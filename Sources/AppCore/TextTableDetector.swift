import CoreGraphics
import Foundation

/// Rebuilds a table from the positions of recognized lines. `VNRecognizeTextRequest`
/// has no notion of tables: it returns each cell as its own line, in column-by-column
/// reading order, so joining lines produces "Plan, Starter, Team, …, Seats, 5, 25, …".
/// On macOS 26+ the document API supplies real table structure; this is the fallback
/// for earlier systems and the cheap check that decides whether that API is worth
/// running at all.
public enum TextTableDetector {
    /// True when at least two visual rows contain two or more separate pieces of text,
    /// the minimum shape of a table. Plain paragraphs never pass, so they skip table work.
    public static func looksTabular(_ lines: [RecognizedTextLine]) -> Bool {
        rows(of: lines).filter { $0.count >= 2 }.count >= 2
    }

    /// The table formed by the rows between the first and last multi-cell rows, or nil
    /// when the layout is not a table. Title or note rows outside that span are left for
    /// the caller to keep as text.
    public static func detectTable(in lines: [RecognizedTextLine]) -> RecognizedTable? {
        let rows = rows(of: lines)
        guard
            let firstIndex = rows.firstIndex(where: { $0.count >= 2 }),
            let lastIndex = rows.lastIndex(where: { $0.count >= 2 })
        else {
            return nil
        }

        let body = Array(rows[firstIndex...lastIndex])
        let multiCellRows = body.filter { $0.count >= 2 }
        // Rows with a single piece of text are fine inside a table (empty cells), but if
        // they dominate, this is text with the occasional aligned pair, not a table.
        guard multiCellRows.count >= 2, Double(multiCellRows.count) >= Double(body.count) * 0.6 else {
            return nil
        }

        // Column extents come from the rows that use every column. Rows with merged or
        // empty cells are then placed by horizontal overlap with those extents.
        let columnCount = multiCellRows.map(\.count).max() ?? 0
        let fullRows = multiCellRows.filter { $0.count == columnCount }
        let extents = (0..<columnCount).map { column -> ClosedRange<CGFloat> in
            let boxes = fullRows.map { $0[column].boundingBox }
            let minX = boxes.map(\.minX).min() ?? 0
            let maxX = boxes.map(\.maxX).max() ?? 0
            return minX...max(minX, maxX)
        }

        var grid = Array(repeating: Array(repeating: "", count: columnCount), count: body.count)
        for (rowIndex, row) in body.enumerated() {
            for cell in row {
                let column = bestColumn(for: cell.boundingBox, extents: extents)
                let text = cell.text.trimmingCharacters(in: .whitespacesAndNewlines)
                grid[rowIndex][column] = grid[rowIndex][column].isEmpty ? text : grid[rowIndex][column] + " " + text
            }
        }

        let boundingBox = body.joined().map(\.boundingBox).reduce(CGRect.null) { $0.union($1) }
        let table = RecognizedTable(rows: grid, boundingBox: boundingBox)
        return table.looksLikeColumnsOfProse ? nil : table
    }

    /// Lines grouped into visual rows, top to bottom, each row sorted left to right. A
    /// line joins a row when it overlaps the row's first line vertically by at least half
    /// of the shorter height; comparing with the first line (not the growing union) keeps
    /// one tall cell from swallowing the next row.
    static func rows(of lines: [RecognizedTextLine]) -> [[RecognizedTextLine]] {
        let sorted = lines
            .filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted { $0.boundingBox.midY > $1.boundingBox.midY }

        var rows: [[RecognizedTextLine]] = []
        for line in sorted {
            if let anchor = rows.last?.first, overlapsVertically(anchor.boundingBox, line.boundingBox) {
                rows[rows.count - 1].append(line)
            } else {
                rows.append([line])
            }
        }
        return rows.map { $0.sorted { $0.boundingBox.minX < $1.boundingBox.minX } }
    }

    private static func overlapsVertically(_ first: CGRect, _ second: CGRect) -> Bool {
        let smallerHeight = min(first.height, second.height)
        guard smallerHeight > 0 else { return false }
        let overlap = min(first.maxY, second.maxY) - max(first.minY, second.minY)
        return overlap >= smallerHeight * 0.5
    }

    private static func bestColumn(for box: CGRect, extents: [ClosedRange<CGFloat>]) -> Int {
        var best = 0
        var bestOverlap: CGFloat = 0
        for (index, extent) in extents.enumerated() {
            let overlap = min(box.maxX, extent.upperBound) - max(box.minX, extent.lowerBound)
            if overlap > bestOverlap {
                bestOverlap = overlap
                best = index
            }
        }
        if bestOverlap > 0 {
            return best
        }
        // No overlap (a value sitting in a gap): use the nearest column center.
        let center = box.midX
        return extents.indices.min { lhs, rhs in
            abs((extents[lhs].lowerBound + extents[lhs].upperBound) / 2 - center)
                < abs((extents[rhs].lowerBound + extents[rhs].upperBound) / 2 - center)
        } ?? 0
    }
}
