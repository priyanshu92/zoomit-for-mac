import AppKit
import AppCore
import PlatformServices

@MainActor
final class ZoomOverlayController {
    enum Mode {
        case zoom
        case liveZoom

        var title: String {
            switch self {
            case .zoom: return "Zoom"
            case .liveZoom: return "Live Zoom"
            }
        }
    }

    private let screenCaptureService: ScreenCaptureService
    private let settingsStore: AppSettingsStore
    private let onStartDrawingFromZoom: (NSImage, CGRect) -> Void
    private var activeMode: Mode?
    private var overlayWindow: NSWindow?
    private weak var overlayView: ZoomOverlayView?
    private var refreshTimer: Timer?
    private var keyMonitor: Any?
    private var zoomFactor: CGFloat = 2.0
    private var trackedMouseLocation: CGPoint = .zero
    private var manualPanOffset: CGPoint = .zero
    private var isFrozen = false
    private var frozenSnapshot: ScreenSnapshot?
    private var lastRenderedImage: NSImage?
    private var lastRenderedFrame: CGRect?

    init(
        screenCaptureService: ScreenCaptureService,
        settingsStore: AppSettingsStore,
        onStartDrawingFromZoom: @escaping (NSImage, CGRect) -> Void
    ) {
        self.screenCaptureService = screenCaptureService
        self.settingsStore = settingsStore
        self.onStartDrawingFromZoom = onStartDrawingFromZoom
    }

    func toggle(_ mode: Mode, preCapturedImage: CGImage? = nil) {
        if activeMode == mode {
            dismiss()
            return
        }

        dismiss()
        activeMode = mode
        zoomFactor = CGFloat(max(1.25, settingsStore.load().initialZoomFactor))
        trackedMouseLocation = NSEvent.mouseLocation
        manualPanOffset = .zero
        isFrozen = false

        if mode == .zoom {
            if let preCapturedImage {
                frozenSnapshot = makeSnapshot(from: preCapturedImage)
            }
            if frozenSnapshot == nil {
                frozenSnapshot = screenCaptureService.captureScreen(containing: trackedMouseLocation)
            }
        }

        renderSnapshot()

        if mode == .liveZoom {
            // Make overlay click-through so user can interact with apps underneath
            overlayWindow?.ignoresMouseEvents = true

            refreshTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    self?.renderSnapshot()
                }
            }

            // Use global key monitor since the window doesn't receive keyboard events
            keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
                DispatchQueue.main.async {
                    self?.handleLiveZoomKeyEvent(event)
                }
            }
        }
    }

    func startLiveDraw(preCapturedImage: CGImage? = nil) {
        toggle(.liveZoom, preCapturedImage: preCapturedImage)
        startDrawingFromCurrentZoom()
    }

    func dismiss() {
        refreshTimer?.invalidate()
        refreshTimer = nil
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
        overlayWindow?.orderOut(nil)
        overlayWindow = nil
        overlayView = nil
        activeMode = nil
        manualPanOffset = .zero
        isFrozen = false
        frozenSnapshot = nil
        lastRenderedImage = nil
        lastRenderedFrame = nil
    }

    private func handleLiveZoomKeyEvent(_ event: NSEvent) {
        switch event.keyCode {
        case 53: // Esc
            dismiss()
        case 126: // Up arrow
            adjustZoom(by: 0.2)
        case 125: // Down arrow
            adjustZoom(by: -0.2)
        default:
            break
        }
    }

    private func renderSnapshot() {
        guard let activeMode else {
            dismiss()
            return
        }

        if !isFrozen {
            trackedMouseLocation = NSEvent.mouseLocation
        }

        let snapshot: ScreenSnapshot
        if let frozenSnapshot {
            snapshot = frozenSnapshot
        } else if let liveSnapshot = captureExcludingOverlay() {
            snapshot = liveSnapshot
        } else {
            return
        }

        let targetPoint = clampedTargetPoint(in: snapshot)
        let croppedImage = crop(snapshot: snapshot, around: targetPoint)
        let screen = NSScreen.screens.first(where: { $0.frame == snapshot.screenFrame })
        let window = overlayWindow ?? makeWindow(frame: snapshot.screenFrame, screen: screen)
        let overlayView = overlayView ?? makeOverlayView(size: snapshot.screenFrame.size)
        let renderedImage = NSImage(cgImage: croppedImage, size: snapshot.screenFrame.size)

        if self.overlayView == nil {
            window.contentView = overlayView
            self.overlayView = overlayView
            overlayWindow = window
            overlayView.clickDrawEnabled = activeMode == .zoom
        }

        lastRenderedImage = renderedImage
        lastRenderedFrame = snapshot.screenFrame
        overlayView.setImage(renderedImage)
        overlayView.updateHUD(mode: activeMode, zoomFactor: zoomFactor, isFrozen: isFrozen, panOffset: manualPanOffset)

        if window.frame != snapshot.screenFrame {
            window.setFrame(snapshot.screenFrame, display: true)
        }

        NSApp.activate(ignoringOtherApps: true)
        window.setFrame(snapshot.screenFrame, display: true)
        window.orderFrontRegardless()
        window.makeKey()
        window.makeFirstResponder(overlayView)
    }

    private func clampedTargetPoint(in snapshot: ScreenSnapshot) -> CGPoint {
        let screenFrame = snapshot.screenFrame
        let candidate = CGPoint(x: trackedMouseLocation.x + manualPanOffset.x, y: trackedMouseLocation.y + manualPanOffset.y)
        let clampedPoint = CGPoint(
            x: clamp(candidate.x, min: screenFrame.minX, max: screenFrame.maxX),
            y: clamp(candidate.y, min: screenFrame.minY, max: screenFrame.maxY)
        )
        manualPanOffset = CGPoint(x: clampedPoint.x - trackedMouseLocation.x, y: clampedPoint.y - trackedMouseLocation.y)
        return clampedPoint
    }

    private func crop(snapshot: ScreenSnapshot, around targetPoint: CGPoint) -> CGImage {
        let screenFrame = snapshot.screenFrame
        let image = snapshot.image
        let scale = snapshot.scaleFactor

        let pixelWidth = CGFloat(image.width)
        let pixelHeight = CGFloat(image.height)
        let cropWidth = pixelWidth / zoomFactor
        let cropHeight = pixelHeight / zoomFactor

        let localX = (targetPoint.x - screenFrame.minX) * scale
        let localY = (targetPoint.y - screenFrame.minY) * scale
        let flippedY = pixelHeight - localY

        let originX = clamp(localX - cropWidth / 2, min: 0, max: pixelWidth - cropWidth)
        let originY = clamp(flippedY - cropHeight / 2, min: 0, max: pixelHeight - cropHeight)
        let cropRect = CGRect(x: originX, y: originY, width: cropWidth, height: cropHeight).integral

        return image.cropping(to: cropRect) ?? image
    }

    private func makeWindow(frame: CGRect, screen: NSScreen?) -> NSWindow {
        let window = OverlayWindow(
            contentRect: frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false,
            screen: screen
        )
        window.isOpaque = true
        window.backgroundColor = .black
        window.level = .screenSaver
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window.hasShadow = false
        window.acceptsMouseMovedEvents = true
        window.sharingType = .none
        return window
    }

    private func makeOverlayView(size: CGSize) -> ZoomOverlayView {
        let overlayView = ZoomOverlayView(frame: CGRect(origin: .zero, size: size))
        overlayView.onDismiss = { [weak self] in
            self?.dismiss()
        }
        overlayView.onAdjustZoom = { [weak self] delta in
            self?.adjustZoom(by: delta)
        }
        overlayView.onPan = { [weak self] delta in
            self?.pan(by: delta)
        }
        overlayView.onRecenter = { [weak self] in
            self?.recenter()
        }
        overlayView.onToggleFreeze = { [weak self] in
            self?.toggleFreeze()
        }
        overlayView.onPointerMoved = { [weak self] point in
            self?.updateTrackedMouseLocation(point)
        }
        overlayView.onStartDrawing = { [weak self] in
            self?.startDrawingFromCurrentZoom()
        }
        return overlayView
    }

    private func updateTrackedMouseLocation(_ point: CGPoint) {
        guard activeMode != nil else { return }

        if activeMode == .zoom {
            // Zoom mode: mouse movement pans around the frozen capture
            trackedMouseLocation = point
            renderSnapshot()
            return
        }

        // Live zoom: only follow mouse when not frozen
        guard !isFrozen else { return }
        trackedMouseLocation = point
        renderSnapshot()
    }

    private func adjustZoom(by delta: CGFloat) {
        zoomFactor = clamp(zoomFactor + delta, min: 1.25, max: 8.0)
        renderSnapshot()
    }

    private func pan(by delta: CGPoint) {
        if activeMode == .liveZoom {
            isFrozen = true
        }

        manualPanOffset.x += delta.x
        manualPanOffset.y += delta.y
        renderSnapshot()
    }

    private func recenter() {
        trackedMouseLocation = NSEvent.mouseLocation
        manualPanOffset = .zero
        if activeMode == .liveZoom {
            isFrozen = false
        }
        renderSnapshot()
    }

    private func toggleFreeze() {
        guard let activeMode else { return }

        if activeMode == .zoom {
            recenter()
            return
        }

        isFrozen.toggle()
        if !isFrozen {
            trackedMouseLocation = NSEvent.mouseLocation
            manualPanOffset = .zero
        }
        renderSnapshot()
    }

    private func startDrawingFromCurrentZoom() {
        guard let image = lastRenderedImage, let frame = lastRenderedFrame else { return }
        dismiss()
        onStartDrawingFromZoom(image, frame)
    }

    private func clamp(_ value: CGFloat, min lowerBound: CGFloat, max upperBound: CGFloat) -> CGFloat {
        Swift.max(lowerBound, Swift.min(value, upperBound))
    }

    private func captureExcludingOverlay() -> ScreenSnapshot? {
        guard
            let screen = NSScreen.screens.first(where: { $0.frame.contains(trackedMouseLocation) }),
            let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
        else {
            return nil
        }

        let bounds = CGDisplayBounds(displayID)
        let image: CGImage?

        if let overlayWindow, overlayWindow.windowNumber > 0 {
            image = CGWindowListCreateImage(
                bounds,
                .optionOnScreenBelowWindow,
                CGWindowID(overlayWindow.windowNumber),
                .bestResolution
            )
        } else {
            image = CGWindowListCreateImage(
                bounds,
                .optionOnScreenOnly,
                kCGNullWindowID,
                .bestResolution
            )
        }

        guard let image else { return nil }

        return ScreenSnapshot(
            displayID: displayID,
            image: image,
            screenFrame: screen.frame,
            scaleFactor: screen.backingScaleFactor
        )
    }

    private func makeSnapshot(from image: CGImage) -> ScreenSnapshot? {
        let mouseLocation = NSEvent.mouseLocation
        guard
            let screen = NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) }),
            let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
        else {
            return nil
        }
        return ScreenSnapshot(
            displayID: displayID,
            image: image,
            screenFrame: screen.frame,
            scaleFactor: screen.backingScaleFactor
        )
    }
}

@MainActor
private final class ZoomOverlayView: NSView {
    var onDismiss: (() -> Void)?
    var onAdjustZoom: ((CGFloat) -> Void)?
    var onPan: ((CGPoint) -> Void)?
    var onRecenter: (() -> Void)?
    var onToggleFreeze: (() -> Void)?
    var onPointerMoved: ((CGPoint) -> Void)?
    var onStartDrawing: (() -> Void)?
    var clickDrawEnabled = false

    private let imageView = NSImageView()
    private let badgeLabel = NSTextField(labelWithString: "")
    private let controlsLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private var lastDragLocation: CGPoint?
    private var hasDragged = false

    override var acceptsFirstResponder: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        setupImageView()
        setupHUD()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setImage(_ image: NSImage) {
        imageView.image = image
    }

    func updateHUD(mode: ZoomOverlayController.Mode, zoomFactor: CGFloat, isFrozen: Bool, panOffset: CGPoint) {
        let stateDescription: String
        switch mode {
        case .zoom:
            stateDescription = "Pinned"
        case .liveZoom:
            stateDescription = isFrozen ? "Frozen" : "Following cursor"
        }

        badgeLabel.stringValue = "\(mode.title) • \(String(format: "%.1fx", zoomFactor)) • \(stateDescription)"
        controlsLabel.stringValue = mode == .liveZoom
            ? "Up/Down zoom • Drag or A/W/S/D pans • Space toggles follow • Right click/Esc exits"
            : "Click to draw • Up/Down zoom • Drag or A/W/S/D pans • Space recenters • Right click/Esc exits"

        if abs(panOffset.x) < 1, abs(panOffset.y) < 1 {
            statusLabel.stringValue = isFrozen ? "Focused on the selected point" : "Centered on the cursor"
        } else {
            statusLabel.stringValue = String(format: "Pan offset  x:%+.0f  y:%+.0f", panOffset.x, panOffset.y)
        }
    }

    override func keyDown(with event: NSEvent) {
        let panStep: CGFloat = event.modifierFlags.contains(.shift) ? 120 : 48

        switch event.keyCode {
        case 123:
            onPan?(CGPoint(x: -panStep, y: 0))
        case 124:
            onPan?(CGPoint(x: panStep, y: 0))
        case 125:
            onAdjustZoom?(-0.2)
        case 126:
            onAdjustZoom?(0.2)
        default:
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "\u{1b}":
                onDismiss?()
            case "+", "=":
                onAdjustZoom?(0.2)
            case "-", "_":
                onAdjustZoom?(-0.2)
            case "0":
                onRecenter?()
            case " ":
                onToggleFreeze?()
            case "w":
                onPan?(CGPoint(x: 0, y: panStep))
            case "a":
                onPan?(CGPoint(x: -panStep, y: 0))
            case "s":
                onPan?(CGPoint(x: 0, y: -panStep))
            case "d":
                onPan?(CGPoint(x: panStep, y: 0))
            default:
                super.keyDown(with: event)
            }
        }
    }

    override func cancelOperation(_ sender: Any?) {
        onDismiss?()
    }

    override func mouseMoved(with event: NSEvent) {
        onPointerMoved?(globalPoint(for: event.locationInWindow))
    }

    override func mouseDown(with event: NSEvent) {
        lastDragLocation = globalPoint(for: event.locationInWindow)
        hasDragged = false
    }

    override func mouseDragged(with event: NSEvent) {
        let currentLocation = globalPoint(for: event.locationInWindow)
        defer { lastDragLocation = currentLocation }

        guard let lastDragLocation else {
            return
        }

        let delta = CGPoint(x: currentLocation.x - lastDragLocation.x, y: currentLocation.y - lastDragLocation.y)
        if abs(delta.x) > 1 || abs(delta.y) > 1 {
            hasDragged = true
        }
        onPan?(delta)
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            lastDragLocation = nil
            hasDragged = false
        }

        if clickDrawEnabled, !hasDragged {
            onStartDrawing?()
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        onDismiss?()
    }

    override func scrollWheel(with event: NSEvent) {
        if abs(event.scrollingDeltaY) >= abs(event.scrollingDeltaX) {
            onAdjustZoom?(event.scrollingDeltaY > 0 ? 0.15 : -0.15)
        } else {
            onPan?(CGPoint(x: -event.scrollingDeltaX * 6, y: 0))
        }
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .arrow)
    }

    private func setupImageView() {
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.imageScaling = .scaleAxesIndependently
        imageView.animates = false
        addSubview(imageView)

        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: trailingAnchor),
            imageView.topAnchor.constraint(equalTo: topAnchor),
            imageView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    private func setupHUD() {
        let topHUD = makeHUDContainer()
        let bottomHUD = makeHUDContainer()
        let titleStack = NSStackView(views: [badgeLabel, controlsLabel])
        titleStack.translatesAutoresizingMaskIntoConstraints = false
        titleStack.orientation = .vertical
        titleStack.spacing = 8
        titleStack.alignment = .centerX

        configureLabel(badgeLabel, font: .systemFont(ofSize: 22, weight: .semibold), alpha: 0.98)
        configureLabel(controlsLabel, font: .systemFont(ofSize: 14, weight: .medium), alpha: 0.85)
        configureLabel(statusLabel, font: .monospacedSystemFont(ofSize: 13, weight: .medium), alpha: 0.9)

        topHUD.addSubview(titleStack)
        bottomHUD.addSubview(statusLabel)
        addSubview(topHUD)
        addSubview(bottomHUD)

        NSLayoutConstraint.activate([
            topHUD.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor, constant: 22),
            topHUD.centerXAnchor.constraint(equalTo: centerXAnchor),
            titleStack.leadingAnchor.constraint(equalTo: topHUD.leadingAnchor, constant: 22),
            titleStack.trailingAnchor.constraint(equalTo: topHUD.trailingAnchor, constant: -22),
            titleStack.topAnchor.constraint(equalTo: topHUD.topAnchor, constant: 18),
            titleStack.bottomAnchor.constraint(equalTo: topHUD.bottomAnchor, constant: -18),

            bottomHUD.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.bottomAnchor, constant: -24),
            bottomHUD.centerXAnchor.constraint(equalTo: centerXAnchor),
            statusLabel.leadingAnchor.constraint(equalTo: bottomHUD.leadingAnchor, constant: 20),
            statusLabel.trailingAnchor.constraint(equalTo: bottomHUD.trailingAnchor, constant: -20),
            statusLabel.topAnchor.constraint(equalTo: bottomHUD.topAnchor, constant: 14),
            statusLabel.bottomAnchor.constraint(equalTo: bottomHUD.bottomAnchor, constant: -14),
        ])
    }

    private func makeHUDContainer() -> NSVisualEffectView {
        let container = NSVisualEffectView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.material = .hudWindow
        container.blendingMode = .withinWindow
        container.state = .active
        container.wantsLayer = true
        container.layer?.cornerRadius = 18
        container.layer?.masksToBounds = true
        return container
    }

    private func configureLabel(_ label: NSTextField, font: NSFont, alpha: CGFloat) {
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = font
        label.textColor = .white.withAlphaComponent(alpha)
        label.alignment = .center
        label.maximumNumberOfLines = 2
        label.lineBreakMode = .byWordWrapping
    }

    private func globalPoint(for pointInWindow: CGPoint) -> CGPoint {
        guard let window else { return pointInWindow }
        return CGPoint(x: window.frame.minX + pointInWindow.x, y: window.frame.minY + pointInWindow.y)
    }
}
