import AppCore
import AppKit
import CoreImage
import CoreMedia
import PlatformServices
@preconcurrency import ScreenCaptureKit

enum DemoMirrorScope {
    case screen
    case region
    case window
}

enum DemoMirrorControllerError: LocalizedError {
    case sourceDisplayUnavailable
    case secondDisplayRequired
    case sourceCaptureUnavailable
    case windowUnavailable
    case windowOutsideSourceDisplay
    case pointerOnTargetDisplay
    case streamFailed(String)

    var errorDescription: String? {
        switch self {
        case .sourceDisplayUnavailable:
            return "The source display could not be determined."
        case .secondDisplayRequired:
            return "Demo Mirror requires a second connected display."
        case .sourceCaptureUnavailable:
            return "The source display could not be captured."
        case .windowUnavailable:
            return "No mirrorable window was found under the pointer."
        case .windowOutsideSourceDisplay:
            return "The selected window is not on the source display."
        case .pointerOnTargetDisplay:
            return "Move the pointer to a window on a display other than the configured presentation display."
        case let .streamFailed(message):
            return "Demo Mirror could not start or update its capture stream: \(message)"
        }
    }
}

private struct DemoMirrorDisplay {
    let screen: NSScreen
    let id: CGDirectDisplayID

    var frame: CGRect { screen.frame }
    var scaleFactor: CGFloat { screen.backingScaleFactor }
}

private struct DemoMirrorSendableImage: @unchecked Sendable {
    let image: CGImage
}

private final class DemoMirrorStreamOutput: NSObject, SCStreamOutput, @unchecked Sendable {
    private let context = CIContext(options: [.useSoftwareRenderer: false])
    private let handler: @MainActor (CGImage) -> Void

    init(handler: @escaping @MainActor (CGImage) -> Void) {
        self.handler = handler
    }

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard type == .screen, sampleBuffer.isValid, let pixelBuffer = sampleBuffer.imageBuffer else {
            return
        }
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        guard let image = context.createCGImage(ciImage, from: ciImage.extent) else { return }

        let sendableImage = DemoMirrorSendableImage(image: image)
        let handler = handler
        Task { @MainActor in
            handler(sendableImage.image)
        }
    }
}

private final class DemoMirrorStreamDelegate: NSObject, SCStreamDelegate, @unchecked Sendable {
    private let handler: @MainActor (Error) -> Void

    init(handler: @escaping @MainActor (Error) -> Void) {
        self.handler = handler
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        let handler = handler
        Task { @MainActor in
            handler(error)
        }
    }
}

@MainActor
private final class DemoMirrorImageView: NSView {
    override var isFlipped: Bool { true }

    var image: CGImage? {
        didSet { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext, let image else { return }
        context.saveGState()
        context.translateBy(x: 0, y: bounds.height)
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: bounds)
        context.restoreGState()
    }
}

@MainActor
private final class DemoMirrorBorderView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        let lineWidth: CGFloat = 4
        let path = NSBezierPath(rect: bounds.insetBy(dx: lineWidth / 2, dy: lineWidth / 2))
        path.lineWidth = lineWidth
        NSColor.systemGreen.setStroke()
        path.stroke()
    }
}

@MainActor
final class DemoMirrorController {
    private let settingsStore: AppSettingsStore
    private let screenCaptureService: ScreenCaptureService
    private let onActivityChanged: (Bool) -> Void
    private let onError: (Error) -> Void

    private(set) var isActive = false
    private(set) var isSelecting = false

    private var sessionID: UUID?
    private var startTask: Task<Void, Never>?
    private var stream: SCStream?
    private var streamOutput: DemoMirrorStreamOutput?
    private var streamDelegate: DemoMirrorStreamDelegate?
    private let sampleQueue = DispatchQueue(label: "com.zoomitformac.demo-mirror")

    private var sourceDisplay: DemoMirrorDisplay?
    private var targetDisplay: DemoMirrorDisplay?
    private var trackedWindowID: CGWindowID?
    private var tracksWindowRegion = true
    private var trackedLocalRect: CGRect?
    private var trackingTimer: Timer?
    private var isRefreshingTrackedWindow = false
    private var missingTrackedWindowPolls = 0
    private var screenParametersObserver: NSObjectProtocol?

    private var backdropWindow: NSWindow?
    private var mirrorWindow: NSWindow?
    private weak var mirrorImageView: DemoMirrorImageView?
    private var borderWindow: NSWindow?
    private var regionSelector: DemoMirrorRegionSelector?

    var isRunning: Bool {
        isActive || isSelecting || startTask != nil
    }

    init(
        settingsStore: AppSettingsStore,
        screenCaptureService: ScreenCaptureService,
        onActivityChanged: @escaping (Bool) -> Void = { _ in },
        onError: @escaping (Error) -> Void
    ) {
        self.settingsStore = settingsStore
        self.screenCaptureService = screenCaptureService
        self.onActivityChanged = onActivityChanged
        self.onError = onError
    }

    func toggle(scope: DemoMirrorScope) {
        if isRunning {
            zoomItDebugLog("Stopping Demo Mirror from toggle")
            stop()
            return
        }

        do {
            let (source, target) = try selectedDisplays(for: scope)
            zoomItDebugLog(
                "Starting Demo Mirror scope=\(scope.logName) source=\(source.id) target=\(target.id)"
            )
            let id = UUID()
            sessionID = id
            sourceDisplay = source
            targetDisplay = target

            switch scope {
            case .screen:
                startMirroring(id: id, source: source, target: target, region: nil, window: nil)
            case .region:
                beginRegionSelection(id: id, source: source, target: target)
            case .window:
                startTask = Task { @MainActor [weak self] in
                    guard let self else { return }
                    do {
                        let window = try await windowUnderPointer(on: source)
                        try Task.checkCancellation()
                        try await beginMirroring(id: id, source: source, target: target, region: nil, window: window)
                    } catch is CancellationError {
                        return
                    } catch {
                        fail(error, sessionID: id)
                    }
                    if sessionID == id {
                        startTask = nil
                    }
                }
            }
        } catch {
            zoomItDebugLog("Demo Mirror setup failed: \(error.localizedDescription)")
            onError(error)
        }
    }

    func stop() {
        let wasRunning = isRunning
        sessionID = nil
        startTask?.cancel()
        startTask = nil
        isSelecting = false
        isActive = false
        isRefreshingTrackedWindow = false

        trackingTimer?.invalidate()
        trackingTimer = nil
        trackedWindowID = nil
        trackedLocalRect = nil
        missingTrackedWindowPolls = 0
        sourceDisplay = nil
        targetDisplay = nil

        if let screenParametersObserver {
            NotificationCenter.default.removeObserver(screenParametersObserver)
            self.screenParametersObserver = nil
        }

        regionSelector?.close()
        regionSelector = nil
        borderWindow?.orderOut(nil)
        borderWindow = nil
        mirrorWindow?.orderOut(nil)
        mirrorWindow = nil
        mirrorImageView = nil
        backdropWindow?.orderOut(nil)
        backdropWindow = nil

        let activeStream = stream
        stream = nil
        streamOutput = nil
        streamDelegate = nil
        if let activeStream {
            Task {
                do {
                    try await activeStream.stopCapture()
                } catch {
                    zoomItDebugLog("Demo Mirror stream stop failed: \(error.localizedDescription)")
                }
            }
        }

        if wasRunning {
            zoomItDebugLog("Demo Mirror stopped")
            onActivityChanged(false)
        }
    }

    private func selectedDisplays(
        for scope: DemoMirrorScope
    ) throws -> (source: DemoMirrorDisplay, target: DemoMirrorDisplay) {
        let displays = NSScreen.screens.compactMap { screen -> DemoMirrorDisplay? in
            guard
                let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
                    as? CGDirectDisplayID
            else {
                return nil
            }
            return DemoMirrorDisplay(screen: screen, id: id)
        }

        guard displays.count >= 2 else {
            throw DemoMirrorControllerError.secondDisplayRequired
        }

        let pointer = NSEvent.mouseLocation
        guard let active = displays.first(where: { $0.frame.contains(pointer) }) ?? displays.first else {
            throw DemoMirrorControllerError.sourceDisplayUnavailable
        }

        if
            let preferredID = settingsStore.load().demoMirrorTargetDisplayID,
            let preferredTarget = displays.first(where: { $0.id == preferredID })
        {
            if preferredTarget.id == active.id {
                if scope == .window {
                    throw DemoMirrorControllerError.pointerOnTargetDisplay
                }
                guard let alternateSource = displays.first(where: { $0.id != preferredTarget.id }) else {
                    throw DemoMirrorControllerError.secondDisplayRequired
                }
                return (alternateSource, preferredTarget)
            }
            return (active, preferredTarget)
        }

        guard let target = displays.first(where: { $0.id != active.id }) else {
            throw DemoMirrorControllerError.secondDisplayRequired
        }
        return (active, target)
    }

    private func beginRegionSelection(
        id: UUID,
        source: DemoMirrorDisplay,
        target: DemoMirrorDisplay
    ) {
        let center = CGPoint(x: source.frame.midX, y: source.frame.midY)
        guard let snapshot = screenCaptureService.captureScreen(containing: center) else {
            fail(DemoMirrorControllerError.sourceCaptureUnavailable, sessionID: id)
            return
        }

        isSelecting = true
        let selector = DemoMirrorRegionSelector(snapshot: snapshot, screen: source.screen)
        regionSelector = selector
        zoomItDebugLog("Demo Mirror region selector shown on display \(source.id)")
        selector.show { [weak self] selection in
            guard let self, self.sessionID == id else { return }
            self.regionSelector = nil
            self.isSelecting = false
            guard let selection else {
                zoomItDebugLog("Demo Mirror region selection cancelled")
                self.sessionID = nil
                return
            }
            zoomItDebugLog("Demo Mirror region selected: \(selection.debugDescription)")
            self.startMirroring(id: id, source: source, target: target, region: selection, window: nil)
        }
    }

    private func startMirroring(
        id: UUID,
        source: DemoMirrorDisplay,
        target: DemoMirrorDisplay,
        region: CGRect?,
        window: SCWindow?
    ) {
        startTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await beginMirroring(id: id, source: source, target: target, region: region, window: window)
            } catch is CancellationError {
                return
            } catch {
                fail(error, sessionID: id)
            }
            if sessionID == id {
                startTask = nil
            }
        }
    }

    private func beginMirroring(
        id: UUID,
        source: DemoMirrorDisplay,
        target: DemoMirrorDisplay,
        region: CGRect?,
        window: SCWindow?
    ) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: true
        )
        try Task.checkCancellation()
        guard
            sessionID == id,
            let captureDisplay = content.displays.first(where: { $0.displayID == source.id })
        else {
            throw CancellationError()
        }

        let trackWindow = settingsStore.load().demoMirrorTrackWindowRegion
        tracksWindowRegion = trackWindow

        let filter: SCContentFilter
        let configuration: SCStreamConfiguration
        let contentSize: CGSize
        let borderRect: CGRect
        let localRect: CGRect?

        if let window, !trackWindow {
            guard let appKitRect = appKitRect(for: window.frame) else {
                throw DemoMirrorControllerError.windowOutsideSourceDisplay
            }
            filter = SCContentFilter(desktopIndependentWindow: window)
            contentSize = pixelSize(for: window.frame.size, scaleFactor: source.scaleFactor)
            configuration = makeConfiguration(contentSize: contentSize, sourceRect: nil)
            borderRect = appKitRect
            localRect = DemoMirrorGeometry.displayLocalRect(
                fromQuartzGlobal: window.frame,
                displayFrame: source.frame,
                primaryDisplayHeight: primaryDisplayHeight()
            )
        } else {
            filter = SCContentFilter(display: captureDisplay, excludingWindows: [])
            let captureRect: CGRect?
            if let window {
                captureRect = DemoMirrorGeometry.displayLocalRect(
                    fromQuartzGlobal: window.frame,
                    displayFrame: source.frame,
                    primaryDisplayHeight: primaryDisplayHeight()
                )
                guard let appKitRect = appKitRect(for: window.frame) else {
                    throw DemoMirrorControllerError.windowOutsideSourceDisplay
                }
                borderRect = appKitRect
            } else if let region {
                captureRect = DemoMirrorGeometry.displayLocalRect(
                    fromAppKitGlobal: region,
                    displayFrame: source.frame
                )
                borderRect = region.intersection(source.frame).integral
            } else {
                captureRect = nil
                borderRect = source.frame
            }

            if window != nil || region != nil {
                guard let captureRect else {
                    throw DemoMirrorControllerError.windowOutsideSourceDisplay
                }
                localRect = captureRect
                contentSize = pixelSize(for: captureRect.size, scaleFactor: source.scaleFactor)
                configuration = makeConfiguration(contentSize: contentSize, sourceRect: captureRect)
            } else {
                localRect = nil
                contentSize = pixelSize(for: source.frame.size, scaleFactor: source.scaleFactor)
                configuration = makeConfiguration(contentSize: contentSize, sourceRect: nil)
            }
        }

        let delegate = DemoMirrorStreamDelegate { [weak self] error in
            guard let self, self.sessionID == id else { return }
            self.fail(
                DemoMirrorControllerError.streamFailed(error.localizedDescription),
                sessionID: id
            )
        }
        let newStream = SCStream(filter: filter, configuration: configuration, delegate: delegate)
        let output = DemoMirrorStreamOutput { [weak self] image in
            guard let self, self.sessionID == id else { return }
            self.mirrorImageView?.image = image
        }
        do {
            try newStream.addStreamOutput(output, type: .screen, sampleHandlerQueue: sampleQueue)
            try await newStream.startCapture()
        } catch {
            throw DemoMirrorControllerError.streamFailed(error.localizedDescription)
        }

        guard sessionID == id, !Task.isCancelled else {
            try? await newStream.stopCapture()
            throw CancellationError()
        }

        stream = newStream
        streamOutput = output
        streamDelegate = delegate
        trackedWindowID = window?.windowID
        trackedLocalRect = localRect
        isActive = true
        zoomItDebugLog("Demo Mirror stream started")

        showBackdrop(on: target)
        showMirrorWindow(on: target, contentSize: contentSize)
        showBorder(around: borderRect)
        watchDisplayChanges()
        if window != nil {
            startWindowTracking()
        }
        onActivityChanged(true)
    }

    private func windowUnderPointer(on source: DemoMirrorDisplay) async throws -> SCWindow {
        let content = try await SCShareableContent.excludingDesktopWindows(
            true,
            onScreenWindowsOnly: true
        )
        try Task.checkCancellation()
        let pointer = quartzPoint(from: NSEvent.mouseLocation)
        let processID = ProcessInfo.processInfo.processIdentifier

        guard let window = content.windows.first(where: {
            $0.owningApplication?.processID != processID
                && $0.frame.width >= 20
                && $0.frame.height >= 20
                && $0.frame.contains(pointer)
        }) else {
            throw DemoMirrorControllerError.windowUnavailable
        }

        guard DemoMirrorGeometry.displayLocalRect(
            fromQuartzGlobal: window.frame,
            displayFrame: source.frame,
            primaryDisplayHeight: primaryDisplayHeight()
        ) != nil else {
            throw DemoMirrorControllerError.windowOutsideSourceDisplay
        }
        return window
    }

    private func makeConfiguration(
        contentSize: CGSize,
        sourceRect: CGRect?
    ) -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()
        configuration.showsCursor = true
        configuration.queueDepth = 3
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        configuration.width = max(1, Int(contentSize.width.rounded()))
        configuration.height = max(1, Int(contentSize.height.rounded()))
        if let sourceRect {
            configuration.sourceRect = sourceRect
        }
        return configuration
    }

    private func showBackdrop(on target: DemoMirrorDisplay) {
        let window = OverlayWindow(
            contentRect: CGRect(origin: .zero, size: target.frame.size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false,
            screen: target.screen
        )
        window.level = .screenSaver
        window.backgroundColor = .black
        window.isOpaque = true
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window.isReleasedWhenClosed = false
        window.sharingType = .none
        // With an explicit screen, AppKit interprets contentRect as screen-local.
        // Set the global frame afterward or nonzero display origins are applied twice.
        window.setFrame(target.frame, display: true)
        window.orderFrontRegardless()
        backdropWindow = window
    }

    private func showMirrorWindow(on target: DemoMirrorDisplay, contentSize: CGSize) {
        guard let frame = DemoMirrorGeometry.fittedRect(contentSize: contentSize, in: target.frame) else {
            return
        }
        let window = OverlayWindow(
            contentRect: CGRect(origin: .zero, size: frame.size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false,
            screen: target.screen
        )
        window.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        window.backgroundColor = .black
        window.isOpaque = true
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window.isReleasedWhenClosed = false
        window.sharingType = .none

        let imageView = DemoMirrorImageView(frame: CGRect(origin: .zero, size: frame.size))
        imageView.autoresizingMask = [.width, .height]
        window.contentView = imageView
        window.setFrame(frame, display: true)
        window.orderFrontRegardless()
        mirrorWindow = window
        mirrorImageView = imageView
    }

    private func showBorder(around frame: CGRect) {
        let window = NSWindow(
            contentRect: frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 2)
        window.backgroundColor = .clear
        window.isOpaque = false
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window.isReleasedWhenClosed = false
        // This border identifies the mirrored source and must not feed back into the stream.
        window.sharingType = .none
        let borderView = DemoMirrorBorderView(frame: CGRect(origin: .zero, size: frame.size))
        borderView.autoresizingMask = [.width, .height]
        window.contentView = borderView
        window.orderFrontRegardless()
        borderWindow = window
    }

    private func watchDisplayChanges() {
        if let screenParametersObserver {
            NotificationCenter.default.removeObserver(screenParametersObserver)
        }
        screenParametersObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isActive else { return }
                let connectedIDs = Set(NSScreen.screens.compactMap {
                    $0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
                        as? CGDirectDisplayID
                })
                guard
                    let sourceID = self.sourceDisplay?.id,
                    let targetID = self.targetDisplay?.id,
                    connectedIDs.contains(sourceID),
                    connectedIDs.contains(targetID)
                else {
                    self.stop()
                    return
                }
            }
        }
    }

    private func startWindowTracking() {
        trackingTimer?.invalidate()
        trackingTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) {
            [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, !self.isRefreshingTrackedWindow else { return }
                self.isRefreshingTrackedWindow = true
                defer { self.isRefreshingTrackedWindow = false }
                await self.refreshTrackedWindow()
            }
        }
    }

    private func refreshTrackedWindow() async {
        guard
            isActive,
            let id = sessionID,
            let trackedWindowID,
            let source = sourceDisplay,
            let target = targetDisplay,
            let stream
        else {
            return
        }

        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                true,
                onScreenWindowsOnly: true
            )
            guard sessionID == id else { return }
            guard let window = content.windows.first(where: { $0.windowID == trackedWindowID }) else {
                missingTrackedWindowPolls += 1
                if missingTrackedWindowPolls >= 4 {
                    stop()
                }
                return
            }
            missingTrackedWindowPolls = 0
            guard
                let appKitRect = appKitRect(for: window.frame),
                let localRect = DemoMirrorGeometry.displayLocalRect(
                    fromQuartzGlobal: window.frame,
                    displayFrame: source.frame,
                    primaryDisplayHeight: primaryDisplayHeight()
                )
            else {
                stop()
                return
            }

            borderWindow?.setFrame(appKitRect, display: true)

            if localRect != trackedLocalRect {
                let contentSize = pixelSize(
                    for: tracksWindowRegion ? localRect.size : window.frame.size,
                    scaleFactor: source.scaleFactor
                )
                let configuration = makeConfiguration(
                    contentSize: contentSize,
                    sourceRect: tracksWindowRegion ? localRect : nil
                )
                try await stream.updateConfiguration(configuration)
                guard sessionID == id else { return }
                trackedLocalRect = localRect
                if
                    let fittedFrame = DemoMirrorGeometry.fittedRect(
                        contentSize: contentSize,
                        in: target.frame
                    )
                {
                    mirrorWindow?.setFrame(fittedFrame, display: true)
                }
            }

            backdropWindow?.orderFrontRegardless()
            mirrorWindow?.orderFrontRegardless()
            borderWindow?.orderFrontRegardless()
        } catch {
            fail(
                DemoMirrorControllerError.streamFailed(error.localizedDescription),
                sessionID: id
            )
        }
    }

    private func fail(_ error: Error, sessionID id: UUID) {
        guard sessionID == id else { return }
        zoomItDebugLog("Demo Mirror failed: \(error.localizedDescription)")
        stop()
        onError(error)
    }

    private func pixelSize(for pointSize: CGSize, scaleFactor: CGFloat) -> CGSize {
        CGSize(
            width: max(1, pointSize.width * scaleFactor),
            height: max(1, pointSize.height * scaleFactor)
        )
    }

    private func primaryDisplayHeight() -> CGFloat {
        NSScreen.screens.first(where: { $0.frame.origin == .zero })?.frame.height
            ?? NSScreen.screens.first?.frame.height
            ?? 0
    }

    private func quartzPoint(from appKitPoint: CGPoint) -> CGPoint {
        CGPoint(x: appKitPoint.x, y: primaryDisplayHeight() - appKitPoint.y)
    }

    private func appKitRect(for quartzRect: CGRect) -> CGRect? {
        CaptureGeometry.screenRect(
            forDisplayRect: quartzRect,
            displayOriginReferenceHeight: primaryDisplayHeight()
        )
    }
}

private extension DemoMirrorScope {
    var logName: String {
        switch self {
        case .screen: "screen"
        case .region: "region"
        case .window: "window"
        }
    }
}

@MainActor
private final class DemoMirrorRegionSelector {
    private let snapshot: ScreenSnapshot
    private let screen: NSScreen
    private var window: NSWindow?
    private var completion: ((CGRect?) -> Void)?
    private var cursorIsPushed = false

    init(snapshot: ScreenSnapshot, screen: NSScreen) {
        self.snapshot = snapshot
        self.screen = screen
    }

    func show(completion: @escaping (CGRect?) -> Void) {
        self.completion = completion

        let window = OverlayPanel(
            contentRect: CGRect(origin: .zero, size: screen.frame.size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false,
            screen: screen
        )
        window.level = .screenSaver
        window.backgroundColor = .clear
        window.isOpaque = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        let view = DemoMirrorSelectionView(frame: CGRect(origin: .zero, size: screen.frame.size), snapshot: snapshot)
        view.onComplete = { [weak self] localRect in
            guard let self else { return }
            let globalRect = localRect.map {
                CGRect(
                    x: $0.minX + self.snapshot.screenFrame.minX,
                    y: $0.minY + self.snapshot.screenFrame.minY,
                    width: $0.width,
                    height: $0.height
                ).integral
            }
            self.finish(with: globalRect)
        }
        window.contentView = view
        self.window = window

        NSApp.activate(ignoringOtherApps: true)
        window.setFrame(screen.frame, display: true)
        window.orderFrontRegardless()
        window.makeKey()
        window.makeFirstResponder(view)
        NSCursor.crosshair.push()
        cursorIsPushed = true
    }

    func close() {
        completion = nil
        closeWindow()
    }

    private func finish(with selection: CGRect?) {
        let completion = completion
        self.completion = nil
        closeWindow()
        completion?(selection)
    }

    private func closeWindow() {
        if cursorIsPushed {
            NSCursor.pop()
            cursorIsPushed = false
        }
        window?.orderOut(nil)
        window = nil
    }
}

@MainActor
private final class DemoMirrorSelectionView: NSView {
    var onComplete: ((CGRect?) -> Void)?

    private let snapshot: ScreenSnapshot
    private let instructionLabel = NSTextField(
        labelWithString: "Drag the region to mirror. Press Esc or right-click to cancel."
    )
    private var dragOrigin: CGPoint?
    private var selectionRect: CGRect?

    override var acceptsFirstResponder: Bool { true }

    init(frame frameRect: NSRect, snapshot: ScreenSnapshot) {
        self.snapshot = snapshot
        super.init(frame: frameRect)
        setupInstructionLabel()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ dirtyRect: NSRect) {
        let image = NSImage(cgImage: snapshot.image, size: bounds.size)
        image.draw(in: bounds)
        NSColor.black.withAlphaComponent(0.35).setFill()
        bounds.fill(using: .sourceAtop)

        guard let selectionRect else { return }
        image.draw(in: selectionRect, from: selectionRect, operation: .sourceOver, fraction: 1)
        NSColor.systemGreen.withAlphaComponent(0.08).setFill()
        selectionRect.fill()
        let path = NSBezierPath(rect: selectionRect)
        path.lineWidth = 3
        NSColor.systemGreen.setStroke()
        path.stroke()
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            onComplete?(nil)
            return
        }
        super.keyDown(with: event)
    }

    override func cancelOperation(_ sender: Any?) {
        onComplete?(nil)
    }

    override func rightMouseDown(with event: NSEvent) {
        onComplete?(nil)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        dragOrigin = point
        selectionRect = CGRect(origin: point, size: .zero)
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
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        dragOrigin = nil
        guard let selectionRect, selectionRect.width >= 8, selectionRect.height >= 8 else {
            NSSound.beep()
            return
        }
        onComplete?(selectionRect)
    }

    private func setupInstructionLabel() {
        instructionLabel.translatesAutoresizingMaskIntoConstraints = false
        instructionLabel.font = .systemFont(ofSize: 13, weight: .medium)
        instructionLabel.textColor = .white
        addSubview(instructionLabel)
        NSLayoutConstraint.activate([
            instructionLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            instructionLabel.topAnchor.constraint(equalTo: topAnchor, constant: 20),
            instructionLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -20),
        ])
    }
}
