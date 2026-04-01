import AppKit
import PlatformServices

@MainActor
protocol StartupPermissionsWindowControllerDelegate: AnyObject {
    func showPreferences()
}

@MainActor
final class StartupPermissionsWindowController: NSWindowController {
    private let permissionsService: PermissionsService
    private weak var delegate: StartupPermissionsWindowControllerDelegate?

    private let introLabel = NSTextField(
        wrappingLabelWithString: "ZoomIt works best when macOS permissions are ready. Review each required permission below, open the matching System Settings page, then come back here to refresh."
    )
    private let summaryLabel = NSTextField(labelWithString: "")
    private let feedbackLabel = NSTextField(labelWithString: "")
    private let screenRecordingStatusLabel = NSTextField(labelWithString: "")
    private let accessibilityStatusLabel = NSTextField(labelWithString: "")
    private let inputMonitoringStatusLabel = NSTextField(labelWithString: "")
    private let screenRecordingButton = NSButton(title: "Open Screen Recording Settings…", target: nil, action: nil)
    private let accessibilityButton = NSButton(title: "Open Accessibility Settings…", target: nil, action: nil)
    private let inputMonitoringButton = NSButton(title: "Open Input Monitoring Settings…", target: nil, action: nil)

    init(
        permissionsService: PermissionsService,
        delegate: StartupPermissionsWindowControllerDelegate
    ) {
        self.permissionsService = permissionsService
        self.delegate = delegate

        let contentRect = NSRect(x: 0, y: 0, width: 560, height: 420)
        let window = NSWindow(
            contentRect: contentRect,
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "ZoomIt Permissions"
        window.center()

        super.init(window: window)

        configureUI(in: window)
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func presentIfNeeded() {
        refresh()

        guard let window, !allPermissionsGranted else {
            return
        }

        showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func refresh() {
        let permissions = permissionsService.snapshot()

        updatePermissionRow(
            statusLabel: screenRecordingStatusLabel,
            status: permissions.screenRecording,
            grantedText: "Granted. Screen capture features are ready.",
            missingText: "Not granted. Required for snips, OCR snips, live zoom, and recording.",
            manualText: "Review in System Settings. macOS may only confirm this after you return."
        )
        updatePermissionRow(
            statusLabel: accessibilityStatusLabel,
            status: permissions.accessibility,
            grantedText: "Granted. Global shortcut control is ready.",
            missingText: "Not granted. Required for reliable hotkeys and overlay control.",
            manualText: "Review in System Settings. macOS may only confirm this after you return."
        )
        updatePermissionRow(
            statusLabel: inputMonitoringStatusLabel,
            status: permissions.inputMonitoring,
            grantedText: "Granted. Keyboard monitoring access is ready.",
            missingText: "Not granted. Required when macOS blocks shortcut event listening.",
            manualText: "Needs manual review in System Settings. Open the page and confirm ZoomIt is enabled."
        )

        allPermissionsGranted = permissions.screenRecording == .granted
            && permissions.accessibility == .granted
            && permissions.inputMonitoring == .granted

        summaryLabel.stringValue = allPermissionsGranted
            ? "All required permissions are granted. You can close this window."
            : "Grant the remaining permissions, then return to ZoomIt. You can also manage them later from Preferences or the menu bar icon."

        if allPermissionsGranted {
            feedbackLabel.stringValue = ""
            window?.close()
        }
    }

    private var allPermissionsGranted = false

    private func configureUI(in window: NSWindow) {
        guard let contentView = window.contentView else {
            return
        }

        screenRecordingButton.target = self
        screenRecordingButton.action = #selector(openScreenRecordingSettings)
        accessibilityButton.target = self
        accessibilityButton.action = #selector(openAccessibilitySettings)
        inputMonitoringButton.target = self
        inputMonitoringButton.action = #selector(openInputMonitoringSettings)

        let root = NSStackView()
        root.translatesAutoresizingMaskIntoConstraints = false
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 16

        let titleLabel = NSTextField(labelWithString: "Required permissions")
        titleLabel.font = .systemFont(ofSize: 20, weight: .bold)
        root.addArrangedSubview(titleLabel)

        introLabel.maximumNumberOfLines = 0
        introLabel.lineBreakMode = .byWordWrapping
        introLabel.textColor = .secondaryLabelColor
        root.addArrangedSubview(introLabel)

        summaryLabel.maximumNumberOfLines = 0
        summaryLabel.lineBreakMode = .byWordWrapping
        summaryLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        root.addArrangedSubview(summaryLabel)

        root.addArrangedSubview(makePermissionRow(
            title: "Screen Recording",
            detail: "Lets ZoomIt capture your screen for zoom, snipping, OCR, and recording.",
            statusLabel: screenRecordingStatusLabel,
            button: screenRecordingButton
        ))
        root.addArrangedSubview(makePermissionRow(
            title: "Accessibility",
            detail: "Lets ZoomIt manage global shortcuts and control overlays reliably.",
            statusLabel: accessibilityStatusLabel,
            button: accessibilityButton
        ))
        root.addArrangedSubview(makePermissionRow(
            title: "Input Monitoring",
            detail: "Lets ZoomIt listen for keyboard events when macOS requires extra approval.",
            statusLabel: inputMonitoringStatusLabel,
            button: inputMonitoringButton
        ))

        let buttonRow = NSStackView()
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 10

        let refreshButton = NSButton(title: "Refresh Status", target: self, action: #selector(refreshStatus))
        let preferencesButton = NSButton(title: "Open Preferences", target: self, action: #selector(openPreferences))
        let continueButton = NSButton(title: "Continue Later", target: self, action: #selector(closeWindow))

        buttonRow.addArrangedSubview(refreshButton)
        buttonRow.addArrangedSubview(preferencesButton)
        buttonRow.addArrangedSubview(continueButton)
        root.addArrangedSubview(buttonRow)

        feedbackLabel.maximumNumberOfLines = 0
        feedbackLabel.lineBreakMode = .byWordWrapping
        feedbackLabel.textColor = .secondaryLabelColor
        root.addArrangedSubview(feedbackLabel)

        contentView.addSubview(root)

        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            root.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            root.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 20),
            root.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor, constant: -20),
        ])
    }

    private func makePermissionRow(
        title: String,
        detail: String,
        statusLabel: NSTextField,
        button: NSButton
    ) -> NSView {
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)

        let detailLabel = NSTextField(wrappingLabelWithString: detail)
        detailLabel.maximumNumberOfLines = 0
        detailLabel.lineBreakMode = .byWordWrapping
        detailLabel.textColor = .secondaryLabelColor

        statusLabel.maximumNumberOfLines = 0
        statusLabel.lineBreakMode = .byWordWrapping

        let footer = NSStackView(views: [statusLabel, button])
        footer.orientation = .horizontal
        footer.alignment = .firstBaseline
        footer.spacing = 12

        let stack = NSStackView(views: [titleLabel, detailLabel, footer])
        stack.orientation = .vertical
        stack.spacing = 6
        return stack
    }

    private func updatePermissionRow(
        statusLabel: NSTextField,
        status: PermissionStatus,
        grantedText: String,
        missingText: String,
        manualText: String
    ) {
        switch status {
        case .granted:
            statusLabel.stringValue = grantedText
            statusLabel.textColor = .systemGreen
        case .notGranted:
            statusLabel.stringValue = missingText
            statusLabel.textColor = .systemOrange
        case .requiresManualGrant:
            statusLabel.stringValue = manualText
            statusLabel.textColor = .secondaryLabelColor
        }
    }

    private func openSettings(_ action: () -> Bool, successMessage: String, failureMessage: String) {
        feedbackLabel.stringValue = action() ? successMessage : failureMessage
    }

    @objc private func openScreenRecordingSettings() {
        openSettings(
            permissionsService.openScreenRecordingSettings,
            successMessage: "Screen Recording settings opened. After granting access, return to ZoomIt or click Refresh Status.",
            failureMessage: "Couldn't open Screen Recording settings automatically. Open System Settings > Privacy & Security > Screen Recording."
        )
    }

    @objc private func openAccessibilitySettings() {
        openSettings(
            permissionsService.openAccessibilitySettings,
            successMessage: "Accessibility settings opened. After granting access, return to ZoomIt or click Refresh Status.",
            failureMessage: "Couldn't open Accessibility settings automatically. Open System Settings > Privacy & Security > Accessibility."
        )
    }

    @objc private func openInputMonitoringSettings() {
        openSettings(
            permissionsService.openInputMonitoringSettings,
            successMessage: "Input Monitoring settings opened. After granting access, return to ZoomIt or click Refresh Status.",
            failureMessage: "Couldn't open Input Monitoring settings automatically. Open System Settings > Privacy & Security > Input Monitoring."
        )
    }

    @objc private func refreshStatus() {
        refresh()
    }

    @objc private func openPreferences() {
        delegate?.showPreferences()
    }

    @objc private func closeWindow() {
        window?.close()
    }
}
