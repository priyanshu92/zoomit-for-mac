import AppCore
import AppKit
import PlatformServices
import ServiceManagement

@MainActor
protocol StatusItemControllerDelegate: AnyObject {
    func triggerFeatureAction(_ action: ShortcutAction)
    func showPreferences()
    func requestScreenRecordingPermission()
    func requestAccessibilityPermission()
    func openInputMonitoringSettings()
    func dismissActiveOverlay()
    func quitApplication()
}

@MainActor
final class StatusItemController: NSObject {
    private let shortcutStore: ShortcutStore
    private let permissionsService: PermissionsService
    private weak var delegate: StatusItemControllerDelegate?
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

    init(
        shortcutStore: ShortcutStore,
        permissionsService: PermissionsService,
        delegate: StatusItemControllerDelegate
    ) {
        self.shortcutStore = shortcutStore
        self.permissionsService = permissionsService
        self.delegate = delegate
        super.init()

        if let button = statusItem.button {
            button.image = makeStatusItemImage()
            button.imagePosition = .imageOnly
            button.title = ""
            button.toolTip = "ZoomIt"
            zoomItDebugLog("Status item button created; image=\(button.image == nil ? "nil" : "set")")
        } else {
            zoomItDebugLog("Status item button is nil")
        }

        refresh()
    }

    func refresh() {
        let menu = NSMenu()
        menu.autoenablesItems = false

        addFeatureActionItems(to: menu)

        menu.addItem(.separator())

        let preferencesItem = NSMenuItem(
            title: "Preferences…",
            action: #selector(openPreferences),
            keyEquivalent: ","
        )
        preferencesItem.target = self
        preferencesItem.isEnabled = true
        menu.addItem(preferencesItem)

        menu.addItem(.separator())

        let permissions = permissionsService.snapshot()
        addPermissionActionItem(
            to: menu,
            status: permissions.screenRecording,
            missingActionTitle: "Grant Screen Recording…",
            grantedActionTitle: "Open Screen Recording Settings…",
            action: #selector(requestScreenRecording)
        )
        addPermissionActionItem(
            to: menu,
            status: permissions.accessibility,
            missingActionTitle: "Grant Accessibility…",
            grantedActionTitle: "Open Accessibility Settings…",
            action: #selector(requestAccessibility)
        )
        addPermissionActionItem(
            to: menu,
            status: permissions.inputMonitoring,
            missingActionTitle: "Open Input Monitoring Settings…",
            grantedActionTitle: "Open Input Monitoring Settings…",
            action: #selector(openInputMonitoringSettings)
        )

        menu.addItem(.separator())

        let launchAtStartup = NSMenuItem(
            title: "Launch at Startup",
            action: #selector(toggleLaunchAtStartup),
            keyEquivalent: ""
        )
        launchAtStartup.target = self
        launchAtStartup.isEnabled = true
        launchAtStartup.state = isLaunchAtStartupEnabled ? .on : .off
        menu.addItem(launchAtStartup)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit ZoomIt for Mac", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        quitItem.isEnabled = true
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    func setPanoramaActive(_ isActive: Bool) {
        guard let button = statusItem.button else { return }
        button.toolTip = isActive ? "ZoomIt Panorama is recording. Press Esc or Ctrl+8 to finish." : "ZoomIt"
    }

    private var isLaunchAtStartupEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    private func addFeatureActionItems(to menu: NSMenu) {
        for (index, group) in ShortcutCatalog.menuActionGroups.enumerated() {
            if index > 0 {
                menu.addItem(.separator())
            }

            for action in group {
                menu.addItem(makeFeatureActionItem(for: action))
            }
        }
    }

    private func makeFeatureActionItem(for action: ShortcutAction) -> NSMenuItem {
        let binding = shortcutStore.binding(for: action)

        // AppKit matches key equivalents against `charactersIgnoringModifiers`, which is
        // lowercase for letters, so the stored uppercase key has to be lowered here.
        let item = NSMenuItem(
            title: menuTitle(for: action),
            action: #selector(triggerFeatureAction(_:)),
            keyEquivalent: binding.key.lowercased()
        )
        item.keyEquivalentModifierMask = modifierFlags(for: binding.modifiers)
        item.target = self
        item.isEnabled = true
        // Enums don't bridge to Objective-C, so round-trip through the raw value instead.
        item.representedObject = action.rawValue
        return item
    }

    /// macOS HIG: a command that needs more input before it can finish gets a trailing
    /// ellipsis. These actions all ask the user to pick a region or a window first.
    private func menuTitle(for action: ShortcutAction) -> String {
        switch action {
        case .snip, .saveSnip, .ocrSnip, .cropRecord, .windowRecord, .panorama, .savePanorama:
            return "\(action.title)…"
        case .zoom, .liveZoom, .draw, .liveDraw, .record, .demoType, .previousDemoType, .breakTimer:
            return action.title
        }
    }

    private func modifierFlags(for modifiers: ShortcutModifiers) -> NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if modifiers.contains(.control) {
            flags.insert(.control)
        }
        if modifiers.contains(.option) {
            flags.insert(.option)
        }
        if modifiers.contains(.shift) {
            flags.insert(.shift)
        }
        if modifiers.contains(.command) {
            flags.insert(.command)
        }
        return flags
    }

    private func addPermissionActionItem(
        to menu: NSMenu,
        status: PermissionStatus,
        missingActionTitle: String,
        grantedActionTitle: String,
        action: Selector
    ) {
        guard status != .granted else { return }
        let item = NSMenuItem(title: missingActionTitle, action: action, keyEquivalent: "")
        item.target = self
        item.isEnabled = true
        menu.addItem(item)
    }

    private func makeStatusItemImage() -> NSImage? {
        let configuration = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
        let image = NSImage(
            systemSymbolName: "magnifyingglass",
            accessibilityDescription: "ZoomIt"
        )
        let configuredImage = image?.withSymbolConfiguration(configuration)
        configuredImage?.isTemplate = true
        return configuredImage
    }

    @objc private func triggerFeatureAction(_ sender: NSMenuItem) {
        guard
            let rawValue = sender.representedObject as? String,
            let action = ShortcutAction(rawValue: rawValue)
        else {
            return
        }
        delegate?.triggerFeatureAction(action)
    }

    @objc private func openPreferences() {
        delegate?.showPreferences()
    }

    @objc private func requestScreenRecording() {
        delegate?.requestScreenRecordingPermission()
    }

    @objc private func requestAccessibility() {
        delegate?.requestAccessibilityPermission()
    }

    @objc private func openInputMonitoringSettings() {
        delegate?.openInputMonitoringSettings()
    }

    @objc private func toggleLaunchAtStartup() {
        do {
            if isLaunchAtStartupEnabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            // Silently ignore — user can retry
        }
        refresh()
    }

    @objc private func quit() {
        delegate?.quitApplication()
    }
}
