import AppKit
import CoreGraphics
import Foundation

enum PanoramaScrollAxis: Sendable {
    case vertical
    case horizontal
}

struct PanoramaFrame: @unchecked Sendable {
    let image: CGImage
    let width: Int
    let height: Int
    let pixels: [UInt8]
    let luma: [UInt8]
    let edges: [UInt8]
    let downsampleScale: Int
    let downsampleWidth: Int
    let downsampleHeight: Int
    let downsampledLuma: [UInt8]
    let downsampledEdges: [UInt8]
    let downsampledRowEdgeDensity: [Double]
    let downsampledColumnEdgeDensity: [Double]
    let constantFraction: Double
}

struct StitchedPanorama: @unchecked Sendable {
    let image: CGImage
    let frameCount: Int
}

struct PanoramaStitcher: Sendable {
    private struct Shift {
        let dx: Int
        let dy: Int
        let score: Double
    }

    private enum Axis {
        case vertical
        case horizontal

        init(_ scrollAxis: PanoramaScrollAxis) {
            switch scrollAxis {
            case .vertical:
                self = .vertical
            case .horizontal:
                self = .horizontal
            }
        }
    }

    private struct Origin {
        var x: Int
        var y: Int
    }

    private struct Candidate {
        let shift: Int
        let score: Double
    }

    func makeFrame(from image: CGImage) throws -> PanoramaFrame {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else {
            throw PanoramaControllerError.captureUnavailable
        }

        let bitmapInfo = CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let didDraw = pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: bitmapInfo
            ) else {
                return false
            }

            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard didDraw else {
            throw PanoramaControllerError.captureUnavailable
        }

        let luma = buildLuma(from: pixels, width: width, height: height)
        let edges = buildEdges(from: luma, width: width, height: height)
        let scale = min(width, height) >= 240 ? 4 : 2
        let downsampledLuma = downsample(luma, width: width, height: height, scale: scale, mode: .average)
        let downsampledEdges = downsample(edges, width: width, height: height, scale: scale, mode: .maximum)
        let downsampleWidth = max(1, width / scale)
        let downsampleHeight = max(1, height / scale)
        let rowEdgeDensity = rowEdgeDensity(downsampledEdges, width: downsampleWidth, height: downsampleHeight)
        let columnEdgeDensity = columnEdgeDensity(downsampledEdges, width: downsampleWidth, height: downsampleHeight)

        return PanoramaFrame(
            image: image,
            width: width,
            height: height,
            pixels: pixels,
            luma: luma,
            edges: edges,
            downsampleScale: scale,
            downsampleWidth: downsampleWidth,
            downsampleHeight: downsampleHeight,
            downsampledLuma: downsampledLuma,
            downsampledEdges: downsampledEdges,
            downsampledRowEdgeDensity: rowEdgeDensity,
            downsampledColumnEdgeDensity: columnEdgeDensity,
            constantFraction: constantContentFraction(luma)
        )
    }

    func isLowContrast(_ frame: PanoramaFrame) -> Bool {
        let mean = frame.luma.reduce(0) { $0 + Int($1) } / max(frame.luma.count, 1)
        let variance = frame.luma.reduce(0.0) { partial, value in
            let delta = Double(Int(value) - mean)
            return partial + delta * delta
        } / Double(max(frame.luma.count, 1))
        let edgeMean = frame.edges.reduce(0) { $0 + Int($1) } / max(frame.edges.count, 1)
        return sqrt(variance) < 18 || edgeMean < 3 || frame.constantFraction > 0.58
    }

    func isNearDuplicate(_ frame: PanoramaFrame, previous: PanoramaFrame, lowContrastMode: Bool) -> Bool {
        guard frame.width == previous.width, frame.height == previous.height else {
            return false
        }

        let step = lowContrastMode ? 4 : 6
        let marginX = max(2, frame.width / 40)
        let marginY = max(2, frame.height / 40)
        var totalDiff = 0
        var changedCount = 0
        var sampleCount = 0

        var y = marginY
        while y < frame.height - marginY {
            var x = marginX
            while x < frame.width - marginX {
                let index = y * frame.width + x
                let diff = abs(Int(frame.luma[index]) - Int(previous.luma[index]))
                totalDiff += diff
                if diff >= 8 {
                    changedCount += 1
                }
                sampleCount += 1
                x += step
            }
            y += step
        }

        guard sampleCount > 0 else { return false }

        let averageDiff = Double(totalDiff) / Double(sampleCount)
        let changedFraction = Double(changedCount) / Double(sampleCount)
        let averageThreshold = lowContrastMode ? 2.0 : 6.0
        let changedThreshold = lowContrastMode ? 0.0005 : 0.005
        var duplicate = averageDiff < averageThreshold && changedFraction < changedThreshold

        if duplicate && informativePixelDifference(frame, previous: previous) >= 8 {
            duplicate = false
        }

        if duplicate,
           let smallShift = bestSmallShift(previous: previous, current: frame, lowContrastMode: lowContrastMode),
           smallShift.score < averageDiff * 0.85 {
            duplicate = false
        }

        return duplicate
    }

    func stitch(
        frames: [PanoramaFrame],
        lowContrastMode: Bool,
        preferredAxis: PanoramaScrollAxis? = nil,
        framesAlreadyFiltered: Bool = false,
        progress: (@Sendable (Double) -> Void)? = nil
    ) throws -> CGImage {
        guard let first = frames.first else {
            throw PanoramaControllerError.noFramesCaptured
        }
        guard frames.allSatisfy({ $0.width == first.width && $0.height == first.height }) else {
            throw PanoramaControllerError.stitchingFailed
        }
        guard frames.count > 1 else {
            return first.image
        }

        var acceptedFrames = [PanoramaFrame]()
        var origins = [Origin]()
        var steps = [Shift]()
        acceptedFrames.reserveCapacity(frames.count)
        origins.reserveCapacity(frames.count)
        steps.reserveCapacity(frames.count)
        acceptedFrames.append(first)
        origins.append(Origin(x: 0, y: 0))
        steps.append(Shift(dx: 0, dy: 0, score: 0))

        var axis = preferredAxis.map(Axis.init)
        var expectedDx = 0
        var expectedDy = 0

        progress?(0.03)
        zoomItDebugLog("Panorama stitch shift pass starting for \(frames.count) frames; preferredAxis=\(String(describing: preferredAxis))")
        let shiftPairCount = max(frames.count - 1, 1)
        for (sourceIndex, frame) in frames.dropFirst().enumerated() {
            defer {
                let shiftedProgress = 0.05 + 0.55 * (Double(sourceIndex + 1) / Double(shiftPairCount))
                progress?(min(shiftedProgress, 0.60))
            }
            let previous = acceptedFrames[acceptedFrames.count - 1]
            if !framesAlreadyFiltered && isNearDuplicate(frame, previous: previous, lowContrastMode: lowContrastMode) {
                zoomItDebugLog("Panorama stitch skipped duplicate frame \(sourceIndex + 2)")
                continue
            }

            zoomItDebugLog("Panorama stitch matching frame \(sourceIndex + 2)")
            let expectedMatchingDx = preferredAxis == nil ? expectedDx : 0
            let expectedMatchingDy = preferredAxis == nil ? expectedDy : 0
            guard let matchedShift = findBestShift(
                previous: previous,
                current: frame,
                axis: axis,
                expectedDx: expectedMatchingDx,
                expectedDy: expectedMatchingDy,
                lowContrastMode: lowContrastMode
            ) else {
                zoomItDebugLog("Panorama stitch rejected frame \(sourceIndex + 2): no reliable shift")
                continue
            }

            if axis == nil {
                axis = abs(matchedShift.dy) >= abs(matchedShift.dx) ? .vertical : .horizontal
            }
            let activeAxis = axis ?? .vertical
            let shift = placementShift(from: matchedShift, axis: activeAxis, preferredAxis: preferredAxis)

            guard abs(shift.dx) >= 1 || abs(shift.dy) >= 1 else {
                continue
            }

            let previousOrigin = origins[origins.count - 1]
            origins.append(Origin(x: previousOrigin.x + shift.dx, y: previousOrigin.y + shift.dy))
            steps.append(shift)
            acceptedFrames.append(frame)
            expectedDx = shift.dx
            expectedDy = shift.dy
            zoomItDebugLog("Panorama stitch accepted frame \(sourceIndex + 2) matched=(\(matchedShift.dx),\(matchedShift.dy)) placed=(\(shift.dx),\(shift.dy)) score=\(String(format: "%.2f", shift.score))")
        }

        guard acceptedFrames.count > 1 else {
            zoomItDebugLog("Panorama stitch had no shifted frames; returning first frame")
            progress?(1.0)
            return first.image
        }

        zoomItDebugLog("Panorama stitch composing \(acceptedFrames.count) frames")
        progress?(0.65)
        let image = try compose(
            frames: acceptedFrames,
            origins: origins,
            steps: steps,
            axis: axis ?? .vertical,
            progress: progress
        )
        progress?(1.0)
        return image
    }

    private func placementShift(
        from matchedShift: Shift,
        axis: Axis,
        preferredAxis: PanoramaScrollAxis?
    ) -> Shift {
        guard let preferredAxis else {
            return matchedShift
        }

        switch (axis, preferredAxis) {
        case (.vertical, .vertical):
            return Shift(dx: 0, dy: abs(matchedShift.dy), score: matchedShift.score)
        case (.horizontal, .horizontal):
            return Shift(dx: abs(matchedShift.dx), dy: 0, score: matchedShift.score)
        default:
            return matchedShift
        }
    }

    private func findBestShift(
        previous: PanoramaFrame,
        current: PanoramaFrame,
        axis: Axis?,
        expectedDx: Int,
        expectedDy: Int,
        lowContrastMode: Bool
    ) -> Shift? {
        if let axis {
            return findBestShiftOnAxis(
                previous: previous,
                current: current,
                axis: axis,
                expectedDx: expectedDx,
                expectedDy: expectedDy,
                lowContrastMode: lowContrastMode
            )
        }

        let vertical = findBestShiftOnAxis(
            previous: previous,
            current: current,
            axis: .vertical,
            expectedDx: 0,
            expectedDy: 0,
            lowContrastMode: lowContrastMode
        )
        let horizontal = findBestShiftOnAxis(
            previous: previous,
            current: current,
            axis: .horizontal,
            expectedDx: 0,
            expectedDy: 0,
            lowContrastMode: lowContrastMode
        )

        switch (vertical, horizontal) {
        case let (v?, h?):
            if previous.height >= previous.width * 2 {
                return v
            }
            let horizontalNeedsStrongWin = lowContrastMode ? 0.65 : 0.75
            return h.score < v.score * horizontalNeedsStrongWin ? h : v
        case let (v?, nil):
            return v
        case let (nil, h?):
            return previous.width <= previous.height ? h : nil
        case (nil, nil):
            return nil
        }
    }

    private func findBestShiftOnAxis(
        previous: PanoramaFrame,
        current: PanoramaFrame,
        axis: Axis,
        expectedDx: Int,
        expectedDy: Int,
        lowContrastMode: Bool
    ) -> Shift? {
        let dsScale = previous.downsampleScale
        let axisLength = axis == .vertical ? previous.downsampleHeight : previous.downsampleWidth
        let maxStep = axisLength - max(2, axisLength / 6)
        guard maxStep > 2 else { return nil }

        let expected = axis == .vertical ? expectedDy / dsScale : expectedDx / dsScale
        let fullRange = (-maxStep)...maxStep
        let primaryRange: ClosedRange<Int>
        if expected == 0 {
            primaryRange = fullRange
        } else {
            // Signed window with proportional slack plus a small absolute floor so the next
            // pair can find shifts that are smaller (slowing scroll) or larger (accelerating)
            // than the previous one without hitting the exact boundary.
            let absExpected = abs(expected)
            let slack = max(absExpected, 16)
            let lower = max(1, absExpected - slack)
            let upper = min(maxStep, absExpected + slack)
            if lower <= upper {
                primaryRange = expected > 0 ? lower...upper : (-upper)...(-lower)
            } else {
                primaryRange = fullRange
            }
        }

        if let shift = matchOnRange(
            previous: previous,
            current: current,
            axis: axis,
            searchRange: primaryRange,
            expectedDx: expectedDx,
            expectedDy: expectedDy,
            lowContrastMode: lowContrastMode
        ) {
            return shift
        }

        // Fall back to the full search range only if the bounded one failed; this protects
        // against scroll velocity changing more than the slack window while keeping the fast
        // path tight in the common case.
        if primaryRange != fullRange {
            return matchOnRange(
                previous: previous,
                current: current,
                axis: axis,
                searchRange: fullRange,
                expectedDx: expectedDx,
                expectedDy: expectedDy,
                lowContrastMode: lowContrastMode
            )
        }
        return nil
    }

    private func matchOnRange(
        previous: PanoramaFrame,
        current: PanoramaFrame,
        axis: Axis,
        searchRange: ClosedRange<Int>,
        expectedDx: Int,
        expectedDy: Int,
        lowContrastMode: Bool
    ) -> Shift? {
        let dsScale = previous.downsampleScale
        let dsWidth = previous.downsampleWidth
        let dsHeight = previous.downsampleHeight

        if let fastShift = fastEdgeDensityShift(
            previous: previous,
            current: current,
            axis: axis,
            searchRange: searchRange,
            lowContrastMode: lowContrastMode
        ) {
            return fastShift
        }

        // Coarser sample step keeps the brute-force scan affordable when the fast
        // edge-density path cannot lock on to a shift. Fine refinement below uses a
        // tighter step at full resolution.
        let scanSampleStep = lowContrastMode ? 3 : 4
        var candidates: [Candidate] = []
        candidates.reserveCapacity(8)

        let scanStride = max(1, (searchRange.upperBound - searchRange.lowerBound) / 256)
        var shift = searchRange.lowerBound
        while shift <= searchRange.upperBound {
            defer { shift += scanStride }
            guard shift != 0 else { continue }
            let dx = axis == .horizontal ? shift : 0
            let dy = axis == .vertical ? shift : 0
            guard let score = scoreShift(
                lumaA: previous.downsampledLuma,
                edgesA: previous.downsampledEdges,
                lumaB: current.downsampledLuma,
                edgesB: current.downsampledEdges,
                width: dsWidth,
                height: dsHeight,
                dx: dx,
                dy: dy,
                sampleStep: scanSampleStep,
                lowContrastMode: lowContrastMode
            ) else {
                continue
            }
            insert(Candidate(shift: shift, score: score), into: &candidates, limit: 8)
        }

        if candidates.isEmpty,
           let edgeCandidate = edgeDensityCandidate(previous: previous, current: current, axis: axis, searchRange: searchRange) {
            candidates.append(edgeCandidate)
        }

        guard !candidates.isEmpty else { return nil }

        // Stationary score on downsampled luma is plenty to detect duplicate frames and
        // is dramatically cheaper than scanning at full resolution.
        let stationary = scoreShift(
            lumaA: previous.downsampledLuma,
            edgesA: previous.downsampledEdges,
            lumaB: current.downsampledLuma,
            edgesB: current.downsampledEdges,
            width: dsWidth,
            height: dsHeight,
            dx: 0,
            dy: 0,
            sampleStep: 2,
            lowContrastMode: lowContrastMode
        ) ?? .greatestFiniteMagnitude
        if stationary <= (lowContrastMode ? 1.0 : 2.0) {
            return nil
        }

        // Refine just the single best candidate at full resolution. Cross-axis range
        // recovers ±1 px wobble and the main range recovers downsample-scale quantization.
        var best: Shift?
        let topCandidate = candidates[0]
        let baseShift = topCandidate.shift * dsScale
        let mainRange = (baseShift - dsScale)...(baseShift + dsScale)
        let crossRange = -1...1
        let fineSampleStep = lowContrastMode ? 6 : 8

        for main in mainRange {
            for cross in crossRange {
                let dx = axis == .horizontal ? main : cross
                let dy = axis == .vertical ? main : cross
                guard dx != 0 || dy != 0 else { continue }
                guard let rawScore = scoreShift(
                    lumaA: previous.luma,
                    edgesA: previous.edges,
                    lumaB: current.luma,
                    edgesB: current.edges,
                    width: previous.width,
                    height: previous.height,
                    dx: dx,
                    dy: dy,
                    sampleStep: fineSampleStep,
                    lowContrastMode: lowContrastMode
                ) else {
                    continue
                }

                let expectedMain = axis == .vertical ? expectedDy : expectedDx
                let expectedPenalty = expectedMain == 0 ? 0 : min(Double(abs(main - expectedMain)) * 0.01, 2.0)
                let score = rawScore + expectedPenalty
                if best == nil || score < best!.score {
                    best = Shift(dx: dx, dy: dy, score: score)
                }
            }
        }

        guard let best else { return nil }
        let threshold = lowContrastMode ? 52.0 : 64.0
        let stationaryFullThreshold = stationary * (lowContrastMode ? 0.85 : 0.82)
        guard best.score <= threshold || best.score < stationaryFullThreshold else {
            return nil
        }
        return best
    }

    private func fastEdgeDensityShift(
        previous: PanoramaFrame,
        current: PanoramaFrame,
        axis: Axis,
        searchRange: ClosedRange<Int>,
        lowContrastMode: Bool
    ) -> Shift? {
        guard let candidate = edgeDensityCandidate(previous: previous, current: current, axis: axis, searchRange: searchRange) else {
            return nil
        }
        // Score is -correlation*100; require at least a modest correlation so we do not
        // chase noise on visually empty frames. This is more permissive than the prior
        // -18 cutoff so the fast path triggers on more page layouts.
        guard candidate.score < (lowContrastMode ? -4 : -8) else {
            return nil
        }

        let dsScale = previous.downsampleScale
        let baseShift = candidate.shift * dsScale

        // Refine at full resolution within ±dsScale to recover sub-block precision and
        // pick up small cross-axis drift. Single best wins.
        var best: Shift?
        let mainRange = (baseShift - dsScale)...(baseShift + dsScale)
        let crossRange = -1...1
        let sampleStep = lowContrastMode ? 6 : 8
        for main in mainRange {
            for cross in crossRange {
                let dx = axis == .horizontal ? main : cross
                let dy = axis == .vertical ? main : cross
                guard dx != 0 || dy != 0 else { continue }
                guard let score = scoreShift(
                    lumaA: previous.luma,
                    edgesA: previous.edges,
                    lumaB: current.luma,
                    edgesB: current.edges,
                    width: previous.width,
                    height: previous.height,
                    dx: dx,
                    dy: dy,
                    sampleStep: sampleStep,
                    lowContrastMode: lowContrastMode
                ) else {
                    continue
                }
                if best == nil || score < best!.score {
                    best = Shift(dx: dx, dy: dy, score: score)
                }
            }
        }

        guard let best else { return nil }
        let threshold = lowContrastMode ? 58.0 : 72.0
        guard best.score <= threshold else {
            return nil
        }
        return best
    }

    private func bestSmallShift(previous: PanoramaFrame, current: PanoramaFrame, lowContrastMode: Bool) -> Shift? {
        let maxDy = lowContrastMode ? 24 : 16
        let maxDx = lowContrastMode ? 12 : 8
        var best: Shift?

        for dy in (-maxDy)...maxDy {
            for dx in (-maxDx)...maxDx {
                guard dx != 0 || dy != 0 else { continue }
                guard let score = scoreShift(
                    lumaA: previous.downsampledLuma,
                    edgesA: previous.downsampledEdges,
                    lumaB: current.downsampledLuma,
                    edgesB: current.downsampledEdges,
                    width: previous.downsampleWidth,
                    height: previous.downsampleHeight,
                    dx: dx / previous.downsampleScale,
                    dy: dy / previous.downsampleScale,
                    sampleStep: 2,
                    lowContrastMode: lowContrastMode
                ) else {
                    continue
                }
                if best == nil || score < best!.score {
                    best = Shift(dx: dx, dy: dy, score: score)
                }
            }
        }

        return best
    }

    private func scoreShift(
        lumaA: [UInt8],
        edgesA: [UInt8],
        lumaB: [UInt8],
        edgesB: [UInt8],
        width: Int,
        height: Int,
        dx: Int,
        dy: Int,
        sampleStep: Int,
        lowContrastMode: Bool
    ) -> Double? {
        guard width > 8, height > 8 else { return nil }

        let x0 = max(0, dx)
        let x1 = min(width, width + dx)
        let y0 = max(0, dy)
        let y1 = min(height, height + dy)
        guard x1 - x0 > max(8, width / 8), y1 - y0 > max(8, height / 8) else {
            return nil
        }

        let marginX = max(1, width / 20)
        let marginY = max(1, height / 20)
        let startX = min(max(x0, marginX), x1)
        let endX = max(min(x1, width - marginX), startX)
        let startY = min(max(y0, marginY), y1)
        let endY = max(min(y1, height - marginY), startY)
        guard endX > startX + 4, endY > startY + 4 else {
            return nil
        }

        var lumaDiff = 0
        var lumaCount = 0
        var edgeDiff = 0
        var edgeLumaDiff = 0
        var edgeCount = 0
        let edgeThreshold = lowContrastMode ? 4 : 8

        var y = startY
        while y < endY {
            let rowA = y * width
            let rowB = (y - dy) * width
            var x = startX
            while x < endX {
                let indexA = rowA + x
                let indexB = rowB + (x - dx)
                let diff = abs(Int(lumaA[indexA]) - Int(lumaB[indexB]))
                lumaDiff += diff
                lumaCount += 1

                if Int(edgesA[indexA]) >= edgeThreshold || Int(edgesB[indexB]) >= edgeThreshold {
                    edgeDiff += abs(Int(edgesA[indexA]) - Int(edgesB[indexB]))
                    edgeLumaDiff += diff
                    edgeCount += 1
                }
                x += sampleStep
            }
            y += sampleStep
        }

        guard lumaCount >= 100 else { return nil }
        let lumaScore = Double(lumaDiff) / Double(lumaCount)

        if edgeCount >= (lowContrastMode ? 20 : 60) {
            let edgeScore = Double(edgeDiff) / Double(edgeCount)
            let maskedLumaScore = Double(edgeLumaDiff) / Double(edgeCount)
            if lowContrastMode {
                return lumaScore * 0.25 + edgeScore * 0.25 + maskedLumaScore * 0.50
            }
            return lumaScore * 0.45 + edgeScore * 0.25 + maskedLumaScore * 0.30
        }

        return lumaScore
    }

    private func edgeDensityCandidate(
        previous: PanoramaFrame,
        current: PanoramaFrame,
        axis: Axis,
        searchRange: ClosedRange<Int>
    ) -> Candidate? {
        let previousDensity = axis == .vertical ? previous.downsampledRowEdgeDensity : previous.downsampledColumnEdgeDensity
        let currentDensity = axis == .vertical ? current.downsampledRowEdgeDensity : current.downsampledColumnEdgeDensity
        let length = previousDensity.count
        guard length == currentDensity.count, length > 8 else { return nil }
        let maxAbs = length - max(2, length / 6)

        var best: Candidate?
        for shift in searchRange {
            let absShift = abs(shift)
            guard absShift < maxAbs else { continue }

            let overlap = length - absShift
            let startA = shift < 0 ? absShift : 0
            let startB = shift < 0 ? 0 : absShift
            let score = normalizedCorrelation(
                previousDensity,
                currentDensity,
                startA: startA,
                startB: startB,
                count: overlap
            )
            let candidate = Candidate(shift: shift, score: -score * 100)
            if best == nil || candidate.score < best!.score {
                best = candidate
            }
        }
        return best
    }

    private func compose(
        frames: [PanoramaFrame],
        origins: [Origin],
        steps: [Shift],
        axis: Axis,
        progress: (@Sendable (Double) -> Void)? = nil
    ) throws -> CGImage {
        guard let first = frames.first else {
            throw PanoramaControllerError.noFramesCaptured
        }

        var minX = origins[0].x
        var minY = origins[0].y
        var maxX = origins[0].x + first.width
        var maxY = origins[0].y + first.height

        for origin in origins {
            minX = min(minX, origin.x)
            minY = min(minY, origin.y)
            maxX = max(maxX, origin.x + first.width)
            maxY = max(maxY, origin.y + first.height)
        }

        let width = maxX - minX
        let height = maxY - minY
        guard width > 0, height > 0, width <= 64_000, height <= 64_000 else {
            throw PanoramaControllerError.stitchingFailed
        }

        var canvas = [UInt8](repeating: 0, count: width * height * 4)
        let verticalFeather = min(max(first.height / 18, 4), 28)
        let horizontalFeather = min(max(first.width / 18, 4), 28)

        for frameIndex in frames.indices {
            let frame = frames[frameIndex]
            let origin = origins[frameIndex]
            let normalizedX = origin.x - minX
            let normalizedY = origin.y - minY
            let step = steps[frameIndex]
            let region = compositionRegion(
                for: frame,
                frameIndex: frameIndex,
                step: step,
                axis: axis,
                verticalFeather: verticalFeather,
                horizontalFeather: horizontalFeather
            )

            for y in region.yRange {
                let destinationY = normalizedY + y
                guard destinationY >= 0, destinationY < height else { continue }
                for x in region.xRange {
                    let destinationX = normalizedX + x
                    guard destinationX >= 0, destinationX < width else { continue }

                    let sourceIndex = (y * frame.width + x) * 4
                    let destinationIndex = (destinationY * width + destinationX) * 4
                    let existingAlpha = canvas[destinationIndex + 3]

                    if existingAlpha == 0 {
                        copyPixel(from: frame.pixels, sourceIndex: sourceIndex, to: &canvas, destinationIndex: destinationIndex)
                        continue
                    }

                    let weight = blendWeight(
                        x: x,
                        y: y,
                        frame: frame,
                        step: step,
                        axis: axis,
                        verticalFeather: verticalFeather,
                        horizontalFeather: horizontalFeather
                    )
                    guard weight > 0 else { continue }
                    blendPixel(from: frame.pixels, sourceIndex: sourceIndex, into: &canvas, destinationIndex: destinationIndex, weight: weight)
                }
            }
            let composedProgress = 0.65 + 0.30 * (Double(frameIndex + 1) / Double(max(frames.count, 1)))
            progress?(min(composedProgress, 0.95))
        }

        progress?(0.97)
        guard let provider = CGDataProvider(data: Data(canvas) as CFData) else {
            throw PanoramaControllerError.stitchingFailed
        }
        let bitmapInfo = CGBitmapInfo.byteOrder32Big.union(CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue))
        guard let image = CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ) else {
            throw PanoramaControllerError.stitchingFailed
        }

        return image
    }

    private func compositionRegion(
        for frame: PanoramaFrame,
        frameIndex: Int,
        step: Shift,
        axis: Axis,
        verticalFeather: Int,
        horizontalFeather: Int
    ) -> (xRange: Range<Int>, yRange: Range<Int>) {
        let fullX = 0..<frame.width
        let fullY = 0..<frame.height
        guard frameIndex > 0 else {
            return (fullX, fullY)
        }

        switch axis {
        case .vertical:
            guard step.dx == 0 else {
                return (fullX, fullY)
            }
            let axisStep = abs(step.dy)
            let overlap = frame.height - axisStep
            guard overlap > 0 else {
                return (fullX, fullY)
            }
            if step.dy >= 0 {
                return (fullX, max(0, overlap - verticalFeather)..<frame.height)
            }
            return (fullX, 0..<min(frame.height, axisStep + verticalFeather))
        case .horizontal:
            guard step.dy == 0 else {
                return (fullX, fullY)
            }
            let axisStep = abs(step.dx)
            let overlap = frame.width - axisStep
            guard overlap > 0 else {
                return (fullX, fullY)
            }
            if step.dx >= 0 {
                return (max(0, overlap - horizontalFeather)..<frame.width, fullY)
            }
            return (0..<min(frame.width, axisStep + horizontalFeather), fullY)
        }
    }

    private func blendWeight(
        x: Int,
        y: Int,
        frame: PanoramaFrame,
        step: Shift,
        axis: Axis,
        verticalFeather: Int,
        horizontalFeather: Int
    ) -> Double {
        switch axis {
        case .vertical:
            let axisStep = abs(step.dy)
            let overlap = frame.height - axisStep
            guard overlap > 0 else { return 1 }
            if step.dy >= 0 {
                let start = max(0, overlap - verticalFeather)
                guard y >= start else { return 0 }
                return Double(y - start + 1) / Double(max(1, verticalFeather))
            } else {
                guard y >= axisStep, y < axisStep + verticalFeather else { return 0 }
                return 1.0 - Double(y - axisStep) / Double(max(1, verticalFeather))
            }
        case .horizontal:
            let axisStep = abs(step.dx)
            let overlap = frame.width - axisStep
            guard overlap > 0 else { return 1 }
            if step.dx >= 0 {
                let start = max(0, overlap - horizontalFeather)
                guard x >= start else { return 0 }
                return Double(x - start + 1) / Double(max(1, horizontalFeather))
            } else {
                guard x >= axisStep, x < axisStep + horizontalFeather else { return 0 }
                return 1.0 - Double(x - axisStep) / Double(max(1, horizontalFeather))
            }
        }
    }

    private func insert(_ candidate: Candidate, into candidates: inout [Candidate], limit: Int) {
        candidates.append(candidate)
        candidates.sort { $0.score < $1.score }
        if candidates.count > limit {
            candidates.removeLast(candidates.count - limit)
        }
    }

    private func informativePixelDifference(_ frame: PanoramaFrame, previous: PanoramaFrame) -> Double {
        let edgeThreshold = 6
        var total = 0
        var count = 0
        var y = 1
        while y < frame.height - 1 {
            var x = 1
            while x < frame.width - 1 {
                let index = y * frame.width + x
                if Int(frame.edges[index]) >= edgeThreshold || Int(previous.edges[index]) >= edgeThreshold {
                    total += abs(Int(frame.luma[index]) - Int(previous.luma[index]))
                    count += 1
                }
                x += 2
            }
            y += 2
        }
        return count > 0 ? Double(total) / Double(count) : 0
    }

    private func copyPixel(from source: [UInt8], sourceIndex: Int, to destination: inout [UInt8], destinationIndex: Int) {
        destination[destinationIndex] = source[sourceIndex]
        destination[destinationIndex + 1] = source[sourceIndex + 1]
        destination[destinationIndex + 2] = source[sourceIndex + 2]
        destination[destinationIndex + 3] = 255
    }

    private func blendPixel(from source: [UInt8], sourceIndex: Int, into destination: inout [UInt8], destinationIndex: Int, weight: Double) {
        let clampedWeight = min(max(weight, 0), 1)
        let inverse = 1.0 - clampedWeight
        destination[destinationIndex] = UInt8(Double(destination[destinationIndex]) * inverse + Double(source[sourceIndex]) * clampedWeight)
        destination[destinationIndex + 1] = UInt8(Double(destination[destinationIndex + 1]) * inverse + Double(source[sourceIndex + 1]) * clampedWeight)
        destination[destinationIndex + 2] = UInt8(Double(destination[destinationIndex + 2]) * inverse + Double(source[sourceIndex + 2]) * clampedWeight)
        destination[destinationIndex + 3] = 255
    }

    private enum DownsampleMode {
        case average
        case maximum
    }

    private func downsample(_ source: [UInt8], width: Int, height: Int, scale: Int, mode: DownsampleMode) -> [UInt8] {
        let downsampleWidth = max(1, width / scale)
        let downsampleHeight = max(1, height / scale)
        var output = [UInt8](repeating: 0, count: downsampleWidth * downsampleHeight)

        for y in 0..<downsampleHeight {
            for x in 0..<downsampleWidth {
                var total = 0
                var maxValue = 0
                var count = 0
                for yy in 0..<scale {
                    let sourceY = min(height - 1, y * scale + yy)
                    for xx in 0..<scale {
                        let sourceX = min(width - 1, x * scale + xx)
                        let value = Int(source[sourceY * width + sourceX])
                        total += value
                        maxValue = max(maxValue, value)
                        count += 1
                    }
                }
                output[y * downsampleWidth + x] = UInt8(mode == .average ? total / max(count, 1) : maxValue)
            }
        }

        return output
    }

    private func buildLuma(from pixels: [UInt8], width: Int, height: Int) -> [UInt8] {
        var luma = [UInt8](repeating: 0, count: width * height)
        for index in 0..<(width * height) {
            let pixelIndex = index * 4
            let red = Int(pixels[pixelIndex])
            let green = Int(pixels[pixelIndex + 1])
            let blue = Int(pixels[pixelIndex + 2])
            luma[index] = UInt8((77 * red + 150 * green + 29 * blue) >> 8)
        }
        return luma
    }

    private func buildEdges(from luma: [UInt8], width: Int, height: Int) -> [UInt8] {
        var rawEdges = [UInt8](repeating: 0, count: width * height)
        guard width > 2, height > 2 else { return rawEdges }

        for y in 1..<(height - 1) {
            for x in 1..<(width - 1) {
                let index = y * width + x
                let horizontal = abs(Int(luma[index - 1]) - Int(luma[index + 1]))
                let vertical = abs(Int(luma[index - width]) - Int(luma[index + width]))
                rawEdges[index] = UInt8(min(255, horizontal + vertical))
            }
        }

        return dilated(rawEdges, width: width, height: height)
    }

    private func dilated(_ source: [UInt8], width: Int, height: Int) -> [UInt8] {
        var output = source
        guard width > 2, height > 2 else { return output }

        for y in 1..<(height - 1) {
            for x in 1..<(width - 1) {
                let index = y * width + x
                output[index] = max(
                    source[index],
                    source[index - 1],
                    source[index + 1],
                    source[index - width],
                    source[index + width]
                )
            }
        }

        return output
    }

    private func constantContentFraction(_ luma: [UInt8]) -> Double {
        guard !luma.isEmpty else { return 0 }
        var buckets = [Int](repeating: 0, count: 32)
        for value in luma {
            buckets[Int(value) / 8] += 1
        }
        return Double(buckets.max() ?? 0) / Double(luma.count)
    }

    private func rowEdgeDensity(_ edges: [UInt8], width: Int, height: Int) -> [Double] {
        var density = [Double](repeating: 0, count: height)
        guard width > 0, height > 0 else { return density }
        for y in 0..<height {
            var total = 0
            let rowOffset = y * width
            for x in 0..<width {
                total += Int(edges[rowOffset + x])
            }
            density[y] = Double(total)
        }
        return density
    }

    private func columnEdgeDensity(_ edges: [UInt8], width: Int, height: Int) -> [Double] {
        var density = [Double](repeating: 0, count: width)
        guard width > 0, height > 0 else { return density }
        for x in 0..<width {
            var total = 0
            for y in 0..<height {
                total += Int(edges[y * width + x])
            }
            density[x] = Double(total)
        }
        return density
    }

    private func normalizedCorrelation(_ a: [Double], _ b: [Double], startA: Int, startB: Int, count: Int) -> Double {
        guard count > 4, startA >= 0, startB >= 0, startA + count <= a.count, startB + count <= b.count else {
            return 0
        }

        var sumA = 0.0
        var sumB = 0.0
        for index in 0..<count {
            sumA += a[startA + index]
            sumB += b[startB + index]
        }
        let meanA = sumA / Double(count)
        let meanB = sumB / Double(count)

        var numerator = 0.0
        var varianceA = 0.0
        var varianceB = 0.0
        for index in 0..<count {
            let valueA = a[startA + index] - meanA
            let valueB = b[startB + index] - meanB
            numerator += valueA * valueB
            varianceA += valueA * valueA
            varianceB += valueB * valueB
        }

        guard varianceA > 0, varianceB > 0 else { return 0 }
        return numerator / sqrt(varianceA * varianceB)
    }
}
