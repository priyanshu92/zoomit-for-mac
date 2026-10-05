import CoreGraphics
import Foundation

public enum TextRecognitionMode: String, Codable, CaseIterable, Sendable {
    case accurate
    case fast

    public var title: String {
        switch self {
        case .accurate: "Accurate"
        case .fast: "Fast"
        }
    }
}

public enum TextCaptureKind: String, Codable, CaseIterable, Sendable {
    case text
    case link
    case table
    case code

    public var pluralTitle: String {
        switch self {
        case .text: "Text"
        case .link: "Links"
        case .table: "Tables"
        case .code: "Codes"
        }
    }
}

public enum TextCaptureOrigin: String, Codable, Sendable {
    case screen
    case clipboard
    case file
}

public struct TextCaptureRecord: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let text: String
    public let kind: TextCaptureKind
    public let origin: TextCaptureOrigin
    /// App that owned the captured window, or the file name for file captures.
    public let sourceName: String?
    public let capturedAt: Date

    public init(
        id: UUID = UUID(),
        text: String,
        kind: TextCaptureKind,
        origin: TextCaptureOrigin,
        sourceName: String?,
        capturedAt: Date = Date()
    ) {
        self.id = id
        self.text = text
        self.kind = kind
        self.origin = origin
        self.sourceName = sourceName
        self.capturedAt = capturedAt
    }
}

/// One line of recognized text. `boundingBox` uses Vision's normalized image space:
/// both axes run 0...1 and the origin is the bottom-left corner, so a line that sits
/// higher in the image has a larger `minY`.
public struct RecognizedTextLine: Equatable, Sendable {
    public let text: String
    public let boundingBox: CGRect

    public init(text: String, boundingBox: CGRect) {
        self.text = text
        self.boundingBox = boundingBox
    }
}

public struct RecognizedCode: Equatable, Sendable {
    public let payload: String
    /// Short human-readable symbology, e.g. "QR", "EAN-13", "Code 128".
    public let symbology: String

    public init(payload: String, symbology: String) {
        self.payload = payload
        self.symbology = symbology
    }
}

/// A table rebuilt from an image. The grid is always rectangular and every cell is a
/// single line without tabs, so `tabSeparatedText` round-trips through
/// `TextCaptureHTML` without ambiguity.
public struct RecognizedTable: Equatable, Sendable {
    public let rows: [[String]]
    /// Vision's normalized image space (origin bottom-left), like `RecognizedTextLine`.
    public let boundingBox: CGRect

    public init(rows: [[String]], boundingBox: CGRect) {
        let columnCount = rows.map(\.count).max() ?? 0
        self.rows = rows.map { row in
            (row + Array(repeating: "", count: columnCount - row.count)).map(Self.cleanCell)
        }
        self.boundingBox = boundingBox.standardized
    }

    public var rowCount: Int { rows.count }
    public var columnCount: Int { rows.first?.count ?? 0 }

    /// True when every column averages more than 30 characters per filled cell: side by
    /// side columns of an article, which both the layout heuristic and macOS 26's
    /// document API otherwise report as a table. Real tables keep at least one column of
    /// short values (a name, a number, a term), so a Term | Definition table with long
    /// definitions still counts as a table.
    public var looksLikeColumnsOfProse: Bool {
        guard columnCount >= 2 else { return false }
        return (0..<columnCount).allSatisfy { column in
            let filled = rows.map { $0[column] }.filter { !$0.isEmpty }
            guard !filled.isEmpty else { return false }
            return filled.map(\.count).reduce(0, +) / filled.count > 30
        }
    }

    /// One row per line, cells separated by tabs. Excel, Numbers, and Google Sheets split
    /// pasted plain text on tabs and newlines, so this pastes as a grid even without HTML.
    public var tabSeparatedText: String {
        rows.map { $0.joined(separator: "\t") }.joined(separator: "\n")
    }

    /// A cell may span several recognized lines; tabs or newlines inside it would break
    /// the tab-separated grid, so all whitespace runs collapse to single spaces.
    private static func cleanCell(_ text: String) -> String {
        text.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
    }
}

public struct TextRecognitionResult: Equatable, Sendable {
    public let lines: [RecognizedTextLine]
    public let codes: [RecognizedCode]
    /// Tables found in the image. Their cells are also present in `lines`; composition
    /// replaces those lines with the table.
    public let tables: [RecognizedTable]

    public init(lines: [RecognizedTextLine], codes: [RecognizedCode], tables: [RecognizedTable] = []) {
        self.lines = lines
        self.codes = codes
        self.tables = tables
    }

    public var isEmpty: Bool {
        lines.isEmpty && codes.isEmpty
    }
}

/// One image or one PDF page worth of extracted content.
public enum TextCapturePage: Equatable, Sendable {
    /// Text taken directly from a PDF text layer. It is already exact, so it is never reflowed.
    case embedded(String)
    case recognized(TextRecognitionResult)
}

/// The text that ends up on the clipboard, and what kind of thing it is.
public struct ComposedTextCapture: Equatable, Sendable {
    public let text: String
    public let kind: TextCaptureKind
    /// Symbology when exactly one code was read, e.g. "QR".
    public let codeSymbology: String?
    public let codeCount: Int
    /// Tables in the capture, in reading order.
    public let tables: [RecognizedTable]

    public init(
        text: String,
        kind: TextCaptureKind,
        codeSymbology: String? = nil,
        codeCount: Int = 0,
        tables: [RecognizedTable] = []
    ) {
        self.text = text
        self.kind = kind
        self.codeSymbology = codeSymbology
        self.codeCount = codeCount
        self.tables = tables
    }

    /// Rich clipboard flavor for table captures, so Notes, Pages, Word, and Mail paste a
    /// real table. Nil for everything else, which pastes as plain text.
    public var html: String? {
        kind == .table ? TextCaptureHTML.document(fromTabSeparatedText: text) : nil
    }

    /// A web link that is safe to open: the whole text for links, or a single code's payload.
    public var webURL: URL? {
        switch kind {
        case .link:
            return TextCaptureClassifier.webURL(for: text)
        case .code:
            return codeCount == 1 ? TextCaptureClassifier.webURL(for: text) : nil
        case .text, .table:
            return nil
        }
    }
}

public enum TextCaptureComposer {
    /// Turns extracted pages into the final clipboard text, or nil when nothing was found.
    ///
    /// For a single image (a screen region, a clipboard image, one photo), a detected
    /// QR code or barcode wins over surrounding text: dragging over a code almost always
    /// means "give me what it encodes", and the caption next to it ("Scan to join") is
    /// noise. For multi-page documents the text wins, because a code on one page must
    /// not hide the rest of the document; codes are used only if no text was found.
    public static func compose(_ pages: [TextCapturePage], keepLineBreaks: Bool) -> ComposedTextCapture? {
        var seenPayloads = Set<String>()
        var codes: [RecognizedCode] = []
        for case let .recognized(result) in pages {
            for code in result.codes where seenPayloads.insert(code.payload).inserted {
                codes.append(code)
            }
        }

        var tables: [RecognizedTable] = []
        let pageTexts = pages.compactMap { page -> String? in
            let text: String
            switch page {
            case let .embedded(embedded):
                text = embedded.trimmingCharacters(in: .whitespacesAndNewlines)
            case let .recognized(result) where !result.tables.isEmpty:
                let ordered = result.tables.sorted { $0.boundingBox.midY > $1.boundingBox.midY }
                tables.append(contentsOf: ordered)
                text = compose(result.lines, around: ordered, keepLineBreaks: keepLineBreaks)
            case let .recognized(result):
                text = TextCaptureFormatter.format(result.lines, keepLineBreaks: keepLineBreaks)
            }
            return text.isEmpty ? nil : text
        }

        let prefersCodes = pages.count <= 1
        if !codes.isEmpty, prefersCodes || pageTexts.isEmpty {
            return ComposedTextCapture(
                text: codes.map(\.payload).joined(separator: "\n"),
                kind: .code,
                codeSymbology: codes.count == 1 ? codes[0].symbology : nil,
                codeCount: codes.count
            )
        }

        guard !pageTexts.isEmpty else {
            return nil
        }

        let text = pageTexts.joined(separator: "\n\n")
        if !tables.isEmpty {
            return ComposedTextCapture(text: text, kind: .table, tables: tables)
        }
        return ComposedTextCapture(text: text, kind: TextCaptureClassifier.kind(for: text))
    }

    /// Text above, between, and below the tables (top to bottom), with each table as a
    /// tab-separated block. Lines whose center falls inside a table are dropped: the
    /// table already carries their text in the right cell. Lines keep Vision's reading
    /// order within each gap.
    private static func compose(
        _ lines: [RecognizedTextLine],
        around tables: [RecognizedTable],
        keepLineBreaks: Bool
    ) -> String {
        var gaps = Array(repeating: [RecognizedTextLine](), count: tables.count + 1)
        for line in lines {
            let center = CGPoint(x: line.boundingBox.midX, y: line.boundingBox.midY)
            // A small margin absorbs the few-pixel difference between a table's frame
            // and the boxes of the text inside it.
            if tables.contains(where: { $0.boundingBox.insetBy(dx: -0.01, dy: -0.01).contains(center) }) {
                continue
            }
            let tablesAbove = tables.filter { $0.boundingBox.midY > center.y }.count
            gaps[tablesAbove].append(line)
        }

        var blocks: [String] = []
        for (index, gap) in gaps.enumerated() {
            let text = TextCaptureFormatter.format(gap, keepLineBreaks: keepLineBreaks)
            if !text.isEmpty {
                blocks.append(text)
            }
            if tables.indices.contains(index) {
                blocks.append(tables[index].tabSeparatedText)
            }
        }
        return blocks.joined(separator: "\n\n")
    }
}

/// Builds the HTML clipboard flavor for table captures.
public enum TextCaptureHTML {
    /// Consecutive lines containing tabs become one `<table>`; other lines become
    /// paragraphs, with blank lines separating blocks. Recognized text never contains
    /// tabs (`RecognizedTable` strips them from cells), so a tab always means a cell
    /// boundary. That also lets a table be rebuilt from its plain text in history.
    public static func document(fromTabSeparatedText text: String) -> String {
        var html = "<meta charset=\"utf-8\">"
        var paragraph: [String] = []
        var tableRows: [[String]] = []

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            html += "<p>" + paragraph.map(escape).joined(separator: "<br>") + "</p>"
            paragraph.removeAll()
        }

        func flushTable() {
            guard !tableRows.isEmpty else { return }
            let columnCount = tableRows.map(\.count).max() ?? 0
            // Visible borders: Word and Pages otherwise paste a table with no grid lines,
            // which looks like misaligned text.
            html += "<table border=\"1\" cellpadding=\"4\" cellspacing=\"0\" style=\"border-collapse: collapse\">"
            for row in tableRows {
                let padded = row + Array(repeating: "", count: columnCount - row.count)
                html += "<tr>" + padded.map { "<td>\(escape($0))</td>" }.joined() + "</tr>"
            }
            html += "</table>"
            tableRows.removeAll()
        }

        for line in text.components(separatedBy: "\n") {
            if line.contains("\t") {
                flushParagraph()
                tableRows.append(line.components(separatedBy: "\t"))
            } else if line.trimmingCharacters(in: .whitespaces).isEmpty {
                flushParagraph()
                flushTable()
            } else {
                flushTable()
                paragraph.append(line)
            }
        }
        flushParagraph()
        flushTable()
        return html
    }

    private static func escape(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}

public enum TextCaptureFormatter {
    /// Joins recognized lines in the order Vision returned them. Vision already emits
    /// lines in reading order (column by column), so this never re-sorts; it only decides
    /// which separator goes between neighbours.
    ///
    /// - Neighbours on the same visual row (table cells, label/value pairs) join with a space.
    /// - With `keepLineBreaks`, every other boundary is a newline.
    /// - Without it, lines reflow into paragraphs. A paragraph ends at a large vertical gap,
    ///   a jump back up the page (next column), or a line that starts a list item.
    public static func format(_ lines: [RecognizedTextLine], keepLineBreaks: Bool) -> String {
        let cleaned = lines.compactMap { line -> RecognizedTextLine? in
            let trimmed = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            return RecognizedTextLine(text: trimmed, boundingBox: line.boundingBox.standardized)
        }
        guard let first = cleaned.first else {
            return ""
        }

        let lineHeight = medianHeight(of: cleaned)
        var output = first.text
        var previous = first
        for line in cleaned.dropFirst() {
            output += separator(
                between: previous,
                and: line,
                lineHeight: lineHeight,
                keepLineBreaks: keepLineBreaks
            )
            output += line.text
            previous = line
        }
        return output
    }

    private static func separator(
        between previous: RecognizedTextLine,
        and line: RecognizedTextLine,
        lineHeight: CGFloat,
        keepLineBreaks: Bool
    ) -> String {
        if isSameRow(previous.boundingBox, line.boundingBox) {
            return " "
        }
        if keepLineBreaks || startsNewParagraph(previous.boundingBox, line.boundingBox, lineHeight: lineHeight) {
            return "\n"
        }
        if startsListItem(line.text) {
            return "\n"
        }
        return softJoinSeparator(previous.text, line.text)
    }

    private static func isSameRow(_ previous: CGRect, _ next: CGRect) -> Bool {
        let smallerHeight = min(previous.height, next.height)
        guard smallerHeight > 0 else { return false }
        let verticalOverlap = min(previous.maxY, next.maxY) - max(previous.minY, next.minY)
        let startsAfterPrevious = next.minX >= previous.maxX - smallerHeight * 0.5
        return verticalOverlap >= smallerHeight * 0.5 && startsAfterPrevious
    }

    private static func startsNewParagraph(_ previous: CGRect, _ next: CGRect, lineHeight: CGFloat) -> Bool {
        guard lineHeight > 0 else { return false }
        // Positive gap means `next` sits below `previous`. A negative gap well beyond one
        // line means Vision moved back up the image, i.e. into the next column or block.
        let gap = previous.minY - next.maxY
        return gap > lineHeight * 0.8 || gap < -lineHeight * 0.5
    }

    private static func startsListItem(_ text: String) -> Bool {
        guard let first = text.first else { return false }
        if "•◦▪▫‣●○■□–—*-".contains(first) {
            return true
        }
        // "1." / "12)" / "a." style markers.
        let marker = text.prefix(4)
        guard let delimiterIndex = marker.firstIndex(where: { $0 == "." || $0 == ")" }) else {
            return false
        }
        let label = marker[..<delimiterIndex]
        guard !label.isEmpty else { return false }
        let isNumber = label.allSatisfy(\.isNumber)
        let isSingleLetter = label.count == 1 && label.allSatisfy(\.isLetter)
        let followedBySpace = text.index(after: delimiterIndex) < text.endIndex
            && text[text.index(after: delimiterIndex)].isWhitespace
        return (isNumber || isSingleLetter) && followedBySpace
    }

    private static func softJoinSeparator(_ previous: String, _ next: String) -> String {
        // Keep the hyphen and drop the space: "well-" + "known" must stay "well-known", and
        // identifiers such as "tulip-river-" + "4829" must not gain a space.
        if previous.count > 1, previous.hasSuffix("-") {
            return ""
        }
        // Chinese and Japanese text has no inter-word spaces.
        if let last = previous.unicodeScalars.last, isCJK(last) {
            return ""
        }
        if let first = next.unicodeScalars.first, isCJK(first) {
            return ""
        }
        return " "
    }

    private static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3000...0x303F, // CJK symbols and punctuation
             0x3040...0x30FF, // Hiragana, Katakana
             0x3400...0x4DBF, // CJK Extension A
             0x4E00...0x9FFF, // CJK Unified Ideographs
             0xF900...0xFAFF, // CJK Compatibility Ideographs
             0xFF00...0xFFEF: // Half-width and full-width forms
            return true
        default:
            return false
        }
    }

    private static func medianHeight(of lines: [RecognizedTextLine]) -> CGFloat {
        let heights = lines.map(\.boundingBox.height).filter { $0 > 0 }.sorted()
        guard !heights.isEmpty else { return 0 }
        return heights[heights.count / 2]
    }
}

public enum TextCaptureClassifier {
    public static func kind(for text: String) -> TextCaptureKind {
        webURL(for: text) == nil ? .text : .link
    }

    /// Returns an http(s) URL when the entire trimmed text is one web link, otherwise nil.
    /// Other schemes (mailto:, file:, custom app schemes) are rejected on purpose: this URL
    /// may be opened automatically from a scanned QR code, and those schemes can trigger
    /// local actions the user never asked for.
    public static func webURL(for text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            !trimmed.isEmpty,
            trimmed.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
            let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        else {
            return nil
        }

        let fullRange = NSRange(trimmed.startIndex..., in: trimmed)
        guard
            let match = detector.firstMatch(in: trimmed, options: [], range: fullRange),
            match.range == fullRange,
            let detectedURL = match.url
        else {
            return bareHostWithPathURL(trimmed)
        }
        guard
            let scheme = detectedURL.scheme?.lowercased(),
            scheme == "http" || scheme == "https"
        else {
            return nil
        }

        // NSDataDetector turns a bare "example.com/path" into "http://example.com/path".
        // Prefer HTTPS when the text itself carried no scheme.
        let lowercased = trimmed.lowercased()
        if lowercased.hasPrefix("http://") || lowercased.hasPrefix("https://") {
            return detectedURL
        }
        return URL(string: "https://\(trimmed)") ?? detectedURL
    }

    /// NSDataDetector only recognizes a scheme-less link when it knows the TLD, so newer
    /// ones such as "beta.northwind.dev/join" or "cafe.menu/t12" come back unmatched.
    /// Accept those only with a path after the host: without the path requirement,
    /// file names ("notes.txt") and run-together words ("Hotel.Sternenfeld") would be
    /// classified as links.
    private static func bareHostWithPathURL(_ text: String) -> URL? {
        guard
            let slashIndex = text.firstIndex(of: "/"),
            slashIndex != text.startIndex,
            let components = URLComponents(string: "https://\(text)"),
            let host = components.host,
            host.lowercased() == text[..<slashIndex].lowercased()
        else {
            return nil
        }

        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        let labelsAreValid = labels.allSatisfy { label in
            !label.isEmpty && label.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
        }
        guard
            labels.count >= 2,
            labelsAreValid,
            let topLevelDomain = labels.last,
            (2...24).contains(topLevelDomain.count),
            topLevelDomain.allSatisfy({ $0.isASCII && $0.isLetter })
        else {
            return nil
        }
        return components.url
    }
}
