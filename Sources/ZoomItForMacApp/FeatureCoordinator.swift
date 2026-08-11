import AppCore
import AppKit
import PlatformServices

@MainActor
final class FeatureCoordinator {
    private let shortcutStore: ShortcutStore
    private let settingsStore: AppSettingsStore
    private let permissionsService: PermissionsService
    private let zoomOverlayController: ZoomOverlayController
    private let breakTimerController: BreakTimerController
    private let demoTypeController: DemoTypeController
    private let drawOverlayController: DrawOverlayController
    private let recordingController: RecordingController
    private let snipController: SnipController
    private let panoramaController: PanoramaController
    private let notificationController: AppNotificationController
    private var demoMirrorController: DemoMirrorController?

    init(
        shortcutStore: ShortcutStore,
        settingsStore: AppSettingsStore,
        permissionsService: PermissionsService,
        screenCaptureService: ScreenCaptureService,
        clipboardService: ClipboardService,
        ocrService: OCRService,
        notificationController: AppNotificationController,
        onPanoramaActivityChanged: @escaping (Bool) -> Void = { _ in },
        onDemoMirrorActivityChanged: @escaping (Bool) -> Void = { _ in }
    ) {
        self.shortcutStore = shortcutStore
        self.settingsStore = settingsStore
        self.permissionsService = permissionsService
        self.notificationController = notificationController
        let drawOverlayController = DrawOverlayController(
            settingsStore: settingsStore,
            screenCaptureService: screenCaptureService
        )
        self.drawOverlayController = drawOverlayController
        self.zoomOverlayController = ZoomOverlayController(
            screenCaptureService: screenCaptureService,
            settingsStore: settingsStore,
            onStartDrawingFromZoom: { image, frame in
                drawOverlayController.beginOverlay(with: image, screenFrame: frame)
            }
        )
        self.breakTimerController = BreakTimerController(settingsStore: settingsStore)
        self.demoTypeController = DemoTypeController(settingsStore: settingsStore, clipboardService: clipboardService)
        self.recordingController = RecordingController(
            screenCaptureService: screenCaptureService,
            clipboardService: clipboardService,
            settingsStore: settingsStore
        )
        self.snipController = SnipController(
            screenCaptureService: screenCaptureService,
            clipboardService: clipboardService,
            ocrService: ocrService,
            settingsStore: settingsStore
        )
        self.panoramaController = PanoramaController(
            screenCaptureService: screenCaptureService,
            clipboardService: clipboardService,
            settingsStore: settingsStore,
            onActivityChanged: onPanoramaActivityChanged
        )
        self.demoMirrorController = DemoMirrorController(
            settingsStore: settingsStore,
            screenCaptureService: screenCaptureService,
            onActivityChanged: onDemoMirrorActivityChanged,
            onError: { [weak self] error in
                self?.presentFeatureError(
                    title: "Demo Mirror failed",
                    message: error.localizedDescription
                )
            }
        )
        self.drawOverlayController.onShortcutAction = { [weak self] action in
            self?.trigger(action)
        }
        self.recordingController.onResult = { [weak self] result in
            switch result {
            case let .success(completion):
                self?.presentNotification(title: completion.title, message: completion.message)
            case let .failure(error):
                self?.presentNotification(title: "Recording failed", message: error.localizedDescription)
            }
        }
    }

    func trigger(_ action: ShortcutAction, preCapturedImage: CGImage? = nil) {
        let permissions = permissionsService.snapshot()

        if action == .zoom || action == .liveZoom || action == .liveDraw {
            guard permissions.screenRecording == .granted else {
                presentMissingPermissionNotification(for: action, permissions: permissions)
                return
            }

            if action == .liveDraw {
                zoomOverlayController.startLiveDraw()
                return
            }

            zoomOverlayController.toggle(action == .zoom ? .zoom : .liveZoom)
            return
        }

        if action == .breakTimer {
            breakTimerController.toggle()
            return
        }

        if action == .draw {
            if drawOverlayController.isActive {
                drawOverlayController.activateRedact()
            } else {
                drawOverlayController.toggle(preCapturedImage: preCapturedImage)
            }
            return
        }

        if action == .demoType {
            demoTypeController.toggle(accessibilityPermission: permissions.accessibility)
            return
        }

        if action == .previousDemoType {
            demoTypeController.moveToPreviousSnippet()
            return
        }

        if action == .demoMirror || action == .demoMirrorRegion || action == .demoMirrorWindow {
            if demoMirrorController?.isRunning == true {
                demoMirrorController?.stop()
                return
            }
            guard permissions.screenRecording == .granted else {
                presentMissingPermissionNotification(for: action, permissions: permissions)
                return
            }

            let scope: DemoMirrorScope
            switch action {
            case .demoMirror:
                scope = .screen
            case .demoMirrorRegion:
                scope = .region
            case .demoMirrorWindow:
                scope = .window
            default:
                return
            }
            demoMirrorController?.toggle(scope: scope)
            return
        }

        if action == .record || action == .cropRecord || action == .windowRecord {
            guard permissions.screenRecording == .granted else {
                presentMissingPermissionNotification(for: action, permissions: permissions)
                return
            }

            do {
                switch action {
                case .record:
                    try recordingController.toggle()
                case .cropRecord:
                    try recordingController.toggleCropped()
                case .windowRecord:
                    try recordingController.toggleHoveredWindow()
                default:
                    return
                }
            } catch {
                presentNotification(
                    title: "Recording failed",
                    message: error.localizedDescription
                )
            }
            return
        }

        if action == .snip || action == .saveSnip {
            guard permissions.screenRecording == .granted else {
                presentMissingPermissionNotification(for: action, permissions: permissions)
                return
            }

            do {
                let drawSnapshot = drawOverlayController.currentSnapshot()
                if drawSnapshot != nil {
                    drawOverlayController.dismiss()
                }

                let result: SnipCaptureResult
                if let drawSnapshot {
                    result = try (action == .snip
                        ? snipController.captureToClipboard(from: drawSnapshot)
                        : snipController.captureToFile(from: drawSnapshot))
                } else if let preCapturedImage, let snapshot = makeSnapshotFromPreCapture(preCapturedImage) {
                    result = try (action == .snip
                        ? snipController.captureToClipboard(from: snapshot)
                        : snipController.captureToFile(from: snapshot))
                } else {
                    result = try (action == .snip ? snipController.captureToClipboard() : snipController.captureToFile())
                }
                if action == .saveSnip {
                    presentNotification(title: result.title, message: result.message)
                }
            } catch {
                if action == .snip, case SnipControllerError.selectionCancelled = error {
                    return
                }
                presentNotification(title: "Snip failed", message: error.localizedDescription)
            }
            return
        }

        if action == .panorama || action == .savePanorama {
            guard permissions.screenRecording == .granted else {
                presentMissingPermissionNotification(for: action, permissions: permissions)
                return
            }

            do {
                try panoramaController.toggle(
                    destination: action == .panorama ? .clipboard : .file
                ) { [weak self] result in
                    switch result {
                    case let .success(captureResult):
                        self?.presentNotification(title: captureResult.title, message: captureResult.message)
                    case let .failure(error):
                        if case PanoramaControllerError.selectionCancelled = error {
                            return
                        }
                        self?.presentNotification(title: "Panorama failed", message: error.localizedDescription)
                    }
                }
            } catch {
                if case PanoramaControllerError.selectionCancelled = error {
                    return
                }
                presentNotification(title: "Panorama failed", message: error.localizedDescription)
            }
            return
        }

        if action == .ocrSnip {
            guard permissions.screenRecording == .granted else {
                presentMissingPermissionNotification(for: action, permissions: permissions)
                return
            }

            do {
                let result: SnipCaptureResult
                if let preCapturedImage, let snapshot = makeSnapshotFromPreCapture(preCapturedImage) {
                    result = try snipController.captureOCRText(from: snapshot)
                } else {
                    result = try snipController.captureOCRText()
                }
                presentNotification(
                    title: result.title,
                    message: result.message
                )
            } catch {
                presentNotification(
                    title: "OCR snip failed",
                    message: error.localizedDescription
                )
            }
            return
        }

        let shortcut = shortcutStore.binding(for: action)
        presentNotification(
            title: "\(action.title) is wired to \(shortcut.windowsStyleDescription)",
            message: """
        The foundation build is running as a native macOS menu bar app with Windows-equivalent default shortcuts.

        Current permissions:
        • Screen Recording: \(permissions.screenRecording.rawValue)
        • Accessibility: \(permissions.accessibility.rawValue)
        • Input Monitoring: \(permissions.inputMonitoring.rawValue)
        """
        )
    }

    func dismissActiveOverlay() {
        zoomOverlayController.dismiss()
        breakTimerController.dismiss()
        demoTypeController.dismiss()
        drawOverlayController.dismiss()
        recordingController.cancel()
        panoramaController.cancel()
        demoMirrorController?.stop()
    }

    func stopPanoramaCapture() {
        panoramaController.stopCapture()
    }

    func presentStartupError(_ error: Error) {
        presentNotification(
            title: "Hotkey registration failed",
            message: error.localizedDescription
        )
    }

    private func presentMissingPermissionNotification(for action: ShortcutAction, permissions: PermissionSnapshot) {
        let shortcut = shortcutStore.binding(for: action)
        presentNotification(
            title: "\(action.title) needs Screen Recording permission",
            message: """
        \(shortcut.windowsStyleDescription) is configured correctly, but macOS is blocking screen capture.

        Current permissions:
        • Screen Recording: \(permissions.screenRecording.rawValue)
        • Accessibility: \(permissions.accessibility.rawValue)
        • Input Monitoring: \(permissions.inputMonitoring.rawValue)
        """
        )
    }

    private func presentNotification(title: String, message: String) {
        notificationController.post(title: title, message: message)
    }

    private func presentFeatureError(title: String, message: String) {
        presentNotification(title: title, message: message)
    }

    private func makeSnapshotFromPreCapture(_ image: CGImage) -> ScreenSnapshot? {
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
