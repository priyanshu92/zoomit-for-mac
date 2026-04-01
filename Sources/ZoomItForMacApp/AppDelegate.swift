import AppCore
import AppKit
import CoreGraphics
import PlatformServices

// Static handler the CGEvent tap C callback can reach without capturing context.
// Set once during app launch; called from the event tap when a snip hotkey is detected.
nonisolated(unsafe) private var snipEventHandler: (@Sendable (ShortcutAction, CGImage?) -> Void)?

// Reference to event tap for re-enabling on timeout
nonisolated(unsafe) private var globalEventTap: CFMachPort?

// Track which keyCodes we suppressed on key-down so we also suppress their key-up.
nonisolated(unsafe) private var suppressedKeyCodes: Set<Int64> = []

// CGEvent tap callback — fires before menu tracking processes the key event.
private func snipEventTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    // Re-enable the tap if macOS disabled it due to timeout
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let tap = globalEventTap {
            CGEvent.tapEnable(tap: tap, enable: true)
        }
        return Unmanaged.passUnretained(event)
    }

    let keyCode = event.getIntegerValueField(.keyboardEventKeycode)

    // Suppress matching key-up for any key-down we previously ate
    if type == .keyUp {
        if suppressedKeyCodes.remove(keyCode) != nil {
            return nil
        }
        return Unmanaged.passUnretained(event)
    }

    guard type == .keyDown else {
        return Unmanaged.passUnretained(event)
    }

    let flags = event.flags

    // Must have Control, must not have Command
    guard flags.contains(.maskControl), !flags.contains(.maskCommand) else {
        return Unmanaged.passUnretained(event)
    }

    let hasShift = flags.contains(.maskShift)
    let hasAlt = flags.contains(.maskAlternate)

    let action: ShortcutAction
    let needsScreenCapture: Bool
    switch (keyCode, hasShift, hasAlt) {
    // keyCode 19 = "2" key — draw
    case (19, false, false): action = .draw; needsScreenCapture = true
    // keyCode 22 = "6" key — snip variants
    case (22, false, false): action = .snip; needsScreenCapture = true
    case (22, true, false):  action = .saveSnip; needsScreenCapture = true
    case (22, false, true):  action = .ocrSnip; needsScreenCapture = true
    default: return Unmanaged.passUnretained(event)
    }

    // Remember to also suppress the key-up
    suppressedKeyCodes.insert(keyCode)

    var preCapturedImage: CGImage?
    if needsScreenCapture {
        let mousePoint = event.location
        var displayCount: UInt32 = 0
        var displayID: CGDirectDisplayID = 0
        CGGetDisplaysWithPoint(mousePoint, 1, &displayID, &displayCount)
        if displayCount > 0 {
            let bounds = CGDisplayBounds(displayID)
            preCapturedImage = CGWindowListCreateImage(bounds, .optionOnScreenOnly, kCGNullWindowID, .bestResolution)
                ?? CGDisplayCreateImage(displayID)
        }
    }

    snipEventHandler?(action, preCapturedImage)

    return nil
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let shortcutStore = UserDefaultsShortcutStore()
    private let settingsStore = UserDefaultsAppSettingsStore()
    private let permissionsService = MacPermissionsService()
    private let screenCaptureService = MacScreenCaptureService()
    private let clipboardService = MacClipboardService()
    private let ocrService = VisionOCRService()
    private var hotKeyCenter: GlobalHotKeyCenter?
    private var statusController: StatusItemController?
    private var preferencesController: PreferencesWindowController?
    private var startupPermissionsController: StartupPermissionsWindowController?
    private lazy var featureCoordinator = FeatureCoordinator(
        shortcutStore: shortcutStore,
        settingsStore: settingsStore,
        permissionsService: permissionsService,
        screenCaptureService: screenCaptureService,
        clipboardService: clipboardService,
        ocrService: ocrService
    )

    private var snipEventTap: CFMachPort?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Install CGEvent tap for snip actions — intercepts keys before menu tracking
        setupSnipEventTap()

        do {
            let hotKeys = try CarbonHotKeyCenter()
            hotKeys.handler = { [weak self] action in
                // Skip actions handled by the CGEvent tap to avoid double-firing
                let eventTapActions: Set<ShortcutAction> = [.draw, .snip, .saveSnip, .ocrSnip]
                guard !eventTapActions.contains(action) else { return }
                DispatchQueue.main.async {
                    self?.featureCoordinator.trigger(action)
                }
            }
            try hotKeys.registerBindings(shortcutStore.allBindings())
            hotKeyCenter = hotKeys
        } catch {
            featureCoordinator.presentStartupError(error)
        }

        preferencesController = PreferencesWindowController(
            shortcutStore: shortcutStore,
            settingsStore: settingsStore,
            permissionsService: permissionsService,
            delegate: self
        )

        statusController = StatusItemController(
            shortcutStore: shortcutStore,
            permissionsService: permissionsService,
            delegate: self
        )

        startupPermissionsController = StartupPermissionsWindowController(
            permissionsService: permissionsService,
            delegate: self
        )
        startupPermissionsController?.presentIfNeeded()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        refreshPermissionUI()
    }

    private func refreshPermissionUI() {
        preferencesController?.refresh()
        statusController?.refresh()
        startupPermissionsController?.refresh()
    }

    private func setupSnipEventTap() {
        // Wire the static handler the C callback uses
        snipEventHandler = { [weak self] action, image in
            DispatchQueue.main.async {
                self?.featureCoordinator.trigger(action, preCapturedImage: image)
            }
        }

        let eventMask: CGEventMask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
            | (1 << CGEventType.tapDisabledByTimeout.rawValue)

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: snipEventTapCallback,
            userInfo: nil
        ) else {
            return
        }

        globalEventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        snipEventTap = tap
    }
}

extension AppDelegate: StatusItemControllerDelegate {
    func showPreferences() {
        preferencesController?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func requestScreenRecordingPermission() {
        _ = permissionsService.requestScreenRecording()
        refreshPermissionUI()
    }

    func requestAccessibilityPermission() {
        _ = permissionsService.requestAccessibility()
        refreshPermissionUI()
    }

    func openInputMonitoringSettings() {
        _ = permissionsService.openInputMonitoringSettings()
        refreshPermissionUI()
    }

    func quitApplication() {
        NSApp.terminate(nil)
    }

    func dismissActiveOverlay() {
        featureCoordinator.dismissActiveOverlay()
    }
}

extension AppDelegate: PreferencesWindowControllerDelegate {
    func preferencesDidUpdateShortcuts() {
        do {
            try hotKeyCenter?.registerBindings(shortcutStore.allBindings())
            statusController?.refresh()
            preferencesController?.refresh()
        } catch {
            featureCoordinator.presentStartupError(error)
        }
    }

    func preferencesDidChangePermissions() {
        refreshPermissionUI()
    }
}

extension AppDelegate: StartupPermissionsWindowControllerDelegate {}
