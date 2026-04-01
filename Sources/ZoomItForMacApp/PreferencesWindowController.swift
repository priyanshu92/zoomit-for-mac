import AppCore
import AppKit
import PlatformServices

@MainActor
protocol PreferencesWindowControllerDelegate: AnyObject {
    func preferencesDidUpdateShortcuts()
    func preferencesDidChangePermissions()
}

@MainActor
final class PreferencesWindowController: NSWindowController {
    private let shortcutStore: ShortcutStore
    private let settingsStore: AppSettingsStore
    private let permissionsService: PermissionsService
    private weak var delegate: PreferencesWindowControllerDelegate?

    private let summaryView = NSTextView()
    private let recordingFormatPopup = NSPopUpButton()
    private let zoomFactorField = NSTextField()
    private let breakDurationField = NSTextField()
    private let annotationFontSizeField = NSTextField()
    private let recordingDirectoryField = NSTextField()
    private let screenshotDirectoryField = NSTextField()
    private let demoTypeSpeedField = NSTextField()
    private let feedbackLabel = NSTextField(labelWithString: "")
    private let permissionHelpLabel = NSTextField(labelWithString: "Enable the items below to make recording, shortcuts, and overlays work reliably.")
    private let screenRecordingStatusLabel = NSTextField(labelWithString: "")
    private let accessibilityStatusLabel = NSTextField(labelWithString: "")
    private let inputMonitoringStatusLabel = NSTextField(labelWithString: "")
    private let screenRecordingButton = NSButton(title: "", target: nil, action: nil)
    private let accessibilityButton = NSButton(title: "", target: nil, action: nil)
    private let inputMonitoringButton = NSButton(title: "", target: nil, action: nil)
    private var shortcutFields: [ShortcutAction: NSTextField] = [:]

    init(
        shortcutStore: ShortcutStore,
        settingsStore: AppSettingsStore,
        permissionsService: PermissionsService,
        delegate: PreferencesWindowControllerDelegate
    ) {
        self.shortcutStore = shortcutStore
        self.settingsStore = settingsStore
        self.permissionsService = permissionsService
        self.delegate = delegate

        let contentRect = NSRect(x: 0, y: 0, width: 980, height: 680)
        let window = NSWindow(
            contentRect: contentRect,
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "ZoomIt for Mac Preferences"
        super.init(window: window)

        configureUI(in: window)
        loadPersistedValuesIntoForm()
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func refresh() {
        refreshPermissionsUI()
        refreshSummary()
    }

    private func loadPersistedValuesIntoForm() {
        let settings = settingsStore.load()
        let bindings = shortcutStore.allBindings()

        recordingFormatPopup.removeAllItems()
        recordingFormatPopup.addItems(withTitles: RecordingFormat.allCases.map(\.title))
        recordingFormatPopup.selectItem(withTitle: settings.recordingFormat.title)
        zoomFactorField.stringValue = String(format: "%.2f", settings.initialZoomFactor)
        breakDurationField.stringValue = "\(settings.breakDurationMinutes)"
        annotationFontSizeField.stringValue = String(format: "%.0f", settings.annotationFontSize)
        recordingDirectoryField.stringValue = settings.recordingSaveLocation
        screenshotDirectoryField.stringValue = settings.screenshotSaveLocation
        demoTypeSpeedField.stringValue = "\(settings.demoTypeCharactersPerTick)"

        for action in ShortcutAction.allCases {
            shortcutFields[action]?.stringValue = bindings[action]?.windowsStyleDescription ?? ""
        }
    }

    private func refreshPermissionsUI() {
        let permissions = permissionsService.snapshot()
        updatePermissionRow(
            statusLabel: screenRecordingStatusLabel,
            button: screenRecordingButton,
            status: permissions.screenRecording,
            grantedText: "Ready for snips, OCR snips, and recording.",
            missingText: "Required to capture your screen.",
            buttonTitleWhenMissing: "Grant Screen Recording…",
            buttonTitleWhenGranted: "Open Screen Recording Settings…"
        )
        updatePermissionRow(
            statusLabel: accessibilityStatusLabel,
            button: accessibilityButton,
            status: permissions.accessibility,
            grantedText: "Ready for global shortcuts and overlay control.",
            missingText: "Required for reliable global hotkeys.",
            buttonTitleWhenMissing: "Grant Accessibility…",
            buttonTitleWhenGranted: "Open Accessibility Settings…"
        )
        updatePermissionRow(
            statusLabel: inputMonitoringStatusLabel,
            button: inputMonitoringButton,
            status: permissions.inputMonitoring,
            grantedText: "Ready for keyboard monitoring.",
            missingText: "Grant manually if shortcut capture is blocked.",
            buttonTitleWhenMissing: "Open Input Monitoring Settings…",
            buttonTitleWhenGranted: "Open Input Monitoring Settings…"
        )
    }

    private func refreshSummary() {
        let permissions = permissionsService.snapshot()
        let settings = settingsStore.load()
        let shortcuts = ShortcutCatalog.orderedDefaults.map { action, _ in
            "\(action.title): \(shortcutStore.binding(for: action).windowsStyleDescription)"
        }.joined(separator: "\n")

        summaryView.string = """
        Permissions
        - Screen Recording: \(summaryLabel(for: permissions.screenRecording))
        - Accessibility: \(summaryLabel(for: permissions.accessibility))
        - Input Monitoring: \(summaryLabel(for: permissions.inputMonitoring))

        Active shortcuts
        \(shortcuts)

        Current settings
        - Zoom factor: \(settings.initialZoomFactor)
        - Break duration: \(settings.breakDurationMinutes) minutes
        - Recording format: \(settings.recordingFormat.title)
        - Recording FPS: \(settings.recordingFramesPerSecond)
        - Recording scale: \(settings.recordingScale)
        - Recording save location: \(settings.recordingSaveLocation)
        - Screenshot save location: \(settings.screenshotSaveLocation)
        - Annotation font size: \(settings.annotationFontSize)
        - DemoType speed: \(settings.demoTypeCharactersPerTick) chars/tick
        """
    }

    private func configureUI(in window: NSWindow) {
        guard let contentView = window.contentView else {
            return
        }

        screenRecordingButton.target = self
        screenRecordingButton.action = #selector(handleScreenRecordingPermission)
        accessibilityButton.target = self
        accessibilityButton.action = #selector(handleAccessibilityPermission)
        inputMonitoringButton.target = self
        inputMonitoringButton.action = #selector(handleInputMonitoringPermission)

        let root = NSStackView()
        root.translatesAutoresizingMaskIntoConstraints = false
        root.orientation = .horizontal
        root.spacing = 16
        root.alignment = .top

        let formScroll = NSScrollView()
        formScroll.translatesAutoresizingMaskIntoConstraints = false
        formScroll.hasVerticalScroller = true
        formScroll.borderType = .noBorder

        let form = NSStackView()
        form.orientation = .vertical
        form.spacing = 12
        form.translatesAutoresizingMaskIntoConstraints = false

        form.addArrangedSubview(sectionLabel("Permissions"))
        permissionHelpLabel.textColor = .secondaryLabelColor
        permissionHelpLabel.maximumNumberOfLines = 0
        permissionHelpLabel.lineBreakMode = .byWordWrapping
        form.addArrangedSubview(permissionHelpLabel)
        form.addArrangedSubview(makePermissionRow(title: "Screen Recording", statusLabel: screenRecordingStatusLabel, button: screenRecordingButton))
        form.addArrangedSubview(makePermissionRow(title: "Accessibility", statusLabel: accessibilityStatusLabel, button: accessibilityButton))
        form.addArrangedSubview(makePermissionRow(title: "Input Monitoring", statusLabel: inputMonitoringStatusLabel, button: inputMonitoringButton))

        form.addArrangedSubview(sectionLabel("App settings"))
        form.addArrangedSubview(makeFieldRow(label: "Recording format", control: recordingFormatPopup))
        form.addArrangedSubview(makeFieldRow(label: "Initial zoom factor", control: zoomFactorField))
        form.addArrangedSubview(makeFieldRow(label: "Break duration (minutes)", control: breakDurationField))
        form.addArrangedSubview(makeFieldRow(label: "Annotation font size", control: annotationFontSizeField))
        form.addArrangedSubview(makeFieldRow(label: "Recording save location", control: makePathControl(field: recordingDirectoryField, action: #selector(chooseRecordingDirectory))))
        form.addArrangedSubview(makeFieldRow(label: "Screenshot save location", control: makePathControl(field: screenshotDirectoryField, action: #selector(chooseScreenshotDirectory))))
        form.addArrangedSubview(makeFieldRow(label: "DemoType speed", control: demoTypeSpeedField))

        form.addArrangedSubview(sectionLabel("Shortcuts"))
        for action in ShortcutAction.allCases {
            let field = NSTextField()
            field.placeholderString = ShortcutCatalog.windowsEquivalentDefaults[action]?.windowsStyleDescription
            shortcutFields[action] = field
            form.addArrangedSubview(makeFieldRow(label: action.title, control: field))
        }

        let buttonRow = NSStackView()
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 10
        let saveButton = NSButton(title: "Save Changes", target: self, action: #selector(saveSettings))
        let resetSettingsButton = NSButton(title: "Reset App Settings", target: self, action: #selector(resetAppSettings))
        let resetShortcutsButton = NSButton(title: "Reset Shortcuts", target: self, action: #selector(resetShortcuts))
        buttonRow.addArrangedSubview(saveButton)
        buttonRow.addArrangedSubview(resetSettingsButton)
        buttonRow.addArrangedSubview(resetShortcutsButton)
        form.addArrangedSubview(buttonRow)

        feedbackLabel.textColor = .secondaryLabelColor
        feedbackLabel.font = .systemFont(ofSize: 12)
        feedbackLabel.maximumNumberOfLines = 0
        feedbackLabel.lineBreakMode = .byWordWrapping
        form.addArrangedSubview(feedbackLabel)

        form.setHuggingPriority(.defaultHigh, for: .horizontal)
        formScroll.documentView = form

        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        summaryView.isEditable = false
        summaryView.isRichText = false
        summaryView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        summaryView.textContainerInset = NSSize(width: 16, height: 16)
        scrollView.documentView = summaryView

        root.addArrangedSubview(formScroll)
        root.addArrangedSubview(scrollView)
        contentView.addSubview(root)

        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            root.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            root.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 20),
            root.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -20),
            formScroll.widthAnchor.constraint(equalToConstant: 440),
        ])
    }

    private func sectionLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 15, weight: .bold)
        return label
    }

    private func makeFieldRow(label: String, control: NSView) -> NSView {
        let title = NSTextField(labelWithString: label)
        title.font = .systemFont(ofSize: 12, weight: .semibold)

        if let textField = control as? NSTextField {
            textField.isBordered = true
        }

        let stack = NSStackView(views: [title, control])
        stack.orientation = .vertical
        stack.spacing = 6
        return stack
    }

    private func makePermissionRow(title: String, statusLabel: NSTextField, button: NSButton) -> NSView {
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 12, weight: .semibold)

        statusLabel.textColor = .secondaryLabelColor
        statusLabel.maximumNumberOfLines = 0
        statusLabel.lineBreakMode = .byWordWrapping

        let stack = NSStackView(views: [titleLabel, statusLabel, button])
        stack.orientation = .vertical
        stack.spacing = 6
        return stack
    }

    private func makePathControl(field: NSTextField, action: Selector) -> NSView {
        field.isBordered = true
        let button = NSButton(title: "Browse…", target: self, action: action)
        let stack = NSStackView(views: [field, button])
        stack.orientation = .horizontal
        stack.spacing = 8
        return stack
    }

    private func updatePermissionRow(
        statusLabel: NSTextField,
        button: NSButton,
        status: PermissionStatus,
        grantedText: String,
        missingText: String,
        buttonTitleWhenMissing: String,
        buttonTitleWhenGranted: String
    ) {
        switch status {
        case .granted:
            statusLabel.stringValue = "Granted. \(grantedText)"
            button.title = buttonTitleWhenGranted
        case .notGranted:
            statusLabel.stringValue = "Needs attention. \(missingText)"
            button.title = buttonTitleWhenMissing
        case .requiresManualGrant:
            statusLabel.stringValue = "Grant manually in System Settings. \(missingText)"
            button.title = buttonTitleWhenMissing
        }
    }

    private func summaryLabel(for status: PermissionStatus) -> String {
        switch status {
        case .granted:
            return "Granted"
        case .notGranted:
            return "Needs attention"
        case .requiresManualGrant:
            return "Grant manually in System Settings"
        }
    }

    @objc private func saveSettings() {
        let originalSettings = settingsStore.load()
        let originalBindings = shortcutStore.allBindings()

        do {
            let settings = try parsedSettings(from: originalSettings)
            let bindings = try parsedShortcutBindings()

            try settingsStore.save(settings)
            do {
                try shortcutStore.setBindings(bindings)
            } catch {
                try? settingsStore.save(originalSettings)
                throw error
            }

            delegate?.preferencesDidUpdateShortcuts()
            setFeedback("Settings saved. Windows-style shortcut defaults remain available via Reset Shortcuts.")
            loadPersistedValuesIntoForm()
            refresh()
        } catch {
            try? shortcutStore.setBindings(originalBindings)
            setFeedback(error.localizedDescription, isError: true)
            presentErrorAlert(title: "Could not save settings", error: error)
        }
    }

    @objc private func resetAppSettings() {
        do {
            try settingsStore.resetToDefaults()
            loadPersistedValuesIntoForm()
            refresh()
            setFeedback("App settings reset to defaults.")
        } catch {
            setFeedback(error.localizedDescription, isError: true)
            presentErrorAlert(title: "Could not reset app settings", error: error)
        }
    }

    @objc private func resetShortcuts() {
        do {
            try shortcutStore.resetToDefaults()
            delegate?.preferencesDidUpdateShortcuts()
            loadPersistedValuesIntoForm()
            refresh()
            setFeedback("Shortcuts reset to Windows-equivalent defaults.")
        } catch {
            setFeedback(error.localizedDescription, isError: true)
            presentErrorAlert(title: "Could not reset shortcuts", error: error)
        }
    }

    @objc private func handleScreenRecordingPermission() {
        let snapshot = permissionsService.snapshot()
        let didOpen = snapshot.screenRecording == .granted
            ? permissionsService.openScreenRecordingSettings()
            : permissionsService.requestScreenRecording()
        delegate?.preferencesDidChangePermissions()
        refresh()
        setFeedback(didOpen ? "Screen Recording guidance opened." : "Open System Settings and grant Screen Recording, then return here.")
    }

    @objc private func handleAccessibilityPermission() {
        let snapshot = permissionsService.snapshot()
        let didOpen = snapshot.accessibility == .granted
            ? permissionsService.openAccessibilitySettings()
            : permissionsService.requestAccessibility()
        delegate?.preferencesDidChangePermissions()
        refresh()
        setFeedback(didOpen ? "Accessibility guidance opened." : "Open System Settings and grant Accessibility, then return here.")
    }

    @objc private func handleInputMonitoringPermission() {
        let didOpen = permissionsService.openInputMonitoringSettings()
        delegate?.preferencesDidChangePermissions()
        refresh()
        setFeedback(didOpen ? "Input Monitoring settings opened." : "Open System Settings and review Input Monitoring.")
    }

    @objc private func chooseRecordingDirectory() {
        chooseDirectory(for: recordingDirectoryField)
    }

    @objc private func chooseScreenshotDirectory() {
        chooseDirectory(for: screenshotDirectoryField)
    }

    private func chooseDirectory(for field: NSTextField) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose Folder"
        panel.directoryURL = URL(fileURLWithPath: expandedDirectoryPath(from: field.stringValue), isDirectory: true)

        if panel.runModal() == .OK, let url = panel.url {
            field.stringValue = url.path
        }
    }

    private func parsedSettings(from base: AppSettings) throws -> AppSettings {
        var settings = base
        guard let selectedTitle = recordingFormatPopup.titleOfSelectedItem?.lowercased(),
              let recordingFormat = RecordingFormat(rawValue: selectedTitle) else {
            throw PreferencesValidationError.invalidField("Recording format", reason: "Choose a supported format.")
        }

        settings.recordingFormat = recordingFormat
        settings.initialZoomFactor = try parseDouble(
            zoomFactorField.stringValue,
            fieldName: "Initial zoom factor",
            minimum: 0.25
        )
        settings.breakDurationMinutes = try parseInt(
            breakDurationField.stringValue,
            fieldName: "Break duration",
            minimum: 1
        )
        settings.annotationFontSize = try parseDouble(
            annotationFontSizeField.stringValue,
            fieldName: "Annotation font size",
            minimum: 8
        )
        settings.recordingSaveLocation = try validatedDirectoryPath(
            recordingDirectoryField.stringValue,
            fieldName: "Recording save location"
        )
        settings.screenshotSaveLocation = try validatedDirectoryPath(
            screenshotDirectoryField.stringValue,
            fieldName: "Screenshot save location"
        )
        settings.demoTypeCharactersPerTick = try parseInt(
            demoTypeSpeedField.stringValue,
            fieldName: "DemoType speed",
            minimum: 1
        )
        return settings
    }

    private func parsedShortcutBindings() throws -> [ShortcutAction: ShortcutBinding] {
        var updatedBindings: [ShortcutAction: ShortcutBinding] = [:]

        for action in ShortcutAction.allCases {
            let rawValue = shortcutFields[action]?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let binding: ShortcutBinding
            if rawValue.isEmpty {
                binding = ShortcutCatalog.windowsEquivalentDefaults[action]!
            } else {
                binding = try ShortcutBinding.parse(rawValue)
            }
            updatedBindings[action] = binding
        }

        let descriptions = updatedBindings.values.map(\.windowsStyleDescription)
        guard Set(descriptions).count == descriptions.count else {
            throw ShortcutValidationError.duplicateBindings
        }

        return updatedBindings
    }

    private func parseDouble(_ rawValue: String, fieldName: String, minimum: Double) throws -> Double {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = Double(trimmed), value >= minimum else {
            throw PreferencesValidationError.invalidField(fieldName, reason: "Enter a number greater than or equal to \(minimum).")
        }
        return value
    }

    private func parseInt(_ rawValue: String, fieldName: String, minimum: Int) throws -> Int {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = Int(trimmed), value >= minimum else {
            throw PreferencesValidationError.invalidField(fieldName, reason: "Enter a whole number greater than or equal to \(minimum).")
        }
        return value
    }

    private func validatedDirectoryPath(_ rawValue: String, fieldName: String) throws -> String {
        let path = expandedDirectoryPath(from: rawValue)
        guard !path.isEmpty else {
            throw PreferencesValidationError.invalidField(fieldName, reason: "Choose a folder.")
        }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw PreferencesValidationError.invalidField(fieldName, reason: "Choose an existing folder.")
        }

        return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.path
    }

    private func expandedDirectoryPath(from rawValue: String) -> String {
        (rawValue as NSString).expandingTildeInPath.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func setFeedback(_ message: String, isError: Bool = false) {
        feedbackLabel.stringValue = message
        feedbackLabel.textColor = isError ? .systemRed : .secondaryLabelColor
    }

    private func presentErrorAlert(title: String, error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

private enum ShortcutValidationError: Error, LocalizedError {
    case duplicateBindings

    var errorDescription: String? {
        switch self {
        case .duplicateBindings:
            return "Each shortcut must be unique."
        }
    }
}

private enum PreferencesValidationError: Error, LocalizedError {
    case invalidField(String, reason: String)

    var errorDescription: String? {
        switch self {
        case let .invalidField(field, reason):
            return "\(field): \(reason)"
        }
    }
}
