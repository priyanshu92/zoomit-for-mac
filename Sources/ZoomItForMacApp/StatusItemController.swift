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
        preferencesItem.image = Self.menuIcon(named: "gearshape")
        menu.addItem(preferencesItem)

        menu.addItem(.separator())

        let permissions = permissionsService.snapshot()
        // Each of these is skipped when the permission is already granted, so the leading
        // separator has to be conditional too. Otherwise a fully permitted app shows two
        // separators back to back (AppKit does not collapse adjacent separators).
        let permissionItems = [
            permissionActionItem(
                status: permissions.screenRecording,
                title: "Grant Screen Recording…",
                symbolName: "rectangle.inset.filled.badge.record",
                action: #selector(requestScreenRecording)
            ),
            permissionActionItem(
                status: permissions.accessibility,
                title: "Grant Accessibility…",
                symbolName: "accessibility",
                action: #selector(requestAccessibility)
            ),
            permissionActionItem(
                status: permissions.inputMonitoring,
                title: "Open Input Monitoring Settings…",
                symbolName: "keyboard.badge.ellipsis",
                action: #selector(openInputMonitoringSettings)
            )
        ].compactMap { $0 }

        if !permissionItems.isEmpty {
            menu.addItem(.separator())
            permissionItems.forEach(menu.addItem)
        }

        menu.addItem(.separator())

        let launchAtStartup = NSMenuItem(
            title: "Launch at Startup",
            action: #selector(toggleLaunchAtStartup),
            keyEquivalent: ""
        )
        launchAtStartup.target = self
        launchAtStartup.isEnabled = true
        launchAtStartup.state = isLaunchAtStartupEnabled ? .on : .off
        launchAtStartup.image = Self.menuIcon(named: "power")
        menu.addItem(launchAtStartup)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit ZoomIt for Mac", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        quitItem.isEnabled = true
        quitItem.image = Self.menuIcon(named: "xmark.circle")
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
        item.image = Self.menuIcon(named: Self.symbolName(for: action))
        // Enums don't bridge to Objective-C, so round-trip through the raw value instead.
        item.representedObject = action.rawValue
        return item
    }

    /// SF Symbol per feature. An exhaustive switch (rather than a dictionary) makes the
    /// compiler flag any newly added `ShortcutAction` that still needs an icon.
    private static func symbolName(for action: ShortcutAction) -> String {
        switch action {
        case .zoom: "plus.magnifyingglass"
        case .liveZoom: "magnifyingglass.circle"
        case .draw: "pencil"
        case .liveDraw: "pencil.circle"
        case .record: "record.circle"
        case .cropRecord: "crop"
        case .windowRecord: "macwindow"
        case .snip: "camera.viewfinder"
        case .saveSnip: "square.and.arrow.down"
        case .ocrSnip: "text.viewfinder"
        case .panorama: "pano"
        case .savePanorama: "square.and.arrow.down.on.square"
        case .demoType: "keyboard"
        case .previousDemoType: "arrow.uturn.backward"
        case .breakTimer: "timer"
        }
    }

    /// Menu icons are template images so AppKit tints them for light/dark mode and for the
    /// highlighted row. Returns nil for an unavailable symbol, which just renders the item
    /// without an icon rather than failing.
    private static func menuIcon(named symbolName: String) -> NSImage? {
        let configuration = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration)
        image?.isTemplate = true
        return image
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

    private func permissionActionItem(
        status: PermissionStatus,
        title: String,
        symbolName: String,
        action: Selector
    ) -> NSMenuItem? {
        guard status != .granted else { return nil }
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.isEnabled = true
        item.image = Self.menuIcon(named: symbolName)
        return item
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
