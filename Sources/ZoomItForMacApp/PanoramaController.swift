import AppKit
import AppCore
import CoreGraphics
import PlatformServices
import UniformTypeIdentifiers

private let panoramaBorderWindowLevel = NSWindow.Level.statusBar
private let panoramaControlWindowLevel = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
private let panoramaCaptureInterval: TimeInterval = 0.08
private let panoramaMaxPendingCapturedImages = 32

private struct CapturedPanoramaImage: @unchecked Sendable {
    let image: CGImage
}

enum PanoramaControllerError: LocalizedError {
    case selectionCancelled
    case captureUnavailable
    case cropFailed
    case noFramesCaptured
    case stitchingFailed
    case saveFailed(String)

    var errorDescription: String? {
        switch self {
        case .selectionCancelled:
            return "Panorama cancelled."
        case .captureUnavailable:
            return "Screen capture could not be completed."
        case .cropFailed:
            return "The selected panorama region could not be cropped."
        case .noFramesCaptured:
            return "No panorama frames were captured."
        case .stitchingFailed:
            return "The captured frames could not be stitched."
        case let .saveFailed(path):
            return "The panorama could not be saved to \(path)."
        }
    }
}

enum PanoramaCaptureDestination {
    case clipboard
    case file
}

@MainActor
final class PanoramaController {
    private let screenCaptureService: ScreenCaptureService
    private let clipboardService: ClipboardService
    private let settingsStore: AppSettingsStore
    private let onActivityChanged: (Bool) -> Void
    private let stitcher = PanoramaStitcher()

    private var captureTimer: Timer?
    private var captureOverlay: NSWindow?
    private var captureControlWindow: NSWindow?
    private weak var captureControlView: PanoramaCaptureControlView?
    private var globalKeyMonitor: Any?
    private var localKeyMonitor: Any?
    private var globalActivityMonitor: Any?
    private var pendingCapturedImages: [CapturedPanoramaImage] = []
    private var capturedFrames: [PanoramaFrame] = []
    private var rawCaptureCount = 0
    private var processedRawCaptureCount = 0
    private var finishingRawCaptureCount = 0
    private var isProcessingCapturedImage = false
    private var captureGeneration = UUID()
    private var activeSelection: CGRect?
    private var activeScaleFactor: CGFloat = 1
    private var activeDestination: PanoramaCaptureDestination = .clipboard
    private var captureCompletion: ((Result<SnipCaptureResult, Error>) -> Void)?
    private var observedVerticalScroll: CGFloat = 0
    private var observedHorizontalScroll: CGFloat = 0
    private var lowContrastMode = false
    private var isFinishing = false
    private var stopRequested = false

    var isActive: Bool {
        captureTimer != nil || isFinishing
    }

    init(
        screenCaptureService: ScreenCaptureService,
        clipboardService: ClipboardService,
        settingsStore: AppSettingsStore,
        onActivityChanged: @escaping (Bool) -> Void
    ) {
        self.screenCaptureService = screenCaptureService
        self.clipboardService = clipboardService
        self.settingsStore = settingsStore
        self.onActivityChanged = onActivityChanged
    }

    func toggle(
        destination: PanoramaCaptureDestination,
        completion: @escaping (Result<SnipCaptureResult, Error>) -> Void
    ) throws {
        if isActive {
            zoomItDebugLog("Panorama toggle while active; stopping")
            stopCapture()
            return
        }

        zoomItDebugLog("Panorama selection starting")
        let previousApplication = NSWorkspace.shared.frontmostApplication
        let snapshot = try snapshotUnderMouse()
        let selection = try selectRegion(from: snapshot)
        zoomItDebugLog("Panorama selected region \(Int(selection.width))x\(Int(selection.height))")
        startCapture(
            selection: selection,
            scaleFactor: snapshot.scaleFactor,
            screenFrame: snapshot.screenFrame,
            previousApplication: previousApplication,
            destination: destination,
            completion: completion
        )
    }

    func stopCapture() {
        guard captureTimer != nil, !isFinishing else {
            zoomItDebugLog("Panorama stop ignored; captureTimer=\(captureTimer == nil ? "nil" : "set") isFinishing=\(isFinishing)")
            return
        }
        zoomItDebugLog("Panorama stop requested")
        stopRequested = true
        finishCapture()
    }

    func cancel() {
        stopRequested = true
        captureTimer?.invalidate()
        finishCaptureActivity()
    }

    private func startCapture(
        selection: CGRect,
        scaleFactor: CGFloat,
        screenFrame: CGRect,
        previousApplication: NSRunningApplication?,
        destination: PanoramaCaptureDestination,
        completion: @escaping (Result<SnipCaptureResult, Error>) -> Void
    ) {
        capturedFrames = []
        capturedFrames.reserveCapacity(64)
        pendingCapturedImages = []
        pendingCapturedImages.reserveCapacity(panoramaMaxPendingCapturedImages)
        rawCaptureCount = 0
        processedRawCaptureCount = 0
        finishingRawCaptureCount = 0
        isProcessingCapturedImage = false
        captureGeneration = UUID()
        activeSelection = selection
        activeScaleFactor = scaleFactor
        activeDestination = destination
        captureCompletion = completion
        observedVerticalScroll = 0
        observedHorizontalScroll = 0
        lowContrastMode = false
        isFinishing = false
        stopRequested = false

        showCaptureOverlay(selection: selection, screenFrame: screenFrame)
        showCaptureControl(selection: selection, screenFrame: screenFrame)
        installStopMonitors()
        onActivityChanged(true)
        zoomItDebugLog("Panorama capture started")

        if previousApplication?.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            previousApplication?.activate(options: [])
        }
        restackCaptureWindows()
        DispatchQueue.main.async { [weak self] in
            self?.restackCaptureWindows()
        }

        let timer = Timer(timeInterval: panoramaCaptureInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.captureFrameTick()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        captureTimer = timer
        captureFrameTick()
    }

    private func captureFrameTick() {
        guard !isFinishing, let selection = activeSelection else {
            return
        }
        guard capturedFrames.count < 1024 else {
            stopCapture()
            return
        }

        do {
            let image = try captureRegion(selection)
            if pendingCapturedImages.count >= panoramaMaxPendingCapturedImages {
                pendingCapturedImages.removeFirst()
            }
            rawCaptureCount += 1
            pendingCapturedImages.append(CapturedPanoramaImage(image: image))
            captureControlView?.update(frameCount: rawCaptureCount)
            if rawCaptureCount == 1 {
                zoomItDebugLog("Panorama captured first raw frame")
            } else if rawCaptureCount <= 5 || rawCaptureCount % 10 == 0 {
                zoomItDebugLog("Panorama captured raw frame \(rawCaptureCount)")
            }
            processNextCapturedImageIfNeeded()
        } catch {
            if capturedFrames.isEmpty {
                zoomItDebugLog("Panorama first frame failed: \(error.localizedDescription)")
                failCapture(error)
            }
        }
    }

    private func finishCapture() {
        guard !isFinishing else { return }
        isFinishing = true
        captureTimer?.invalidate()
        captureTimer = nil
        removeStopMonitors()
        finishingRawCaptureCount = rawCaptureCount

        guard !capturedFrames.isEmpty || !pendingCapturedImages.isEmpty || isProcessingCapturedImage else {
            zoomItDebugLog("Panorama finishing with no frames")
            failCapture(PanoramaControllerError.noFramesCaptured)
            return
        }

        captureControlView?.setProcessing()
        guard !isProcessingCapturedImage, pendingCapturedImages.isEmpty else {
            updateFrameProcessingProgress()
            return
        }
        startStitching()
    }

    private func processNextCapturedImageIfNeeded() {
        guard !isProcessingCapturedImage, !pendingCapturedImages.isEmpty else {
            return
        }

        let sessionID = captureGeneration
        let capturedImage = pendingCapturedImages.removeFirst()
        let previousFrame = capturedFrames.last
        let previousLowContrastMode = lowContrastMode
        let stitcher = stitcher
        isProcessingCapturedImage = true

        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let frame = try stitcher.makeFrame(from: capturedImage.image)
                let frameLowContrastMode = previousFrame == nil
                    ? stitcher.isLowContrast(frame)
                    : previousLowContrastMode
                let shouldAccept: Bool
                if let previousFrame {
                    shouldAccept = !stitcher.isNearDuplicate(
                        frame,
                        previous: previousFrame,
                        lowContrastMode: frameLowContrastMode
                    )
                } else {
                    shouldAccept = true
                }

                await MainActor.run {
                    self?.completeCapturedImageProcessing(
                        sessionID: sessionID,
                        frame: frame,
                        lowContrastMode: frameLowContrastMode,
                        shouldAccept: shouldAccept
                    )
                }
            } catch {
                let message = error.localizedDescription
                await MainActor.run {
                    self?.completeCapturedImageProcessingFailure(sessionID: sessionID, message: message)
                }
            }
        }
    }

    private func completeCapturedImageProcessing(
        sessionID: UUID,
        frame: PanoramaFrame,
        lowContrastMode frameLowContrastMode: Bool,
        shouldAccept: Bool
    ) {
        guard sessionID == captureGeneration else {
            return
        }

        processedRawCaptureCount += 1
        isProcessingCapturedImage = false

        if capturedFrames.isEmpty {
            lowContrastMode = frameLowContrastMode
            zoomItDebugLog("Panorama processed first frame; lowContrast=\(lowContrastMode)")
        }

        if shouldAccept {
            capturedFrames.append(frame)
            if capturedFrames.count <= 5 || capturedFrames.count % 10 == 0 {
                zoomItDebugLog("Panorama accepted frame \(capturedFrames.count)")
            }
        }

        if isFinishing {
            updateFrameProcessingProgress()
        }

        if capturedFrames.count >= 1024 {
            stopCapture()
            return
        }

        if pendingCapturedImages.isEmpty, isFinishing {
            startStitching()
        } else {
            processNextCapturedImageIfNeeded()
        }
    }

    private func completeCapturedImageProcessingFailure(sessionID: UUID, message: String) {
        guard sessionID == captureGeneration else {
            return
        }

        isProcessingCapturedImage = false
        zoomItDebugLog("Panorama frame processing failed: \(message)")

        if capturedFrames.isEmpty, pendingCapturedImages.isEmpty {
            failCapture(PanoramaControllerError.noFramesCaptured)
        } else if pendingCapturedImages.isEmpty, isFinishing {
            startStitching()
        } else {
            processNextCapturedImageIfNeeded()
        }
    }

    private func updateFrameProcessingProgress() {
        guard finishingRawCaptureCount > 0 else {
            return
        }

        let progress = 0.25 * Double(processedRawCaptureCount) / Double(finishingRawCaptureCount)
        captureControlView?.updateProgress(progress)
    }

    private func startStitching() {
        guard isFinishing else { return }
        guard !capturedFrames.isEmpty else {
            zoomItDebugLog("Panorama finishing with no accepted frames")
            failCapture(PanoramaControllerError.noFramesCaptured)
            return
        }

        let frames = capturedFrames
        let lowContrastMode = lowContrastMode
        let preferredAxis = preferredScrollAxis()
        let stitcher = stitcher
        zoomItDebugLog("Panorama stitching \(frames.count) frames in background; preferredAxis=\(String(describing: preferredAxis))")

        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let progressHandler: @Sendable (Double) -> Void = { [weak self] progress in
                    Task { @MainActor [weak self] in
                        self?.captureControlView?.updateProgress(progress)
                    }
                }
                let stitched = try stitcher.stitch(
                    frames: frames,
                    lowContrastMode: lowContrastMode,
                    preferredAxis: preferredAxis,
                    framesAlreadyFiltered: true,
                    progress: { progress in
                        progressHandler(0.25 + 0.75 * progress)
                    }
                )
                let panorama = StitchedPanorama(image: stitched, frameCount: frames.count)
                await MainActor.run {
                    self?.completeStitching(panorama)
                }
            } catch {
                let message = error.localizedDescription
                await MainActor.run {
                    self?.completeStitchingFailure(message)
                }
            }
        }
    }

    private func completeStitching(_ panorama: StitchedPanorama) {
        let scaleFactor = max(activeScaleFactor, 1)
        let imageSize = CGSize(
            width: CGFloat(panorama.image.width) / scaleFactor,
            height: CGFloat(panorama.image.height) / scaleFactor
        )
        let image = NSImage(cgImage: panorama.image, size: imageSize)
        do {
            let result: SnipCaptureResult
            switch activeDestination {
            case .clipboard:
                clipboardService.copy(image: image)
                result = SnipCaptureResult(
                    title: "Panorama copied to clipboard",
                    message: "Captured \(panorama.frameCount) frame\(panorama.frameCount == 1 ? "" : "s") and stitched a \(panorama.image.width)×\(panorama.image.height) image."
                )
                zoomItDebugLog("Panorama copied \(panorama.image.width)x\(panorama.image.height) image to clipboard")
            case .file:
                let savedURL = try save(image: panorama.image)
                result = SnipCaptureResult(
                    title: "Panorama saved as PNG",
                    message: "Captured \(panorama.frameCount) frame\(panorama.frameCount == 1 ? "" : "s") and saved \(panorama.image.width)×\(panorama.image.height) PNG to \(savedURL.path)."
                )
                zoomItDebugLog("Panorama saved \(panorama.image.width)x\(panorama.image.height) image to \(savedURL.path)")
            }

            let completion = captureCompletion
            finishCaptureActivity()
            completion?(.success(result))
        } catch {
            failCapture(error)
        }
    }

    private func completeStitchingFailure(_ message: String) {
        zoomItDebugLog("Panorama stitch/copy failed: \(message)")
        failCapture(PanoramaControllerError.stitchingFailed)
    }

    private func finishCaptureActivity() {
        captureTimer?.invalidate()
        captureTimer = nil
        removeStopMonitors()
        captureControlWindow?.orderOut(nil)
        captureControlWindow = nil
        captureControlView = nil
        captureOverlay?.orderOut(nil)
        captureOverlay = nil
        pendingCapturedImages = []
        capturedFrames = []
        rawCaptureCount = 0
        processedRawCaptureCount = 0
        finishingRawCaptureCount = 0
        isProcessingCapturedImage = false
        captureGeneration = UUID()
        activeSelection = nil
        activeDestination = .clipboard
        captureCompletion = nil
        observedVerticalScroll = 0
        observedHorizontalScroll = 0
        lowContrastMode = false
        isFinishing = false
        stopRequested = false
        onActivityChanged(false)
    }

    private func save(image: CGImage) throws -> URL {
        let bitmap = NSBitmapImageRep(cgImage: image)
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            throw PanoramaControllerError.stitchingFailed
        }

        let settings = settingsStore.load()
        let directory = URL(fileURLWithPath: settings.screenshotSaveLocation, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"

        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "ZoomItPanorama-\(formatter.string(from: Date())).png"
        panel.directoryURL = directory
        panel.allowedContentTypes = [.png]
        panel.isExtensionHidden = false
        panel.title = "Save Panorama"
        panel.message = "Choose where to save the stitched panorama."

        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else {
            throw PanoramaControllerError.selectionCancelled
        }

        do {
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            throw PanoramaControllerError.saveFailed(url.path)
        }
    }

    private func failCapture(_ error: Error) {
        let completion = captureCompletion
        finishCaptureActivity()
        completion?(.failure(error))
    }

    private func installStopMonitors() {
        removeStopMonitors()
        globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard Self.isStopEvent(event) else { return }
            zoomItDebugLog("Panorama global stop key detected")
            Task { @MainActor in
                self?.stopCapture()
            }
        }
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard Self.isStopEvent(event) else { return event }
            zoomItDebugLog("Panorama local stop key detected")
            self?.stopCapture()
            return nil
        }
        globalActivityMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.scrollWheel, .leftMouseDown, .leftMouseDragged, .leftMouseUp, .rightMouseDown]
        ) { [weak self] event in
            let deltaX = event.type == .scrollWheel ? event.scrollingDeltaX : 0
            let deltaY = event.type == .scrollWheel ? event.scrollingDeltaY : 0
            Task { @MainActor in
                self?.recordScroll(deltaX: deltaX, deltaY: deltaY)
                self?.restackCaptureWindows()
            }
        }
    }

    private func removeStopMonitors() {
        if let globalKeyMonitor {
            NSEvent.removeMonitor(globalKeyMonitor)
            self.globalKeyMonitor = nil
        }
        if let localKeyMonitor {
            NSEvent.removeMonitor(localKeyMonitor)
            self.localKeyMonitor = nil
        }
        if let globalActivityMonitor {
            NSEvent.removeMonitor(globalActivityMonitor)
            self.globalActivityMonitor = nil
        }
    }

    private static func isStopEvent(_ event: NSEvent) -> Bool {
        if event.keyCode == 53 {
            return true
        }

        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let extraModifiers = modifiers.subtracting([.control])
        return event.keyCode == 28 && modifiers.contains(.control) && extraModifiers.isEmpty
    }

    private func showCaptureOverlay(selection: CGRect, screenFrame: CGRect) {
        captureOverlay?.orderOut(nil)

        guard let screen = NSScreen.screens.first(where: { $0.frame == screenFrame }) else {
            return
        }

        let borderInset: CGFloat = 4
        let windowFrame = selection.insetBy(dx: -borderInset, dy: -borderInset).integral
        let window = OverlayPanel(
            contentRect: windowFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false,
            screen: screen
        )
        window.level = panoramaBorderWindowLevel
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.hidesOnDeactivate = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        let localSelection = CGRect(origin: .zero, size: windowFrame.size).insetBy(dx: borderInset, dy: borderInset).integral
        let view = PanoramaCaptureBorderView(
            frame: CGRect(origin: .zero, size: windowFrame.size),
            selectionRect: localSelection
        )
        view.autoresizingMask = NSView.AutoresizingMask([.width, .height])
        window.contentView = view
        window.setFrame(windowFrame, display: true)
        window.orderFrontRegardless()
        window.contentView?.displayIfNeeded()
        zoomItDebugLog("Panorama overlay window frame=\(windowFrame.debugDescription) visible=\(window.isVisible)")
        captureOverlay = window
    }

    private func showCaptureControl(selection: CGRect, screenFrame: CGRect) {
        captureControlWindow?.orderOut(nil)

        guard let screen = NSScreen.screens.first(where: { $0.frame == screenFrame }) else {
            return
        }

        let controlSize = CGSize(width: 238, height: 92)
        let localSelection = CGRect(
            x: selection.minX - screenFrame.minX,
            y: selection.minY - screenFrame.minY,
            width: selection.width,
            height: selection.height
        ).integral
        let preferredX = min(max(localSelection.maxX - controlSize.width, 12), screen.frame.width - controlSize.width - 12)
        let preferredY: CGFloat
        if localSelection.minY - controlSize.height - 12 >= 12 {
            preferredY = localSelection.minY - controlSize.height - 12
        } else {
            preferredY = min(localSelection.maxY + 12, screen.frame.height - controlSize.height - 12)
        }

        let window = OverlayPanel(
            contentRect: CGRect(origin: CGPoint(x: preferredX, y: preferredY), size: controlSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false,
            screen: screen
        )
        window.level = panoramaControlWindowLevel
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = true
        window.hidesOnDeactivate = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        let controlView = PanoramaCaptureControlView(frame: CGRect(origin: .zero, size: controlSize))
        controlView.stopHandler = { [weak self] in
            self?.stopCapture()
        }
        window.contentView = controlView
        window.orderFrontRegardless()
        captureControlWindow = window
        captureControlView = controlView
    }

    private func restackCaptureWindows() {
        guard captureOverlay != nil || captureControlWindow != nil else {
            return
        }

        captureOverlay?.level = panoramaBorderWindowLevel
        captureOverlay?.orderFrontRegardless()
        captureControlWindow?.level = panoramaControlWindowLevel
        captureControlWindow?.orderFrontRegardless()
    }

    private func recordScroll(deltaX: CGFloat, deltaY: CGFloat) {
        observedHorizontalScroll += abs(deltaX)
        observedVerticalScroll += abs(deltaY)
    }

    private func preferredScrollAxis() -> PanoramaScrollAxis? {
        guard observedVerticalScroll > 0 || observedHorizontalScroll > 0 else {
            return .vertical
        }
        if observedVerticalScroll >= observedHorizontalScroll * 1.2 {
            return .vertical
        }
        if observedHorizontalScroll >= observedVerticalScroll * 1.2 {
            return .horizontal
        }
        return .vertical
    }

    private func snapshotUnderMouse() throws -> ScreenSnapshot {
        let mouseLocation = NSEvent.mouseLocation
        guard let snapshot = screenCaptureService.captureScreen(containing: mouseLocation) else {
            throw PanoramaControllerError.captureUnavailable
        }

        return snapshot
    }

    private func selectRegion(from snapshot: ScreenSnapshot) throws -> CGRect {
        guard let screen = NSScreen.screens.first(where: { $0.frame == snapshot.screenFrame }) else {
            throw PanoramaControllerError.captureUnavailable
        }

        let selector = PanoramaRegionSelector(snapshot: snapshot, screen: screen)
        guard let selection = selector.run() else {
            throw PanoramaControllerError.selectionCancelled
        }

        return selection
    }

    private func captureRegion(_ selection: CGRect) throws -> CGImage {
        let center = CGPoint(x: selection.midX, y: selection.midY)
        guard
            let screen = NSScreen.screens.first(where: { $0.frame.contains(center) }),
            let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
        else {
            throw PanoramaControllerError.captureUnavailable
        }

        let displayBounds = CGDisplayBounds(displayID)
        let screenImage: CGImage?
        if let captureOverlay {
            let overlayWindowID = CGWindowID(captureOverlay.windowNumber)
            screenImage = CGWindowListCreateImage(
                displayBounds,
                .optionOnScreenBelowWindow,
                overlayWindowID,
                .bestResolution
            )
        } else {
            screenImage = CGWindowListCreateImage(displayBounds, .optionOnScreenOnly, kCGNullWindowID, .bestResolution)
        }

        guard let screenImage else {
            throw PanoramaControllerError.captureUnavailable
        }

        let snapshot = ScreenSnapshot(
            displayID: displayID,
            image: screenImage,
            screenFrame: screen.frame,
            scaleFactor: screen.backingScaleFactor
        )
        guard
            let cropRect = CaptureGeometry.cropRect(
                for: selection,
                within: snapshot.screenFrame,
                scaleFactor: snapshot.scaleFactor
            ),
            let image = snapshot.image.cropping(to: cropRect)
        else {
            throw PanoramaControllerError.cropFailed
        }

        return image
    }
}

@MainActor
private final class PanoramaRegionSelector {
    private let snapshot: ScreenSnapshot
    private let screen: NSScreen
    private var window: NSWindow?
    private var selection: CGRect?

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
        window.hidesOnDeactivate = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window.sharingType = .none
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true

        let selectionView = PanoramaSelectionView(
            frame: CGRect(origin: .zero, size: screen.frame.size),
            snapshot: snapshot
        )
        selectionView.autoresizingMask = [.width, .height]
        selectionView.selectionHandler = { [weak self] selection in
            self?.selection = selection
            NSApp.stopModal()
        }
        selectionView.cancelHandler = {
            NSApp.stopModal()
        }

        window.contentView = selectionView
        self.window = window

        NSApp.activate(ignoringOtherApps: true)
        window.setFrame(screen.frame, display: true)
        window.orderFrontRegardless()
        window.makeKey()
        window.makeFirstResponder(selectionView)
        NSCursor.crosshair.push()
        NSApp.runModal(for: window)
        NSCursor.pop()

        window.orderOut(nil)
        self.window = nil
        return selection
    }
}

private final class PanoramaCaptureBorderView: NSView {
    private let selectionRect: CGRect

    init(frame frameRect: NSRect, selectionRect: CGRect) {
        self.selectionRect = selectionRect
        super.init(frame: frameRect)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        NSColor.clear.setFill()
        bounds.fill()

        let path = NSBezierPath(rect: selectionRect)
        NSColor.systemYellow.setStroke()
        path.lineWidth = 3
        path.stroke()

        let innerPath = NSBezierPath(rect: selectionRect.insetBy(dx: 3, dy: 3))
        NSColor.black.withAlphaComponent(0.55).setStroke()
        innerPath.lineWidth = 1
        innerPath.stroke()
    }
}

private final class PanoramaCaptureControlView: NSView {
    var stopHandler: (() -> Void)?

    private let statusLabel = NSTextField(labelWithString: "Panorama recording")
    private let frameLabel = NSTextField(labelWithString: "Frames: 0")
    private let progressIndicator = NSProgressIndicator()
    private let stopButton = NSButton(title: "Finish Panorama", target: nil, action: nil)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.92).cgColor
        setupSubviews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(frameCount: Int) {
        frameLabel.stringValue = "Frames: \(frameCount)"
    }

    func setProcessing() {
        statusLabel.stringValue = "Processing panorama"
        frameLabel.stringValue = "Stitching captured frames..."
        progressIndicator.isHidden = false
        progressIndicator.isIndeterminate = false
        progressIndicator.minValue = 0
        progressIndicator.maxValue = 100
        progressIndicator.doubleValue = 3
        stopButton.isEnabled = false
        stopButton.title = "Processing..."
    }

    func updateProgress(_ progress: Double) {
        guard !progressIndicator.isHidden else { return }
        progressIndicator.doubleValue = min(max(progress * 100, 0), 100)
        frameLabel.stringValue = "Stitching... \(Int(progressIndicator.doubleValue))%"
    }

    private func setupSubviews() {
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        statusLabel.textColor = .labelColor

        frameLabel.translatesAutoresizingMaskIntoConstraints = false
        frameLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        frameLabel.textColor = .secondaryLabelColor

        progressIndicator.translatesAutoresizingMaskIntoConstraints = false
        progressIndicator.controlSize = .small
        progressIndicator.style = .bar
        progressIndicator.isDisplayedWhenStopped = true
        progressIndicator.isIndeterminate = false
        progressIndicator.minValue = 0
        progressIndicator.maxValue = 100
        progressIndicator.doubleValue = 0
        progressIndicator.isHidden = true

        stopButton.translatesAutoresizingMaskIntoConstraints = false
        stopButton.bezelStyle = .rounded
        stopButton.target = self
        stopButton.action = #selector(stopClicked)

        addSubview(statusLabel)
        addSubview(frameLabel)
        addSubview(progressIndicator)
        addSubview(stopButton)

        NSLayoutConstraint.activate([
            statusLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            statusLabel.topAnchor.constraint(equalTo: topAnchor, constant: 10),

            frameLabel.leadingAnchor.constraint(equalTo: statusLabel.leadingAnchor),
            frameLabel.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 2),
            frameLabel.trailingAnchor.constraint(lessThanOrEqualTo: stopButton.leadingAnchor, constant: -8),

            progressIndicator.leadingAnchor.constraint(equalTo: statusLabel.leadingAnchor),
            progressIndicator.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            progressIndicator.topAnchor.constraint(equalTo: frameLabel.bottomAnchor, constant: 8),

            stopButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            stopButton.topAnchor.constraint(equalTo: topAnchor, constant: 22),
        ])
    }

    @objc private func stopClicked() {
        stopHandler?()
    }
}

@MainActor
private final class PanoramaSelectionView: NSView {
    var selectionHandler: ((CGRect) -> Void)?
    var cancelHandler: (() -> Void)?

    private let snapshot: ScreenSnapshot
    private let selectionLabel = NSTextField(labelWithString: "Drag a region for Panorama. Press Esc to cancel.")
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
            NSColor.systemYellow.setStroke()
            path.lineWidth = 2
            path.stroke()

            NSColor.systemYellow.withAlphaComponent(0.08).setFill()
            NSBezierPath(rect: selectionRect).fill()
        }
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            cancelHandler?()
            return
        }
        super.keyDown(with: event)
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
        if let selectionRect, selectionRect.width >= 32, selectionRect.height >= 32 {
            localRect = selectionRect
        } else {
            localRect = quickSelection(around: point)
        }

        selectionHandler?(makeGlobalRect(from: localRect))
    }

    private func makeGlobalRect(from localRect: CGRect) -> CGRect {
        CGRect(
            x: localRect.minX + snapshot.screenFrame.minX,
            y: localRect.minY + snapshot.screenFrame.minY,
            width: localRect.width,
            height: localRect.height
        ).integral
    }

    private func quickSelection(around point: CGPoint) -> CGRect {
        let size = CGSize(width: min(420, bounds.width), height: min(260, bounds.height))
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
        selectionLabel.backgroundColor = .clear

        addSubview(selectionLabel)

        NSLayoutConstraint.activate([
            selectionLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            selectionLabel.topAnchor.constraint(equalTo: topAnchor, constant: 20),
            selectionLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -20),
        ])
    }

    private func updateSelectionLabel() {
        guard let selectionRect, selectionRect.width > 0, selectionRect.height > 0 else {
            selectionLabel.stringValue = "Drag a region for Panorama. Press Esc to cancel."
            return
        }

        selectionLabel.stringValue = "Panorama region: \(Int(selectionRect.width))×\(Int(selectionRect.height)). Scroll, then press Esc or Ctrl+8 to finish."
    }
}
