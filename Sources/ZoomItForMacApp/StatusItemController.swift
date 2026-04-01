import AppCore
import AppKit
import PlatformServices
import ServiceManagement

@MainActor
protocol StatusItemControllerDelegate: AnyObject {
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
        }

        refresh()
    }

    func refresh() {
        let menu = NSMenu()
        menu.autoenablesItems = false

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

    private var isLaunchAtStartupEnabled: Bool {
        SMAppService.mainApp.status == .enabled
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
            systemSymbolName: "scope",
            accessibilityDescription: "ZoomIt"
        )
        let configuredImage = image?.withSymbolConfiguration(configuration)
        configuredImage?.isTemplate = true
        return configuredImage
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
