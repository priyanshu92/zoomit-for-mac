@preconcurrency import AVFoundation
import AppCore
import AppKit
import ApplicationServices
import ImageIO
import PlatformServices
import UniformTypeIdentifiers

@MainActor
struct RecordingToggleResult {
    let title: String
    let message: String
    let shouldPresentAlert: Bool
}

enum RecordingControllerError: LocalizedError {
    case captureUnavailable
    case noFramesCaptured
    case exportFailed
    case invalidDestination(String)
    case selectionCancelled
    case hoveredWindowUnavailable

    var errorDescription: String? {
        switch self {
        case .captureUnavailable:
            return "The selected display could not be captured."
        case .noFramesCaptured:
            return "No frames were captured before recording stopped."
        case .exportFailed:
            return "Recording export could not be finalized."
        case let .invalidDestination(path):
            return "The recording could not be saved to \(path)."
        case .selectionCancelled:
            return "Recording region selection was cancelled."
        case .hoveredWindowUnavailable:
            return "The hovered window could not be determined. Grant Accessibility permission and try again."
        }
    }
}

private enum RecordingMode {
    case fullDisplay
    case selectedRegion(CGRect)
    case hoveredWindow(CGRect)

    var label: String {
        switch self {
        case .fullDisplay:
            return "full screen"
        case .selectedRegion:
            return "cropped region"
        case .hoveredWindow:
            return "hovered window"
        }
    }

    var region: CGRect? {
        switch self {
        case .fullDisplay:
            return nil
        case let .selectedRegion(rect), let .hoveredWindow(rect):
            return rect
        }
    }
}

@MainActor
final class RecordingController {
    private let screenCaptureService: ScreenCaptureService
    private let settingsStore: AppSettingsStore

    private var timer: Timer?
    private var capturedFrames: [CGImage] = []
    private var targetScreenPoint: CGPoint?
    private var targetScreenFrame: CGRect?
    private var targetCaptureRegion: CGRect?
    private var recordingMode: RecordingMode = .fullDisplay
    private var recordingStartedAt: Date?
    private var recordingHighlightWindow: NSWindow?

    init(screenCaptureService: ScreenCaptureService, settingsStore: AppSettingsStore) {
        self.screenCaptureService = screenCaptureService
        self.settingsStore = settingsStore
    }

    var isRecording: Bool {
        timer != nil
    }

    func toggle() throws -> RecordingToggleResult {
        if isRecording {
            return try stop()
        }

        try start(mode: .fullDisplay)
        return startedResult(for: .fullDisplay)
    }

    func toggleCropped() throws -> RecordingToggleResult {
        if isRecording {
            return try stop()
        }

        let region = try selectRecordingRegion()
        let mode = RecordingMode.selectedRegion(region)
        try start(mode: mode)
        return startedResult(for: mode)
    }

    func toggleHoveredWindow() throws -> RecordingToggleResult {
        if isRecording {
            return try stop()
        }

        let frame = try hoveredWindowFrame()
        let mode = RecordingMode.hoveredWindow(frame)
        try start(mode: mode)
        return startedResult(for: mode)
    }

    func cancel() {
        timer?.invalidate()
        timer = nil
        resetRecordingState()
    }

    private func startedResult(for mode: RecordingMode) -> RecordingToggleResult {
        let settings = settingsStore.load()
        return RecordingToggleResult(
            title: "Recording armed",
            message: "Starting \(mode.label) \(settings.recordingFormat.title) recording after a 3-second countdown.",
            shouldPresentAlert: false
        )
    }

    private func start(mode: RecordingMode) throws {
        let targetPoint = NSEvent.mouseLocation
        let capturePoint = mode.region?.center ?? targetPoint
        guard let snapshot = screenCaptureService.captureScreen(containing: capturePoint) else {
            throw RecordingControllerError.captureUnavailable
        }

        capturedFrames.removeAll()
        targetScreenPoint = targetPoint
        targetScreenFrame = snapshot.screenFrame
        targetCaptureRegion = mode.region
        recordingMode = mode
        try runCountdown(on: snapshot.screenFrame, highlighting: mode.region)
        showRecordingHighlightIfNeeded(on: snapshot.screenFrame, highlightedRegion: mode.region)
        capturedFrames.removeAll()
        recordingStartedAt = Date()
        captureFrame()

        let interval = 1.0 / settingsStore.load().validatedRecordingFramesPerSecond
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.captureFrame()
            }
        }
    }

    private func stop() throws -> RecordingToggleResult {
        timer?.invalidate()
        timer = nil

        let completedMode = recordingMode

        defer {
            resetRecordingState()
        }

        guard !capturedFrames.isEmpty else {
            throw RecordingControllerError.noFramesCaptured
        }

        hideRecordingHighlight()

        let settings = settingsStore.load()
        guard let destinationURL = try promptForDestinationURL(for: settings.recordingFormat) else {
            return RecordingToggleResult(
                title: "Recording discarded",
                message: "Recording stopped without saving.",
                shouldPresentAlert: false
            )
        }

        let savedURL: URL
        switch settings.recordingFormat {
        case .gif:
            guard let url = writeGIF(to: destinationURL, settings: settings) else {
                throw RecordingControllerError.exportFailed
            }
            savedURL = url
        case .mp4:
            guard let url = try writeMP4(to: destinationURL, settings: settings) else {
                throw RecordingControllerError.exportFailed
            }
            savedURL = url
        }

        let duration = max(recordingStartedAt?.timeIntervalSinceNow.magnitude ?? 0, Double(capturedFrames.count) / settings.validatedRecordingFramesPerSecond)
        let fileSize = (try? savedURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file

        return RecordingToggleResult(
            title: "Recording saved",
            message: "Saved \(completedMode.label) \(settings.recordingFormat.title) recording (\(capturedFrames.count) frames, \(String(format: "%.1f", duration))s, \(formatter.string(fromByteCount: Int64(fileSize)))) to \(savedURL.path)",
            shouldPresentAlert: true
        )
    }

    private func captureFrame() {
        let point = targetCaptureRegion?.center ?? targetScreenPoint ?? NSEvent.mouseLocation
        guard let snapshot = screenCaptureService.captureScreen(containing: point) else {
            return
        }

        let targetFrame = targetScreenFrame ?? snapshot.screenFrame
        guard snapshot.screenFrame.equalTo(targetFrame) else {
            return
        }

        let frame: CGImage
        if let targetCaptureRegion {
            guard
                let cropRect = CaptureGeometry.cropRect(
                    for: targetCaptureRegion,
                    within: snapshot.screenFrame,
                    scaleFactor: snapshot.scaleFactor
                ),
                let croppedFrame = snapshot.image.cropping(to: cropRect)
            else {
                return
            }
            frame = croppedFrame
        } else {
            frame = snapshot.image
        }

        capturedFrames.append(frame)
    }

    private func selectRecordingRegion() throws -> CGRect {
        let mouseLocation = NSEvent.mouseLocation
        guard
            let snapshot = screenCaptureService.captureScreen(containing: mouseLocation),
            let screen = NSScreen.screens.first(where: { $0.frame == snapshot.screenFrame })
        else {
            throw RecordingControllerError.captureUnavailable
        }

        let selector = RecordingRegionSelector(snapshot: snapshot, screen: screen)
        guard let selection = selector.run() else {
            throw RecordingControllerError.selectionCancelled
        }

        return selection
    }

    private func hoveredWindowFrame() throws -> CGRect {
        let mouseLocation = NSEvent.mouseLocation
        let systemWide = AXUIElementCreateSystemWide()
        var elementReference: AXUIElement?
        let hitTestResult = AXUIElementCopyElementAtPosition(systemWide, Float(mouseLocation.x), Float(mouseLocation.y), &elementReference)

        if hitTestResult == .success,
           let elementReference,
           let window = windowElement(containing: elementReference),
           let frame = frame(of: window) {
            return frame.integral
        }

        if let frontmostApplication = NSWorkspace.shared.frontmostApplication {
            let applicationElement = AXUIElementCreateApplication(frontmostApplication.processIdentifier)
            let focusedWindow: AXUIElement? = attributeValue(kAXFocusedWindowAttribute as CFString, of: applicationElement)
            if let focusedWindow,
               let frame = frame(of: focusedWindow) {
                return frame.integral
            }
        }

        throw RecordingControllerError.hoveredWindowUnavailable
    }

    private func windowElement(containing element: AXUIElement) -> AXUIElement? {
        var currentElement: AXUIElement? = element
        while let unwrappedElement = currentElement {
            if role(of: unwrappedElement) == kAXWindowRole as String {
                return unwrappedElement
            }

            currentElement = attributeValue(kAXParentAttribute as CFString, of: unwrappedElement)
        }

        return nil
    }

    private func role(of element: AXUIElement) -> String? {
        let role: String? = attributeValue(kAXRoleAttribute as CFString, of: element)
        return role
    }

    private func attributeValue<T>(_ attribute: CFString, of element: AXUIElement) -> T? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute, &value)
        guard result == .success, let typedValue = value as? T else {
            return nil
        }
        return typedValue
    }

    private func frame(of element: AXUIElement) -> CGRect? {
        guard
            let positionValue: AXValue = attributeValue(kAXPositionAttribute as CFString, of: element),
            let sizeValue: AXValue = attributeValue(kAXSizeAttribute as CFString, of: element)
        else {
            return nil
        }

        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue, .cgPoint, &position), AXValueGetValue(sizeValue, .cgSize, &size) else {
            return nil
        }

        return CGRect(origin: position, size: size)
    }

    private func writeGIF(to destinationURL: URL, settings: AppSettings) -> URL? {
        guard let destination = CGImageDestinationCreateWithURL(
            destinationURL as CFURL,
            UTType.gif.identifier as CFString,
            capturedFrames.count,
            nil
        ) else {
            return nil
        }

        let frameDelay = 1.0 / settings.validatedRecordingFramesPerSecond
        let frameProperties = [
            kCGImagePropertyGIFDictionary: [
                kCGImagePropertyGIFDelayTime: frameDelay
            ]
        ] as CFDictionary
        let gifProperties = [
            kCGImagePropertyGIFDictionary: [
                kCGImagePropertyGIFLoopCount: 0
            ]
        ] as CFDictionary

        CGImageDestinationSetProperties(destination, gifProperties)
        for frame in capturedFrames {
            CGImageDestinationAddImage(destination, scaled(frame: frame, scale: settings.validatedRecordingScale), frameProperties)
        }

        guard CGImageDestinationFinalize(destination) else {
            return nil
        }

        return destinationURL
    }

    private func writeMP4(to destinationURL: URL, settings: AppSettings) throws -> URL? {
        guard let firstFrame = capturedFrames.first else {
            return nil
        }

        let scaledFirstFrame = scaled(frame: firstFrame, scale: settings.validatedRecordingScale)
        let width = scaledFirstFrame.width
        let height = scaledFirstFrame.height
        let fps = settings.validatedRecordingFramesPerSecond

        let writer = try AVAssetWriter(outputURL: destinationURL, fileType: .mp4)
        let outputSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
        ]

        let input = AVAssetWriterInput(mediaType: .video, outputSettings: outputSettings)
        input.expectsMediaDataInRealTime = false

        let sourceAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32ARGB),
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
        ]

        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: sourceAttributes
        )

        guard writer.canAdd(input) else {
            return nil
        }

        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        let frameDuration = CMTime(seconds: 1.0 / fps, preferredTimescale: 600)
        var presentationTime = CMTime.zero

        for frame in capturedFrames {
            let scaledFrame = scaled(frame: frame, scale: settings.validatedRecordingScale)
            guard let pixelBuffer = makePixelBuffer(from: scaledFrame, canvasSize: CGSize(width: width, height: height)) else {
                continue
            }

            while !input.isReadyForMoreMediaData {
                RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01))
            }

            adaptor.append(pixelBuffer, withPresentationTime: presentationTime)
            presentationTime = CMTimeAdd(presentationTime, frameDuration)
        }

        input.markAsFinished()
        try awaitFinish(writer)
        return destinationURL
    }

    private func awaitFinish(_ writer: AVAssetWriter) throws {
        let semaphore = DispatchSemaphore(value: 0)

        writer.finishWriting {
            semaphore.signal()
        }

        semaphore.wait()

        if let error = writer.error {
            throw error
        }
    }

    private func scaled(frame: CGImage, scale: Double) -> CGImage {
        guard scale > 0, scale != 1 else {
            return frame
        }

        let width = max(1, Int(Double(frame.width) * scale))
        let height = max(1, Int(Double(frame.height) * scale))

        guard
            let colorSpace = frame.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB),
            let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
            )
        else {
            return frame
        }

        context.interpolationQuality = .high
        context.draw(frame, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage() ?? frame
    }

    private func makePixelBuffer(from image: CGImage, canvasSize: CGSize) -> CVPixelBuffer? {
        var pixelBuffer: CVPixelBuffer?
        let attributes: [String: Any] = [
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
            kCVPixelBufferWidthKey as String: Int(canvasSize.width),
            kCVPixelBufferHeightKey as String: Int(canvasSize.height),
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32ARGB),
        ]

        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            Int(canvasSize.width),
            Int(canvasSize.height),
            kCVPixelFormatType_32ARGB,
            attributes as CFDictionary,
            &pixelBuffer
        )

        guard status == kCVReturnSuccess, let pixelBuffer else {
            return nil
        }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

        guard
            let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer),
            let colorSpace = image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB),
            let context = CGContext(
                data: baseAddress,
                width: Int(canvasSize.width),
                height: Int(canvasSize.height),
                bitsPerComponent: 8,
                bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
            )
        else {
            return nil
        }

        context.clear(CGRect(origin: .zero, size: canvasSize))
        context.draw(image, in: CGRect(origin: .zero, size: canvasSize))
        return pixelBuffer
    }

    private func makeSuggestedDestinationURL(for format: RecordingFormat) throws -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let extensionName = format == .gif ? "gif" : "mp4"
        let fileName = "ZoomItRecording-\(formatter.string(from: Date())).\(extensionName)"
        let directory = URL(fileURLWithPath: settingsStore.load().recordingSaveLocation, isDirectory: true)

        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw RecordingControllerError.invalidDestination(directory.path)
        }

        return directory.appendingPathComponent(fileName)
    }

    private func promptForDestinationURL(for format: RecordingFormat) throws -> URL? {
        let suggestedURL = try makeSuggestedDestinationURL(for: format)
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = suggestedURL.lastPathComponent
        panel.directoryURL = suggestedURL.deletingLastPathComponent()
        panel.allowedContentTypes = [format == .gif ? .gif : .mpeg4Movie]
        panel.isExtensionHidden = false
        panel.title = "Save Recording"
        panel.message = "Choose where to save the recording."
        return panel.runModal() == .OK ? panel.url : nil
    }

    private func runCountdown(on screenFrame: CGRect, highlighting highlightedRegion: CGRect?) throws {
        guard let screen = NSScreen.screens.first(where: { $0.frame == screenFrame }) ?? NSScreen.main ?? NSScreen.screens.first else {
            throw RecordingControllerError.captureUnavailable
        }

        let highlightWindow = makeHighlightWindow(
            on: screen,
            screenFrame: screenFrame,
            highlightedRegion: highlightedRegion,
            dimBackground: true
        )
        highlightWindow?.orderFrontRegardless()

        let countdownCenter = highlightedRegion?.center ?? screenFrame.center
        let frame = CGRect(
            x: countdownCenter.x - 90,
            y: countdownCenter.y - 70,
            width: 180,
            height: 140
        )
        let window = OverlayWindow(
            contentRect: frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false,
            screen: screen
        )
        window.level = .statusBar
        window.isOpaque = false
        window.backgroundColor = .clear
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.ignoresMouseEvents = true

        let panel = NSVisualEffectView(frame: CGRect(origin: .zero, size: frame.size))
        panel.material = .hudWindow
        panel.state = .active
        panel.wantsLayer = true
        panel.layer?.cornerRadius = 24
        panel.layer?.masksToBounds = true

        let label = NSTextField(labelWithString: "")
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .monospacedDigitSystemFont(ofSize: 72, weight: .bold)
        label.textColor = .white
        label.alignment = .center

        panel.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 16),
            label.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -16),
            label.centerYAnchor.constraint(equalTo: panel.centerYAnchor),
        ])

        window.contentView = panel
        window.orderFrontRegardless()

        for remaining in stride(from: 3, through: 1, by: -1) {
            label.stringValue = "\(remaining)"
            playCountdownBeep()
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 1.0))
        }

        window.orderOut(nil)
        highlightWindow?.orderOut(nil)
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.08))
    }

    private func makeHighlightWindow(
        on screen: NSScreen,
        screenFrame: CGRect,
        highlightedRegion: CGRect?,
        dimBackground: Bool
    ) -> NSWindow? {
        guard let highlightedRegion else {
            return nil
        }

        let borderInset: CGFloat = 2
        let windowFrame = dimBackground
            ? screenFrame
            : highlightedRegion.insetBy(dx: -borderInset, dy: -borderInset).integral

        let window = OverlayPanel(
            contentRect: windowFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false,
            screen: screen
        )
        window.level = .statusBar
        window.backgroundColor = .clear
        window.isOpaque = false
        window.ignoresMouseEvents = true
        window.hasShadow = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        let localHighlightedRegion = dimBackground
            ? CGRect(
                x: highlightedRegion.minX - screenFrame.minX,
                y: highlightedRegion.minY - screenFrame.minY,
                width: highlightedRegion.width,
                height: highlightedRegion.height
            ).integral
            : CGRect(origin: .zero, size: windowFrame.size).insetBy(dx: borderInset, dy: borderInset)

        window.contentView = RecordingRegionHighlightView(
            frame: CGRect(origin: .zero, size: windowFrame.size),
            highlightedRegion: localHighlightedRegion,
            dimBackground: dimBackground
        )
        return window
    }

    private func showRecordingHighlightIfNeeded(on screenFrame: CGRect, highlightedRegion: CGRect?) {
        recordingHighlightWindow?.orderOut(nil)
        recordingHighlightWindow = nil

        guard
            let highlightedRegion,
            let screen = NSScreen.screens.first(where: { $0.frame == screenFrame }) ?? NSScreen.main ?? NSScreen.screens.first
        else {
            return
        }

        let window = makeHighlightWindow(
            on: screen,
            screenFrame: screenFrame,
            highlightedRegion: highlightedRegion,
            dimBackground: false
        )
        window?.orderFrontRegardless()
        recordingHighlightWindow = window
    }

    private func resetRecordingState() {
        hideRecordingHighlight()
        capturedFrames.removeAll()
        targetScreenPoint = nil
        targetScreenFrame = nil
        targetCaptureRegion = nil
        recordingMode = .fullDisplay
        recordingStartedAt = nil
    }

    private func hideRecordingHighlight() {
        recordingHighlightWindow?.orderOut(nil)
        recordingHighlightWindow = nil
    }

    private func playCountdownBeep() {
        let names = ["Tink", "Pop", "Ping"]
        for name in names {
            if let sound = NSSound(named: NSSound.Name(name)) {
                sound.volume = 0.25
                sound.play()
                return
            }
        }
        NSSound.beep()
    }
}

private extension CGRect {
    var center: CGPoint {
        CGPoint(x: midX, y: midY)
    }
}

@MainActor
private final class RecordingRegionHighlightView: NSView {
    private let highlightedRegion: CGRect
    private let dimBackground: Bool

    init(frame frameRect: NSRect, highlightedRegion: CGRect, dimBackground: Bool) {
        self.highlightedRegion = highlightedRegion
        self.dimBackground = dimBackground
        super.init(frame: frameRect)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        if dimBackground {
            NSColor.black.withAlphaComponent(0.14).setFill()
            bounds.fill()

            NSColor.clear.setFill()
            highlightedRegion.fill(using: .clear)
        }

        let strokePath = NSBezierPath(rect: highlightedRegion)
        NSColor.systemRed.setStroke()
        strokePath.lineWidth = 3
        strokePath.stroke()
    }
}

@MainActor
private final class RecordingRegionSelector {
    private let snapshot: ScreenSnapshot
    private let screen: NSScreen
    private var window: NSWindow?
    private var overlayView: RecordingSelectionView?
    private var selectedRect: CGRect?

    init(snapshot: ScreenSnapshot, screen: NSScreen) {
        self.snapshot = snapshot
        self.screen = screen
    }

    func run() -> CGRect? {
        let window = OverlayPanel(
            contentRect: screen.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false,
            screen: screen
        )
        window.level = .screenSaver
        window.backgroundColor = .clear
        window.isOpaque = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        let overlayView = RecordingSelectionView(frame: CGRect(origin: .zero, size: screen.frame.size), snapshot: snapshot)
        overlayView.autoresizingMask = [.width, .height]
        overlayView.selectionHandler = { [weak self] rect in
            self?.selectedRect = rect
            NSApp.stopModal()
        }
        overlayView.cancelHandler = {
            NSApp.stopModal()
        }

        window.contentView = overlayView
        self.window = window
        self.overlayView = overlayView

        NSApp.activate(ignoringOtherApps: true)
        window.setFrame(screen.frame, display: true)
        window.orderFrontRegardless()
        window.makeKey()
        window.makeFirstResponder(overlayView)
        NSCursor.crosshair.push()
        NSApp.runModal(for: window)
        NSCursor.pop()

        window.orderOut(nil)
        self.window = nil
        self.overlayView = nil
        return selectedRect
    }
}

@MainActor
private final class RecordingSelectionView: NSView {
    var selectionHandler: ((CGRect) -> Void)?
    var cancelHandler: (() -> Void)?

    private let snapshot: ScreenSnapshot
    private let selectionLabel = NSTextField(labelWithString: "No region selected yet")
    private var dragOrigin: CGPoint?
    private var selectionRect: CGRect?

    override var acceptsFirstResponder: Bool { true }

    init(frame frameRect: NSRect, snapshot: ScreenSnapshot) {
        self.snapshot = snapshot
        super.init(frame: frameRect)
        wantsLayer = true
        setupLabels()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let backgroundImage = NSImage(cgImage: snapshot.image, size: bounds.size)
        backgroundImage.draw(in: bounds)
        NSColor.black.withAlphaComponent(0.35).setFill()
        bounds.fill(using: .sourceAtop)

        if let selectionRect {
            backgroundImage.draw(in: selectionRect, from: selectionRect, operation: .sourceOver, fraction: 1)
            let path = NSBezierPath(rect: selectionRect)
            NSColor.systemRed.setStroke()
            path.lineWidth = 2
            path.stroke()
        }
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36, 76:
            selectionHandler?(snapshot.screenFrame)
        case 53:
            cancelHandler?()
        default:
            super.keyDown(with: event)
        }
    }

    override func cancelOperation(_ sender: Any?) {
        cancelHandler?()
    }

    override func rightMouseDown(with event: NSEvent) {
        cancelHandler?()
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        dragOrigin = point
        selectionRect = CGRect(origin: point, size: .zero)
        updateSelectionLabel()
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let dragOrigin else { return }
        let point = convert(event.locationInWindow, from: nil)
        selectionRect = CGRect(
            x: min(dragOrigin.x, point.x),
            y: min(dragOrigin.y, point.y),
            width: abs(point.x - dragOrigin.x),
            height: abs(point.y - dragOrigin.y)
        ).integral
        updateSelectionLabel()
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            dragOrigin = nil
        }

        let point = convert(event.locationInWindow, from: nil)
        let localRect: CGRect
        if let selectionRect, selectionRect.width >= 8, selectionRect.height >= 8 {
            localRect = selectionRect
        } else {
            localRect = quickSelection(around: point)
        }

        selectionHandler?(CGRect(
            x: localRect.minX + snapshot.screenFrame.minX,
            y: localRect.minY + snapshot.screenFrame.minY,
            width: localRect.width,
            height: localRect.height
        ).integral)
    }

    private func quickSelection(around point: CGPoint) -> CGRect {
        let size = CGSize(width: min(480, bounds.width), height: min(270, bounds.height))
        let origin = CGPoint(
            x: min(max(0, point.x - size.width / 2), bounds.width - size.width),
            y: min(max(0, point.y - size.height / 2), bounds.height - size.height)
        )
        return CGRect(origin: origin, size: size).integral
    }

    private func setupLabels() {
        selectionLabel.translatesAutoresizingMaskIntoConstraints = false
        selectionLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        selectionLabel.textColor = .white
        selectionLabel.stringValue = "No region selected yet"

        addSubview(selectionLabel)

        NSLayoutConstraint.activate([
            selectionLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            selectionLabel.topAnchor.constraint(equalTo: topAnchor, constant: 20),
        ])
    }

    private func updateSelectionLabel() {
        guard let selectionRect, selectionRect.width > 0, selectionRect.height > 0 else {
            selectionLabel.stringValue = "No region selected yet"
            return
        }

        selectionLabel.stringValue = "Recording: \(Int(selectionRect.width))×\(Int(selectionRect.height))"
    }
}
