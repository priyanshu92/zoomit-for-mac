import AppCore
import AppKit
import CoreGraphics

@MainActor
final class RecordingTrimTimelineView: NSView {
    var session: RecordingTrimSession {
        didSet {
            needsDisplay = true
            discardCursorRects()
        }
    }

    var onSessionChanged: (@MainActor (RecordingTrimSession) -> Void)?

    private enum DragTarget {
        case startHandle
        case endHandle
        case playhead
    }

    private struct TimelineColors {
        let dim: NSColor
        let selectedBorder: NSColor
        let handleFill: NSColor
        let handleNotch: NSColor
        let playhead: NSColor
        let playheadShadow: NSColor
        let tick: NSColor
        let primaryText: NSColor
        let secondaryText: NSColor
        let stripFallback: NSColor
    }

    private let frames: [CGImage]
    private let horizontalInset: CGFloat = 28
    private let filmstripHeight: CGFloat = 44
    private let filmstripCornerRadius: CGFloat = 4
    private let handleSize = NSSize(width: 14, height: 60)
    private let handleHitOutset: CGFloat = 8
    private let playheadHitWidth: CGFloat = 14
    private let minimumDrawnSelectionWidth: CGFloat = 6
    private let selectionBorderWidth: CGFloat = 2

    private var activeDragTarget: DragTarget?
    private var cachedFilmstrip: NSImage?
    private var cachedFilmstripWidth: CGFloat = 0

    init(frames: [CGImage], session: RecordingTrimSession) {
        self.frames = frames
        self.session = session
        super.init(frame: .zero)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool { true }

    override var intrinsicContentSize: NSSize {
        NSSize(width: 520, height: 132)
    }

    func update(session: RecordingTrimSession) {
        self.session = session
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let trackRect = timelineTrackRect
        guard trackRect.width > 0 else {
            return
        }

        let colors = timelineColors
        drawFilmstrip(in: trackRect, colors: colors)
        drawDimAndSelectionBorder(in: trackRect, colors: colors)
        drawHandle(at: startHandleX, in: trackRect, colors: colors)
        drawHandle(at: endHandleX, in: trackRect, colors: colors)
        drawPlayhead(in: trackRect, colors: colors)
        drawTicks(in: trackRect, colors: colors)
        drawLabels(in: trackRect, colors: colors)
    }

    override func viewWillStartLiveResize() {
        super.viewWillStartLiveResize()

        let trackRect = timelineTrackRect
        guard trackRect.width > 0, cachedFilmstrip == nil else {
            return
        }

        cachedFilmstrip = renderFilmstrip(width: trackRect.width, height: trackRect.height)
        cachedFilmstripWidth = trackRect.width
    }

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        cachedFilmstrip = nil
        cachedFilmstripWidth = 0
        needsDisplay = true
        discardCursorRects()
    }

    override func resetCursorRects() {
        super.resetCursorRects()

        let trackRect = timelineTrackRect
        guard trackRect.width > 0 else {
            return
        }

        addCursorRect(handleHitRect(at: startHandleX, in: trackRect), cursor: .resizeLeftRight)
        addCursorRect(handleHitRect(at: endHandleX, in: trackRect), cursor: .resizeLeftRight)
        addCursorRect(playheadHitRect(in: trackRect), cursor: .pointingHand)
        addCursorRect(trackRect.insetBy(dx: -2, dy: -16), cursor: .pointingHand)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)

        let point = convert(event.locationInWindow, from: nil)
        guard let target = dragTarget(at: point) else {
            activeDragTarget = nil
            return
        }

        activeDragTarget = target
        applyDrag(target, at: point)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let target = activeDragTarget else {
            return
        }

        applyDrag(target, at: convert(event.locationInWindow, from: nil))
    }

    override func mouseUp(with event: NSEvent) {
        if let target = activeDragTarget {
            applyDrag(target, at: convert(event.locationInWindow, from: nil))
        }
        activeDragTarget = nil
    }

    override func keyDown(with event: NSEvent) {
        guard let scalar = event.charactersIgnoringModifiers?.unicodeScalars.first else {
            super.keyDown(with: event)
            return
        }

        var nextSession = session
        switch scalar.value {
        case UInt32(NSRightArrowFunctionKey):
            nextSession.setPlayheadFrame(session.playheadFrameIndex + 1)
        case UInt32(NSLeftArrowFunctionKey):
            nextSession.setPlayheadFrame(session.playheadFrameIndex - 1)
        default:
            super.keyDown(with: event)
            return
        }

        applyInternalSessionChange(nextSession)
    }

    private var timelineTrackRect: NSRect {
        let inset = min(horizontalInset, max(0, bounds.width / 4))
        let width = max(1, bounds.width - inset * 2)
        let y = bounds.midY - filmstripHeight / 2
        return NSRect(x: bounds.minX + inset, y: y, width: width, height: filmstripHeight)
    }

    private var startHandleX: CGFloat {
        xPosition(forBoundaryIndex: session.selectedRange.startIndex, in: timelineTrackRect)
    }

    private var endHandleX: CGFloat {
        xPosition(forBoundaryIndex: session.selectedRange.endIndexExclusive, in: timelineTrackRect)
    }

    private var playheadX: CGFloat {
        xPosition(forFrameIndex: session.playheadFrameIndex, in: timelineTrackRect)
    }

    private var timelineColors: TimelineColors {
        TimelineColors(
            dim: NSColor.black.withAlphaComponent(0.55),
            selectedBorder: NSColor.controlAccentColor,
            handleFill: NSColor.controlAccentColor,
            handleNotch: NSColor.white.withAlphaComponent(0.9),
            playhead: NSColor.white,
            playheadShadow: NSColor.black.withAlphaComponent(0.55),
            tick: NSColor.tertiaryLabelColor,
            primaryText: NSColor.labelColor,
            secondaryText: NSColor.secondaryLabelColor,
            stripFallback: NSColor.separatorColor.withAlphaComponent(0.55)
        )
    }

    private func drawFilmstrip(in trackRect: NSRect, colors: TimelineColors) {
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }

        let clipPath = NSBezierPath(roundedRect: trackRect, xRadius: filmstripCornerRadius, yRadius: filmstripCornerRadius)
        clipPath.addClip()

        colors.stripFallback.setFill()
        trackRect.fill()

        let strip = ensureFilmstripImage(width: trackRect.width, height: trackRect.height)
        strip.draw(
            in: trackRect,
            from: NSRect(origin: .zero, size: strip.size),
            operation: .copy,
            fraction: 1.0
        )
    }

    private func ensureFilmstripImage(width: CGFloat, height: CGFloat) -> NSImage {
        if let cached = cachedFilmstrip {
            if inLiveResize || abs(cachedFilmstripWidth - width) < 0.5 {
                return cached
            }
        }
        let image = renderFilmstrip(width: width, height: height)
        cachedFilmstrip = image
        cachedFilmstripWidth = width
        return image
    }

    private func renderFilmstrip(width: CGFloat, height: CGFloat) -> NSImage {
        let size = NSSize(width: max(1, width), height: max(1, height))
        let image = NSImage(size: size)
        image.lockFocus()
        defer { image.unlockFocus() }

        NSColor.black.setFill()
        NSRect(origin: .zero, size: size).fill()

        guard !frames.isEmpty else {
            return image
        }

        let firstFrame = frames[0]
        let frameAspect = CGFloat(firstFrame.width) / CGFloat(max(1, firstFrame.height))
        let preferredThumbWidth = max(40, height * frameAspect)
        let count = max(1, Int((width / preferredThumbWidth).rounded()))
        let thumbWidth = width / CGFloat(count)

        for index in 0..<count {
            let frameProgress = (Double(index) + 0.5) / Double(count)
            let frameIndex = min(frames.count - 1, max(0, Int(frameProgress * Double(frames.count))))
            let cgFrame = frames[frameIndex]
            let thumbRect = NSRect(
                x: CGFloat(index) * thumbWidth,
                y: 0,
                width: thumbWidth,
                height: height
            )
            drawAspectFill(cgImage: cgFrame, in: thumbRect)
        }

        return image
    }

    private func drawAspectFill(cgImage: CGImage, in rect: NSRect) {
        let imgW = CGFloat(cgImage.width)
        let imgH = CGFloat(cgImage.height)
        guard imgW > 0, imgH > 0, rect.width > 0, rect.height > 0 else {
            return
        }

        let imgAspect = imgW / imgH
        let rectAspect = rect.width / rect.height

        let sourceRect: NSRect
        if imgAspect > rectAspect {
            let visibleWidth = imgH * rectAspect
            let originX = (imgW - visibleWidth) / 2
            sourceRect = NSRect(x: originX, y: 0, width: visibleWidth, height: imgH)
        } else {
            let visibleHeight = imgW / rectAspect
            let originY = (imgH - visibleHeight) / 2
            sourceRect = NSRect(x: 0, y: originY, width: imgW, height: visibleHeight)
        }

        let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: imgW, height: imgH))
        nsImage.draw(in: rect, from: sourceRect, operation: .copy, fraction: 1.0)
    }

    private func drawDimAndSelectionBorder(in trackRect: NSRect, colors: TimelineColors) {
        let rawSelectionRect = NSRect(
            x: startHandleX,
            y: trackRect.minY,
            width: max(0, endHandleX - startHandleX),
            height: trackRect.height
        )
        let selectionRect = widenedSelectionRect(rawSelectionRect, boundedBy: trackRect)

        NSGraphicsContext.saveGraphicsState()
        let clipPath = NSBezierPath(roundedRect: trackRect, xRadius: filmstripCornerRadius, yRadius: filmstripCornerRadius)
        clipPath.addClip()

        colors.dim.setFill()
        if selectionRect.minX > trackRect.minX {
            NSRect(
                x: trackRect.minX,
                y: trackRect.minY,
                width: selectionRect.minX - trackRect.minX,
                height: trackRect.height
            ).fill()
        }
        if selectionRect.maxX < trackRect.maxX {
            NSRect(
                x: selectionRect.maxX,
                y: trackRect.minY,
                width: trackRect.maxX - selectionRect.maxX,
                height: trackRect.height
            ).fill()
        }

        NSGraphicsContext.restoreGraphicsState()

        let borderInset = selectionBorderWidth / 2
        let borderRect = NSRect(
            x: selectionRect.minX + borderInset,
            y: selectionRect.minY + borderInset,
            width: max(1, selectionRect.width - selectionBorderWidth),
            height: max(1, selectionRect.height - selectionBorderWidth)
        )
        let borderPath = NSBezierPath(rect: borderRect)
        borderPath.lineWidth = selectionBorderWidth
        colors.selectedBorder.setStroke()
        borderPath.stroke()
    }

    private func drawHandle(at x: CGFloat, in trackRect: NSRect, colors: TimelineColors) {
        let rect = handleRect(at: x, in: trackRect)
        let path = NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3)
        colors.handleFill.setFill()
        path.fill()

        let notchPath = NSBezierPath()
        let notchInset = rect.height * 0.32
        notchPath.move(to: NSPoint(x: rect.midX, y: rect.minY + notchInset))
        notchPath.line(to: NSPoint(x: rect.midX, y: rect.maxY - notchInset))
        colors.handleNotch.setStroke()
        notchPath.lineWidth = 1.5
        notchPath.lineCapStyle = .round
        notchPath.stroke()
    }

    private func drawPlayhead(in trackRect: NSRect, colors: TimelineColors) {
        let x = playheadX

        let shadowPath = NSBezierPath()
        shadowPath.move(to: NSPoint(x: x + 1, y: trackRect.minY - 8))
        shadowPath.line(to: NSPoint(x: x + 1, y: trackRect.maxY + 18))
        colors.playheadShadow.setStroke()
        shadowPath.lineWidth = 3
        shadowPath.stroke()

        let linePath = NSBezierPath()
        linePath.move(to: NSPoint(x: x, y: trackRect.minY - 9))
        linePath.line(to: NSPoint(x: x, y: trackRect.maxY + 18))
        colors.playhead.setStroke()
        linePath.lineWidth = 1.5
        linePath.stroke()

        let knobRect = NSRect(x: x - 5, y: trackRect.maxY + 11, width: 10, height: 10)
        let knobPath = NSBezierPath(ovalIn: knobRect)
        colors.playhead.setFill()
        knobPath.fill()
    }

    private func drawTicks(in trackRect: NSRect, colors: TimelineColors) {
        let tickCount = max(2, min(8, Int(trackRect.width / 80)))
        colors.tick.setStroke()

        for index in 0...tickCount {
            let progress = CGFloat(index) / CGFloat(tickCount)
            let x = trackRect.minX + progress * trackRect.width
            let path = NSBezierPath()
            path.move(to: NSPoint(x: x, y: trackRect.minY - 4))
            path.line(to: NSPoint(x: x, y: trackRect.minY - 10))
            path.lineWidth = 1
            path.stroke()
        }
    }

    private func drawLabels(in trackRect: NSRect, colors: TimelineColors) {
        let smallFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        let titleFont = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)

        drawText(
            "0.0s",
            in: NSRect(x: trackRect.minX, y: trackRect.minY - 31, width: 80, height: 16),
            font: smallFont,
            color: colors.secondaryText,
            alignment: .left
        )
        drawText(
            session.formattedTotalDuration,
            in: NSRect(x: trackRect.maxX - 80, y: trackRect.minY - 31, width: 80, height: 16),
            font: smallFont,
            color: colors.secondaryText,
            alignment: .right
        )

        guard bounds.width >= 260 else {
            return
        }

        let selectionText = "\(session.formattedSelectedTimeRange) (\(session.formattedSelectedDuration))"
        drawText(
            selectionText,
            in: NSRect(x: trackRect.minX, y: trackRect.maxY + 27, width: trackRect.width, height: 18),
            font: titleFont,
            color: colors.primaryText,
            alignment: .center
        )

        let playheadLabelWidth: CGFloat = 74
        let playheadLabelMinX = min(
            max(playheadX - playheadLabelWidth / 2, trackRect.minX),
            trackRect.maxX - playheadLabelWidth
        )
        drawText(
            session.formattedPlayheadTime,
            in: NSRect(x: playheadLabelMinX, y: trackRect.maxY + 4, width: playheadLabelWidth, height: 16),
            font: smallFont,
            color: colors.secondaryText,
            alignment: .center
        )
    }

    private func drawText(
        _ text: String,
        in rect: NSRect,
        font: NSFont,
        color: NSColor,
        alignment: NSTextAlignment
    ) {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = alignment
        paragraphStyle.lineBreakMode = .byTruncatingMiddle

        (text as NSString).draw(
            in: rect,
            withAttributes: [
                .font: font,
                .foregroundColor: color,
                .paragraphStyle: paragraphStyle,
            ]
        )
    }

    private func dragTarget(at point: NSPoint) -> DragTarget? {
        let trackRect = timelineTrackRect
        let extendedHitArea = trackRect.insetBy(dx: -handleHitOutset, dy: -22)
        guard extendedHitArea.contains(point) else {
            return nil
        }

        var candidates: [(target: DragTarget, distance: CGFloat)] = []

        if handleHitRect(at: startHandleX, in: trackRect).contains(point) {
            candidates.append((.startHandle, abs(point.x - startHandleX)))
        }
        if handleHitRect(at: endHandleX, in: trackRect).contains(point) {
            candidates.append((.endHandle, abs(point.x - endHandleX)))
        }
        if playheadHitRect(in: trackRect).contains(point) {
            candidates.append((.playhead, abs(point.x - playheadX)))
        }

        if let nearestCandidate = candidates.min(by: { $0.distance < $1.distance }) {
            return nearestCandidate.target
        }

        if point.x < startHandleX {
            return .startHandle
        }

        if point.x > endHandleX {
            return .endHandle
        }

        return .playhead
    }

    private func applyDrag(_ target: DragTarget, at point: NSPoint) {
        var nextSession = session

        switch target {
        case .startHandle:
            nextSession.setStartFrame(boundaryIndex(atX: point.x))
            nextSession.setPlayheadFrame(nextSession.selectedStartFrameIndex)
        case .endHandle:
            nextSession.setEndIndexExclusive(boundaryIndex(atX: point.x))
            nextSession.setPlayheadFrame(nextSession.selectedEndFrameIndex)
        case .playhead:
            nextSession.setPlayheadFrame(frameIndex(atX: point.x))
        }

        applyInternalSessionChange(nextSession)
    }

    private func applyInternalSessionChange(_ nextSession: RecordingTrimSession) {
        guard nextSession != session else {
            return
        }

        session = nextSession
        onSessionChanged?(session)
    }

    private func handleRect(at x: CGFloat, in trackRect: NSRect) -> NSRect {
        NSRect(
            x: x - handleSize.width / 2,
            y: trackRect.midY - handleSize.height / 2,
            width: handleSize.width,
            height: handleSize.height
        )
    }

    private func handleHitRect(at x: CGFloat, in trackRect: NSRect) -> NSRect {
        handleRect(at: x, in: trackRect).insetBy(dx: -handleHitOutset, dy: -handleHitOutset)
    }

    private func playheadHitRect(in trackRect: NSRect) -> NSRect {
        NSRect(
            x: playheadX - playheadHitWidth / 2,
            y: trackRect.minY - 14,
            width: playheadHitWidth,
            height: trackRect.height + 36
        )
    }

    private func widenedSelectionRect(_ selectionRect: NSRect, boundedBy trackRect: NSRect) -> NSRect {
        guard selectionRect.width < minimumDrawnSelectionWidth else {
            return selectionRect
        }

        let width = min(minimumDrawnSelectionWidth, trackRect.width)
        let centeredMinX = selectionRect.midX - width / 2
        let x = min(max(centeredMinX, trackRect.minX), trackRect.maxX - width)
        return NSRect(x: x, y: selectionRect.minY, width: width, height: selectionRect.height)
    }

    private func xPosition(forBoundaryIndex boundaryIndex: Int, in trackRect: NSRect) -> CGFloat {
        let clampedIndex = min(max(boundaryIndex, 0), session.totalFrameCount)
        let progress = CGFloat(clampedIndex) / CGFloat(session.totalFrameCount)
        return trackRect.minX + progress * trackRect.width
    }

    private func xPosition(forFrameIndex frameIndex: Int, in trackRect: NSRect) -> CGFloat {
        let clampedIndex = min(max(frameIndex, 0), session.lastFrameIndex)
        let progress = (CGFloat(clampedIndex) + 0.5) / CGFloat(session.totalFrameCount)
        return trackRect.minX + progress * trackRect.width
    }

    private func boundaryIndex(atX x: CGFloat) -> Int {
        Int((normalizedProgress(atX: x) * Double(session.totalFrameCount)).rounded())
    }

    private func frameIndex(atX x: CGFloat) -> Int {
        let rawIndex = Int((normalizedProgress(atX: x) * Double(session.totalFrameCount)).rounded(.down))
        return min(max(rawIndex, 0), session.lastFrameIndex)
    }

    private func normalizedProgress(atX x: CGFloat) -> Double {
        let trackRect = timelineTrackRect
        guard trackRect.width > 0 else {
            return 0
        }

        let progress = (x - trackRect.minX) / trackRect.width
        return Double(min(max(progress, 0), 1))
    }
}
