import AppCore
import AppKit

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
        let track: NSColor
        let mutedRegion: NSColor
        let selectedRegion: NSColor
        let handleFill: NSColor
        let handleStroke: NSColor
        let playhead: NSColor
        let tick: NSColor
        let primaryText: NSColor
        let secondaryText: NSColor
    }

    private let horizontalInset: CGFloat = 28
    private let trackHeight: CGFloat = 12
    private let handleSize = NSSize(width: 12, height: 36)
    private let handleHitOutset: CGFloat = 8
    private let playheadHitWidth: CGFloat = 14
    private let minimumDrawnSelectionWidth: CGFloat = 6
    private var activeDragTarget: DragTarget?

    init(session: RecordingTrimSession) {
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
        NSSize(width: 520, height: 108)
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
        drawTrack(in: trackRect, colors: colors)
        drawTicks(in: trackRect, colors: colors)
        drawLabels(in: trackRect, colors: colors)
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
        addCursorRect(trackRect.insetBy(dx: -2, dy: -12), cursor: .pointingHand)
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
        let y = bounds.midY - trackHeight / 2
        return NSRect(x: bounds.minX + inset, y: y, width: width, height: trackHeight)
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
            track: NSColor.separatorColor.withAlphaComponent(0.55),
            mutedRegion: NSColor.disabledControlTextColor.withAlphaComponent(0.18),
            selectedRegion: NSColor.controlAccentColor.withAlphaComponent(0.42),
            handleFill: NSColor.controlBackgroundColor,
            handleStroke: NSColor.controlAccentColor,
            playhead: NSColor.labelColor,
            tick: NSColor.tertiaryLabelColor,
            primaryText: NSColor.labelColor,
            secondaryText: NSColor.secondaryLabelColor
        )
    }

    private func drawTrack(in trackRect: NSRect, colors: TimelineColors) {
        let basePath = NSBezierPath(roundedRect: trackRect, xRadius: trackHeight / 2, yRadius: trackHeight / 2)
        colors.track.setFill()
        basePath.fill()

        let rawSelectionRect = NSRect(
            x: startHandleX,
            y: trackRect.minY,
            width: max(0, endHandleX - startHandleX),
            height: trackRect.height
        )
        let selectionRect = widenedSelectionRect(rawSelectionRect, boundedBy: trackRect)

        drawMutedRegion(from: trackRect.minX, to: selectionRect.minX, in: trackRect, colors: colors)
        drawMutedRegion(from: selectionRect.maxX, to: trackRect.maxX, in: trackRect, colors: colors)

        let selectedPath = NSBezierPath(roundedRect: selectionRect, xRadius: trackHeight / 2, yRadius: trackHeight / 2)
        colors.selectedRegion.setFill()
        selectedPath.fill()

        drawHandle(at: startHandleX, in: trackRect, colors: colors)
        drawHandle(at: endHandleX, in: trackRect, colors: colors)
        drawPlayhead(in: trackRect, colors: colors)
    }

    private func drawMutedRegion(from minX: CGFloat, to maxX: CGFloat, in trackRect: NSRect, colors: TimelineColors) {
        guard maxX > minX else {
            return
        }

        let rect = NSRect(x: minX, y: trackRect.minY, width: maxX - minX, height: trackRect.height)
        let path = NSBezierPath(roundedRect: rect, xRadius: trackHeight / 2, yRadius: trackHeight / 2)
        colors.mutedRegion.setFill()
        path.fill()
    }

    private func drawHandle(at x: CGFloat, in trackRect: NSRect, colors: TimelineColors) {
        let rect = handleRect(at: x, in: trackRect)
        let path = NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4)
        colors.handleFill.setFill()
        path.fill()
        colors.handleStroke.setStroke()
        path.lineWidth = 1.5
        path.stroke()

        let notchX = rect.midX
        let notchPath = NSBezierPath()
        notchPath.move(to: NSPoint(x: notchX, y: rect.minY + 8))
        notchPath.line(to: NSPoint(x: notchX, y: rect.maxY - 8))
        colors.tick.setStroke()
        notchPath.lineWidth = 1
        notchPath.stroke()
    }

    private func drawPlayhead(in trackRect: NSRect, colors: TimelineColors) {
        let x = playheadX
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
