import AppCore
import AppKit
import PlatformServices

@MainActor
final class DrawOverlayController {
    private let settingsStore: AppSettingsStore
    private let screenCaptureService: ScreenCaptureService
    private var window: NSWindow?
    private var canvasView: DrawingCanvasView?
    var onShortcutAction: ((ShortcutAction) -> Void)?

    init(settingsStore: AppSettingsStore, screenCaptureService: ScreenCaptureService) {
        self.settingsStore = settingsStore
        self.screenCaptureService = screenCaptureService
    }

    func toggle(preCapturedImage: CGImage? = nil) {
        if window == nil {
            present(preCapturedImage: preCapturedImage)
        } else {
            dismiss()
        }
    }

    func beginOverlay(with frozenBackgroundImage: NSImage?, screenFrame: CGRect? = nil) {
        dismiss()
        present(backgroundImage: frozenBackgroundImage, frame: screenFrame)
    }

    var isActive: Bool {
        window != nil
    }

    func currentSnapshot() -> ScreenSnapshot? {
        guard
            let window,
            let canvasView,
            let renderedImage = canvasView.renderSnapshot(),
            let screen = window.screen ?? NSScreen.screens.first(where: { $0.frame == window.frame }),
            let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
        else {
            return nil
        }

        return ScreenSnapshot(
            displayID: displayID,
            image: renderedImage,
            screenFrame: window.frame,
            scaleFactor: screen.backingScaleFactor
        )
    }

    func dismiss() {
        window?.orderOut(nil)
        window = nil
        canvasView = nil
    }

    private func present(preCapturedImage: CGImage? = nil) {
        let mouseLocation = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) }) ?? NSScreen.main ?? NSScreen.screens.first else {
            return
        }

        let backgroundImage: NSImage?
        if let preCapturedImage {
            backgroundImage = NSImage(cgImage: preCapturedImage, size: screen.frame.size)
        } else {
            let capturePoint = CGPoint(x: screen.frame.midX, y: screen.frame.midY)
            let frozenSnapshot = screenCaptureService.captureScreen(containing: capturePoint)
            backgroundImage = frozenSnapshot.map { NSImage(cgImage: $0.image, size: screen.frame.size) }
        }
        present(backgroundImage: backgroundImage, frame: screen.frame)
    }

    private func present(backgroundImage: NSImage?, frame: CGRect?) {
        let mouseLocation = NSEvent.mouseLocation
        guard let screenFrame = frame ?? NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) })?.frame ?? NSScreen.screens.first?.frame else {
            return
        }
        let screen = NSScreen.screens.first(where: { $0.frame == screenFrame }) ?? NSScreen.screens.first

        let window = OverlayWindow(
            contentRect: screenFrame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false,
            screen: screen
        )
        window.level = .screenSaver
        window.backgroundColor = NSColor.clear
        window.isOpaque = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.acceptsMouseMovedEvents = true

        let canvas = DrawingCanvasView(
            frame: CGRect(origin: .zero, size: screenFrame.size),
            settingsStore: settingsStore,
            frozenBackgroundImage: backgroundImage,
            onShortcutAction: { [weak self] action in
                self?.onShortcutAction?(action)
            },
            onRequestDismiss: { [weak self] in
                self?.dismiss()
            }
        )
        canvas.autoresizingMask = [.width, .height]
        window.contentView = canvas

        self.window = window
        self.canvasView = canvas

        NSApp.activate(ignoringOtherApps: true)
        window.setFrame(screenFrame, display: true)
        window.orderFrontRegardless()
        window.makeKey()
        window.makeFirstResponder(canvas)
    }
}

@MainActor
private final class DrawingCanvasView: NSView {
    private enum BackgroundMode {
        case captured
        case whiteboard
        case blackboard

        var title: String {
            switch self {
            case .captured: return "Screen"
            case .whiteboard: return "Whiteboard"
            case .blackboard: return "Blackboard"
            }
        }
    }

    private enum InkColor: CaseIterable {
        case red
        case green
        case blue
        case yellow
        case orange
        case pink

        var title: String {
            switch self {
            case .red: return "Red"
            case .green: return "Green"
            case .blue: return "Blue"
            case .yellow: return "Yellow"
            case .orange: return "Orange"
            case .pink: return "Pink"
            }
        }

        var color: NSColor {
            switch self {
            case .red: return .systemRed
            case .green: return .systemGreen
            case .blue: return .systemBlue
            case .yellow: return .systemYellow
            case .orange: return .systemOrange
            case .pink: return .systemPink
            }
        }
    }

    private enum ToolMode: Equatable {
        case ink(color: InkColor, highlight: Bool)
        case blur
        case text(alignment: NSTextAlignment)

        var title: String {
            switch self {
            case let .ink(color, highlight):
                return highlight ? "\(color.title) Highlight" : "\(color.title) Pen"
            case .blur:
                return "Blur Pen"
            case let .text(alignment):
                return alignment == .right ? "Right-aligned Text" : "Text"
            }
        }

        var hint: String {
            switch self {
            case .ink:
                return "Hold Shift for line, Ctrl for rectangle, Tab for ellipse, Ctrl+Shift for arrow"
            case .blur:
                return "Mask content with an opaque brush"
            case let .text(alignment):
                return alignment == .right ? "Click to place right-aligned text" : "Click to place left-aligned text"
            }
        }

        var usesTextSizing: Bool {
            if case .text = self {
                return true
            }
            return false
        }
    }

    private enum ShapeKind {
        case freehand
        case line
        case rectangle
        case ellipse
        case arrow
    }

    private enum Annotation {
        case stroke(StrokeAnnotation)
        case text(TextAnnotation)
    }

    private struct StrokeAnnotation {
        let shape: ShapeKind
        let path: NSBezierPath
        let color: NSColor
        let lineWidth: CGFloat
        let isBlur: Bool
    }

    private struct TextAnnotation {
        let point: CGPoint
        let text: String
        let fontSize: CGFloat
        let color: NSColor
        let backgroundColor: NSColor
        let alignment: NSTextAlignment
    }

    private let settingsStore: AppSettingsStore
    private let frozenBackgroundImage: NSImage?
    private let onShortcutAction: (ShortcutAction) -> Void
    private let onRequestDismiss: () -> Void
    private let transientOverlay = NSVisualEffectView()
    private let transientLabel = NSTextField(labelWithString: "")
    private weak var activeTextField: InlineAnnotationTextField?
    private var transientHideTask: DispatchWorkItem?
    private var trackingAreaRef: NSTrackingArea?
    private var currentMode: ToolMode = .ink(color: .red, highlight: false) {
        didSet {
            window?.invalidateCursorRects(for: self)
            if window != nil {
                flashMessage("\(currentMode.title) — \(currentMode.hint)")
            }
            needsDisplay = true
        }
    }
    private var backgroundMode: BackgroundMode = .captured {
        didSet {
            needsDisplay = true
        }
    }
    private var annotations: [Annotation] = []
    private var currentStroke: StrokeAnnotation?
    private var dragStartPoint: CGPoint?
    private var pointerLocation: CGPoint?
    private var strokeSize: CGFloat = 6
    private var typingFontSize: CGFloat
    private var isTabShapeModifierActive = false

    override var acceptsFirstResponder: Bool { true }

    init(
        frame frameRect: NSRect,
        settingsStore: AppSettingsStore,
        frozenBackgroundImage: NSImage?,
        onShortcutAction: @escaping (ShortcutAction) -> Void,
        onRequestDismiss: @escaping () -> Void
    ) {
        self.settingsStore = settingsStore
        self.frozenBackgroundImage = frozenBackgroundImage
        self.onShortcutAction = onShortcutAction
        self.onRequestDismiss = onRequestDismiss
        self.typingFontSize = settingsStore.load().validatedAnnotationFontSize
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        setupTransientOverlay()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()

        if let trackingAreaRef {
            removeTrackingArea(trackingAreaRef)
        }

        let trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        trackingAreaRef = trackingArea
    }

    override func draw(_ dirtyRect: NSRect) {
        drawBackground(in: dirtyRect)

        for annotation in annotations {
            draw(annotation)
        }

        if let currentStroke {
            draw(currentStroke)
        }

        drawCursorPreview()
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 48 {
            isTabShapeModifierActive = true
            return
        }

        if let shortcutAction = embeddedShortcutAction(for: event) {
            onShortcutAction(shortcutAction)
            return
        }

        if (event.modifierFlags.contains(.command) || event.modifierFlags.contains(.control)),
           event.charactersIgnoringModifiers?.lowercased() == "z" {
            undoLastAnnotation()
            return
        }

        switch event.keyCode {
        case 123, 125:
            adjustSizing(by: -2)
            return
        case 124, 126:
            adjustSizing(by: 2)
            return
        default:
            break
        }

        switch event.charactersIgnoringModifiers?.lowercased() {
        case "r": currentMode = .ink(color: .red, highlight: event.modifierFlags.contains(.shift))
        case "g": currentMode = .ink(color: .green, highlight: event.modifierFlags.contains(.shift))
        case "b": currentMode = .ink(color: .blue, highlight: event.modifierFlags.contains(.shift))
        case "y": currentMode = .ink(color: .yellow, highlight: event.modifierFlags.contains(.shift))
        case "o": currentMode = .ink(color: .orange, highlight: event.modifierFlags.contains(.shift))
        case "p": currentMode = .ink(color: .pink, highlight: event.modifierFlags.contains(.shift))
        case "x": currentMode = .blur
        case "t": currentMode = .text(alignment: event.modifierFlags.contains(.shift) ? .right : .left)
        case "w": toggleBackgroundMode(.whiteboard)
        case "k": toggleBackgroundMode(.blackboard)
        case "e", "c":
            clearAnnotations()
        case "u", "\u{7f}":
            undoLastAnnotation()
        case "/", "?":
            showHelp()
        case " ":
            centerCursor()
        case "\u{1b}":
            cancelTextEditing()
            onRequestDismiss()
        default:
            super.keyDown(with: event)
        }
    }

    override func keyUp(with event: NSEvent) {
        if event.keyCode == 48 {
            isTabShapeModifierActive = false
            return
        }

        super.keyUp(with: event)
    }

    override func cancelOperation(_ sender: Any?) {
        cancelTextEditing()
        onRequestDismiss()
    }

    override func mouseMoved(with event: NSEvent) {
        pointerLocation = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    override func mouseEntered(with event: NSEvent) {
        pointerLocation = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        pointerLocation = nil
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        pointerLocation = convert(event.locationInWindow, from: nil)
        commitActiveTextIfNeeded()
        let point = convert(event.locationInWindow, from: nil)

        if currentMode.usesTextSizing {
            beginTextAnnotation(at: point)
            return
        }

        dragStartPoint = point
        currentStroke = makeStroke(from: point, to: point, shape: shapeKind(for: event.modifierFlags))
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let dragStartPoint else { return }
        let point = convert(event.locationInWindow, from: nil)
        pointerLocation = point

        if currentStroke?.shape == .freehand {
            currentStroke?.path.line(to: point)
        } else {
            currentStroke = makeStroke(from: dragStartPoint, to: point, shape: shapeKind(for: event.modifierFlags))
        }

        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        pointerLocation = convert(event.locationInWindow, from: nil)
        defer {
            currentStroke = nil
            dragStartPoint = nil
            needsDisplay = true
        }

        guard let currentStroke else { return }
        annotations.append(.stroke(currentStroke))
    }

    override func rightMouseDown(with event: NSEvent) {
        cancelTextEditing()
        onRequestDismiss()
    }

    override func scrollWheel(with event: NSEvent) {
        pointerLocation = convert(event.locationInWindow, from: nil)

        guard event.modifierFlags.contains(.control) else {
            super.scrollWheel(with: event)
            return
        }

        adjustSizing(by: event.scrollingDeltaY > 0 ? 2 : -2)
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: currentMode.usesTextSizing ? .iBeam : .crosshair)
    }

    private func drawBackground(in dirtyRect: NSRect) {
        switch backgroundMode {
        case .captured:
            if let frozenBackgroundImage {
                frozenBackgroundImage.draw(in: bounds)
            } else {
                NSColor.black.setFill()
                dirtyRect.fill()
            }
        case .whiteboard:
            NSColor.white.setFill()
            dirtyRect.fill()
        case .blackboard:
            NSColor.black.setFill()
            dirtyRect.fill()
        }
    }

    private func setupTransientOverlay() {
        transientOverlay.translatesAutoresizingMaskIntoConstraints = false
        transientOverlay.material = .hudWindow
        transientOverlay.blendingMode = .withinWindow
        transientOverlay.state = .active
        transientOverlay.wantsLayer = true
        transientOverlay.layer?.cornerRadius = 14
        transientOverlay.layer?.masksToBounds = true
        transientOverlay.isHidden = true

        transientLabel.translatesAutoresizingMaskIntoConstraints = false
        transientLabel.font = .systemFont(ofSize: 14, weight: .medium)
        transientLabel.textColor = .white.withAlphaComponent(0.95)
        transientLabel.maximumNumberOfLines = 5
        transientLabel.lineBreakMode = .byWordWrapping

        addSubview(transientOverlay)
        transientOverlay.addSubview(transientLabel)

        NSLayoutConstraint.activate([
            transientOverlay.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor, constant: 18),
            transientOverlay.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            transientOverlay.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -18),

            transientLabel.leadingAnchor.constraint(equalTo: transientOverlay.leadingAnchor, constant: 16),
            transientLabel.trailingAnchor.constraint(equalTo: transientOverlay.trailingAnchor, constant: -16),
            transientLabel.topAnchor.constraint(equalTo: transientOverlay.topAnchor, constant: 12),
            transientLabel.bottomAnchor.constraint(equalTo: transientOverlay.bottomAnchor, constant: -12),
        ])
    }

    private func flashMessage(_ message: String, duration: TimeInterval = 1.8) {
        transientHideTask?.cancel()
        transientLabel.stringValue = message
        transientOverlay.alphaValue = 1
        transientOverlay.isHidden = false

        let hideTask = DispatchWorkItem { [weak self] in
            guard let self else { return }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                self.transientOverlay.animator().alphaValue = 0
            } completionHandler: {
                Task { @MainActor [weak self] in
                    self?.transientOverlay.isHidden = true
                }
            }
        }
        transientHideTask = hideTask
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: hideTask)
    }

    private func showHelp() {
        flashMessage(
            "Left click draws • Hold Shift line • Hold Ctrl rectangle • Hold Tab ellipse • Hold Ctrl+Shift arrow • W whiteboard • K blackboard • T/Shift+T text • Ctrl+scroll or arrows size • E clear • ⌘Z undo • Space center • Esc/right-click exit",
            duration: 5
        )
    }

    private func toggleBackgroundMode(_ target: BackgroundMode) {
        backgroundMode = backgroundMode == target ? .captured : target
        let detail = backgroundMode == .captured ? "Returned to frozen screen" : "Switched to \(backgroundMode.title.lowercased())"
        flashMessage("\(backgroundMode.title) — \(detail)")
    }

    private func shapeKind(for modifierFlags: NSEvent.ModifierFlags) -> ShapeKind {
        if case .blur = currentMode {
            return .freehand
        }

        if modifierFlags.contains(.control), modifierFlags.contains(.shift) {
            return .arrow
        }
        if isTabShapeModifierActive {
            return .ellipse
        }
        if modifierFlags.contains(.control) {
            return .rectangle
        }
        if modifierFlags.contains(.shift) {
            return .line
        }
        return .freehand
    }

    private func makeStroke(from start: CGPoint, to end: CGPoint, shape: ShapeKind) -> StrokeAnnotation {
        let path = NSBezierPath()

        switch shape {
        case .freehand:
            path.move(to: start)
            path.line(to: end)
        case .rectangle:
            path.appendRect(CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x), height: abs(end.y - start.y)))
        case .ellipse:
            path.appendOval(in: CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x), height: abs(end.y - start.y)))
        case .line:
            path.move(to: start)
            path.line(to: end)
        case .arrow:
            path.move(to: end)
            path.line(to: start)
            let angle = atan2(start.y - end.y, start.x - end.x)
            let arrowLength: CGFloat = max(18, effectiveStrokeWidth * 3)
            let arrowAngle: CGFloat = .pi / 7
            path.move(to: start)
            path.line(to: CGPoint(x: start.x - arrowLength * cos(angle - arrowAngle), y: start.y - arrowLength * sin(angle - arrowAngle)))
            path.move(to: start)
            path.line(to: CGPoint(x: start.x - arrowLength * cos(angle + arrowAngle), y: start.y - arrowLength * sin(angle + arrowAngle)))
        }

        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        return StrokeAnnotation(
            shape: shape,
            path: path,
            color: effectiveStrokeColor,
            lineWidth: effectiveStrokeWidth,
            isBlur: {
                if case .blur = currentMode {
                    return true
                }
                return false
            }()
        )
    }

    private func beginTextAnnotation(at point: CGPoint) {
        cancelTextEditing()

        let width: CGFloat = 360
        let x: CGFloat
        if case let .text(alignment) = currentMode, alignment == .right {
            x = clamp(point.x - width, min: 18, max: max(18, bounds.width - width - 18))
        } else {
            x = clamp(point.x, min: 18, max: max(18, bounds.width - width - 18))
        }
        let y = clamp(point.y, min: 18, max: max(18, bounds.height - 44))

        let field = InlineAnnotationTextField(frame: NSRect(x: x, y: y, width: width, height: 36))
        field.placeholderString = ""
        field.font = .systemFont(ofSize: typingFontSize)
        field.drawsBackground = false
        field.backgroundColor = .clear
        field.isBordered = false
        field.focusRingType = .none

        // Use current ink color for text, or white if in blur/non-ink mode
        let textColor: NSColor
        if case let .text(alignment) = currentMode {
            field.alignment = alignment
        }
        if case let .ink(color, _) = currentMode {
            textColor = color.color
        } else {
            textColor = .white
        }
        field.textColor = textColor
        field.onCommit = { [weak self, weak field] text in
            self?.finishTextAnnotation(text, from: field)
        }
        field.onCancel = { [weak self, weak field] in
            self?.cancelTextEditing(field)
            self?.onRequestDismiss()
        }
        field.onAdjustSize = { [weak self] delta in
            self?.adjustFontSize(by: delta)
        }
        field.onShortcutAction = { [weak self] action in
            self?.onShortcutAction(action)
        }

        addSubview(field)
        activeTextField = field
        window?.makeFirstResponder(field)
    }

    private func finishTextAnnotation(_ text: String, from field: InlineAnnotationTextField?) {
        guard let field else {
            cancelTextEditing()
            return
        }

        let origin = field.frame.origin
        let alignment = field.alignment
        cancelTextEditing(field)
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else {
            return
        }

        let inkColor: NSColor
        if case let .ink(color, _) = currentMode {
            inkColor = color.color
        } else {
            inkColor = .white
        }

        annotations.append(
            .text(
                TextAnnotation(
                    point: origin,
                    text: trimmedText,
                    fontSize: typingFontSize,
                    color: inkColor,
                    backgroundColor: .clear,
                    alignment: alignment
                )
            )
        )
        needsDisplay = true
    }

    private func cancelTextEditing(_ field: InlineAnnotationTextField? = nil) {
        let field = field ?? activeTextField
        field?.removeFromSuperview()
        if activeTextField === field {
            activeTextField = nil
        }
        window?.makeFirstResponder(self)
    }

    private func commitActiveTextIfNeeded() {
        activeTextField?.commit()
    }

    private func undoLastAnnotation() {
        cancelTextEditing()
        guard !annotations.isEmpty else { return }
        annotations.removeLast()
        needsDisplay = true
        flashMessage(annotations.isEmpty ? "Undid last annotation" : "Undid last annotation • \(annotations.count) remaining")
    }

    private func clearAnnotations() {
        cancelTextEditing()
        annotations.removeAll()
        currentStroke = nil
        needsDisplay = true
        flashMessage("Cleared all annotations")
    }

    private func adjustSizing(by delta: CGFloat) {
        if currentMode.usesTextSizing || activeTextField != nil {
            adjustFontSize(by: delta)
        } else {
            adjustStrokeSize(by: delta)
        }
    }

    private func adjustStrokeSize(by delta: CGFloat) {
        strokeSize = clamp(strokeSize + delta, min: 2, max: 48)
        flashMessage("\(currentMode.title) size \(Int(strokeSize.rounded()))")
        needsDisplay = true
    }

    private func adjustFontSize(by delta: CGFloat) {
        typingFontSize = clamp(typingFontSize + delta, min: 14, max: 96)
        activeTextField?.font = .systemFont(ofSize: typingFontSize)
        flashMessage("Text size \(Int(typingFontSize.rounded()))")
        needsDisplay = true
    }

    private func centerCursor() {
        guard let window else { return }
        let localPoint = CGPoint(x: bounds.midX, y: bounds.midY)
        pointerLocation = localPoint
        let screenPoint = window.convertPoint(toScreen: localPoint)
        CGWarpMouseCursorPosition(screenPoint)
        needsDisplay = true
        flashMessage("Centered cursor")
    }

    private var effectiveStrokeColor: NSColor {
        switch currentMode {
        case let .ink(color, highlight):
            return highlight ? color.color.withAlphaComponent(0.35) : color.color
        case .blur:
            return NSColor.black.withAlphaComponent(0.72)
        case .text:
            return .white
        }
    }

    private var effectiveStrokeWidth: CGFloat {
        switch currentMode {
        case let .ink(_, highlight):
            return highlight ? max(strokeSize * 2.6, strokeSize + 10) : strokeSize
        case .blur:
            return max(strokeSize * 3.4, strokeSize + 16)
        case .text:
            return strokeSize
        }
    }

    private func draw(_ annotation: Annotation) {
        switch annotation {
        case let .stroke(stroke):
            draw(stroke)
        case let .text(text):
            draw(text)
        }
    }

    private func draw(_ stroke: StrokeAnnotation) {
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
        shadow.shadowBlurRadius = 4
        shadow.shadowOffset = NSSize(width: 0, height: -1)
        shadow.set()

        stroke.color.setStroke()
        stroke.path.lineWidth = stroke.lineWidth

        stroke.path.stroke()
        if stroke.isBlur {
            NSColor.white.withAlphaComponent(0.08).setStroke()
            stroke.path.lineWidth = max(1, stroke.lineWidth * 0.16)
            stroke.path.stroke()
        }

        NSGraphicsContext.restoreGraphicsState()
    }

    private func draw(_ text: TextAnnotation) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = text.alignment
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: text.fontSize, weight: .semibold),
            .foregroundColor: text.color,
            .paragraphStyle: paragraph,
        ]
        let string = NSString(string: text.text)
        let textSize = string.size(withAttributes: attributes)
        let originX = text.alignment == .right ? text.point.x - textSize.width - 22 : text.point.x
        let backgroundRect = CGRect(x: originX, y: text.point.y - 4, width: textSize.width + 22, height: textSize.height + 14)

        text.backgroundColor.setFill()
        let backgroundPath = NSBezierPath(roundedRect: backgroundRect, xRadius: 10, yRadius: 10)
        backgroundPath.fill()

        string.draw(
            in: backgroundRect.insetBy(dx: 11, dy: 7),
            withAttributes: attributes
        )
    }

    private func drawCursorPreview() {
        guard !currentMode.usesTextSizing, let pointerLocation, bounds.contains(pointerLocation) else { return }

        NSGraphicsContext.saveGraphicsState()
        let diameter = clamp(effectiveStrokeWidth + 10, min: 14, max: 120)
        let previewRect = CGRect(x: pointerLocation.x - diameter / 2, y: pointerLocation.y - diameter / 2, width: diameter, height: diameter)
        let previewPath = NSBezierPath(ovalIn: previewRect)
        NSColor.white.withAlphaComponent(0.9).setStroke()
        previewPath.lineWidth = 1.5
        previewPath.stroke()
        NSGraphicsContext.restoreGraphicsState()
    }

    private func clamp(_ value: CGFloat, min lowerBound: CGFloat, max upperBound: CGFloat) -> CGFloat {
        Swift.max(lowerBound, Swift.min(value, upperBound))
    }

    private func embeddedShortcutAction(for event: NSEvent) -> ShortcutAction? {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard modifiers.contains(.control), let key = event.charactersIgnoringModifiers?.uppercased() else {
            return nil
        }

        let hasShift = modifiers.contains(.shift)
        let hasOption = modifiers.contains(.option)
        let extraModifiers = modifiers.subtracting([.control, .shift, .option])
        guard extraModifiers.isEmpty else {
            return nil
        }

        switch (key, hasShift, hasOption) {
        case ("6", false, false):
            return .snip
        case ("6", true, false):
            return .saveSnip
        case ("6", false, true):
            return .ocrSnip
        default:
            return nil
        }
    }

    func renderSnapshot() -> CGImage? {
        let previousTransientVisibility = transientOverlay.isHidden
        transientOverlay.isHidden = true
        defer { transientOverlay.isHidden = previousTransientVisibility }

        let bounds = self.bounds
        guard let bitmap = bitmapImageRepForCachingDisplay(in: bounds) else {
            return nil
        }
        cacheDisplay(in: bounds, to: bitmap)
        return bitmap.cgImage
    }
}

@MainActor
private final class InlineAnnotationTextField: NSTextField {
    var onCommit: ((String) -> Void)?
    var onCancel: (() -> Void)?
    var onAdjustSize: ((CGFloat) -> Void)?
    var onShortcutAction: ((ShortcutAction) -> Void)?

    func commit() {
        onCommit?(stringValue)
    }

    override func keyDown(with event: NSEvent) {
        if let shortcutAction = embeddedShortcutAction(for: event) {
            onShortcutAction?(shortcutAction)
            return
        }

        switch event.keyCode {
        case 36, 76:
            commit()
        case 53:
            onCancel?()
        case 123, 125:
            onAdjustSize?(-2)
        case 124, 126:
            onAdjustSize?(2)
        default:
            super.keyDown(with: event)
        }
    }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }

    private func embeddedShortcutAction(for event: NSEvent) -> ShortcutAction? {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard modifiers.contains(.control), let key = event.charactersIgnoringModifiers?.uppercased() else {
            return nil
        }

        let hasShift = modifiers.contains(.shift)
        let hasOption = modifiers.contains(.option)
        let extraModifiers = modifiers.subtracting([.control, .shift, .option])
        guard extraModifiers.isEmpty else {
            return nil
        }

        switch (key, hasShift, hasOption) {
        case ("6", false, false):
            return .snip
        case ("6", true, false):
            return .saveSnip
        case ("6", false, true):
            return .ocrSnip
        default:
            return nil
        }
    }

    override func scrollWheel(with event: NSEvent) {
        if event.modifierFlags.contains(.control) {
            onAdjustSize?(event.scrollingDeltaY > 0 ? 2 : -2)
            return
        }

        super.scrollWheel(with: event)
    }
}
