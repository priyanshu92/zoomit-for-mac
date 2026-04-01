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

    init(
        shortcutStore: ShortcutStore,
        settingsStore: AppSettingsStore,
        permissionsService: PermissionsService,
        screenCaptureService: ScreenCaptureService,
        clipboardService: ClipboardService,
        ocrService: OCRService
    ) {
        self.shortcutStore = shortcutStore
        self.settingsStore = settingsStore
        self.permissionsService = permissionsService
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
        self.recordingController = RecordingController(screenCaptureService: screenCaptureService, settingsStore: settingsStore)
        self.snipController = SnipController(
            screenCaptureService: screenCaptureService,
            clipboardService: clipboardService,
            ocrService: ocrService,
            settingsStore: settingsStore
        )
        self.drawOverlayController.onShortcutAction = { [weak self] action in
            self?.trigger(action)
        }
    }

    func trigger(_ action: ShortcutAction, preCapturedImage: CGImage? = nil) {
        let permissions = permissionsService.snapshot()

        if action == .zoom || action == .liveZoom || action == .liveDraw {
            guard permissions.screenRecording == .granted else {
                presentMissingPermissionAlert(for: action, permissions: permissions)
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
            drawOverlayController.toggle(preCapturedImage: preCapturedImage)
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

        if action == .record || action == .cropRecord || action == .windowRecord {
            guard permissions.screenRecording == .granted else {
                presentMissingPermissionAlert(for: action, permissions: permissions)
                return
            }

            do {
                let result: RecordingToggleResult
                switch action {
                case .record:
                    result = try recordingController.toggle()
                case .cropRecord:
                    result = try recordingController.toggleCropped()
                case .windowRecord:
                    result = try recordingController.toggleHoveredWindow()
                default:
                    return
                }
                if result.shouldPresentAlert {
                    presentClipboardResultAlert(title: result.title, message: result.message)
                }
            } catch {
                presentClipboardResultAlert(
                    title: "Recording failed",
                    message: error.localizedDescription
                )
            }
            return
        }

        if action == .snip || action == .saveSnip {
            guard permissions.screenRecording == .granted else {
                presentMissingPermissionAlert(for: action, permissions: permissions)
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
                    presentClipboardResultAlert(title: result.title, message: result.message)
                }
            } catch {
                if action == .snip, case SnipControllerError.selectionCancelled = error {
                    return
                }
                presentClipboardResultAlert(title: "Snip failed", message: error.localizedDescription)
            }
            return
        }

        if action == .panoramaSnip {
            guard permissions.screenRecording == .granted else {
                presentMissingPermissionAlert(for: action, permissions: permissions)
                return
            }

            do {
                let result = try snipController.capturePanoramaToClipboard()
                presentClipboardResultAlert(title: result.title, message: result.message)
            } catch {
                presentClipboardResultAlert(title: "Panorama capture failed", message: error.localizedDescription)
            }
            return
        }

        if action == .ocrSnip {
            guard permissions.screenRecording == .granted else {
                presentMissingPermissionAlert(for: action, permissions: permissions)
                return
            }

            do {
                let result: SnipCaptureResult
                if let preCapturedImage, let snapshot = makeSnapshotFromPreCapture(preCapturedImage) {
                    result = try snipController.captureOCRText(from: snapshot)
                } else {
                    result = try snipController.captureOCRText()
                }
                presentClipboardResultAlert(
                    title: result.title,
                    message: result.message
                )
            } catch {
                presentClipboardResultAlert(
                    title: "OCR snip failed",
                    message: error.localizedDescription
                )
            }
            return
        }

        let shortcut = shortcutStore.binding(for: action)
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "\(action.title) is wired to \(shortcut.windowsStyleDescription)"
        alert.informativeText = """
        The foundation build is running as a native macOS menu bar app with Windows-equivalent default shortcuts.

        Current permissions:
        • Screen Recording: \(permissions.screenRecording.rawValue)
        • Accessibility: \(permissions.accessibility.rawValue)
        • Input Monitoring: \(permissions.inputMonitoring.rawValue)
        """
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    func dismissActiveOverlay() {
        zoomOverlayController.dismiss()
        breakTimerController.dismiss()
        demoTypeController.dismiss()
        drawOverlayController.dismiss()
        recordingController.cancel()
    }

    func presentStartupError(_ error: Error) {
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Hotkey registration failed"
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func presentMissingPermissionAlert(for action: ShortcutAction, permissions: PermissionSnapshot) {
        let shortcut = shortcutStore.binding(for: action)

        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "\(action.title) needs Screen Recording permission"
        alert.informativeText = """
        \(shortcut.windowsStyleDescription) is configured correctly, but macOS is blocking screen capture.

        Current permissions:
        • Screen Recording: \(permissions.screenRecording.rawValue)
        • Accessibility: \(permissions.accessibility.rawValue)
        • Input Monitoring: \(permissions.inputMonitoring.rawValue)
        """
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func presentClipboardResultAlert(title: String, message: String) {
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
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
