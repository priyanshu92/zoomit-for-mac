import AppCore
import AppKit
import PlatformServices

@MainActor
protocol PreferencesWindowControllerDelegate: AnyObject {
    func preferencesDidUpdateShortcuts()
    func preferencesDidChangePermissions()
}

private enum PreferencesSection: Int, CaseIterable {
    case general
    case recording
    case shortcuts
    case permissions

    var title: String {
        switch self {
        case .general: "General"
        case .recording: "Recording"
        case .shortcuts: "Shortcuts"
        case .permissions: "Permissions"
        }
    }

    var systemImageName: String {
        switch self {
        case .general: "gearshape"
        case .recording: "record.circle"
        case .shortcuts: "keyboard"
        case .permissions: "lock.shield"
        }
    }
}

@MainActor
final class PreferencesWindowController: NSWindowController {
    /// Key the window position is saved under in `UserDefaults`. Changing it resets every
    /// user back to a centered window.
    private static let frameAutosaveName = NSWindow.FrameAutosaveName("ZoomItPreferencesWindow")

    private let shortcutStore: ShortcutStore
    private let settingsStore: AppSettingsStore
    private let permissionsService: PermissionsService
    private weak var delegate: PreferencesWindowControllerDelegate?

    // Sidebar & detail
    private let sidebarTableView = NSTableView()
    private var sectionViews: [PreferencesSection: NSView] = [:]
    private var detailScrollView: NSScrollView!
    private var currentWidthConstraint: NSLayoutConstraint?

    // Persistent form controls (built once, never recreated)
    private let zoomFactorField = NSTextField()
    private let breakDurationField = NSTextField()
    private let annotationFontSizeField = NSTextField()
    private let recordingDirectoryField = NSTextField()
    private let screenshotDirectoryField = NSTextField()
    private let demoTypeSpeedField = NSTextField()
    private let feedbackLabel = NSTextField(labelWithString: "")
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

        let contentRect = NSRect(x: 0, y: 0, width: 820, height: 620)
        let window = NSWindow(
            contentRect: contentRect,
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "ZoomIt for Mac"
        window.titlebarAppearsTransparent = true
        super.init(window: window)

        // The window is built programmatically, so AppKit would otherwise leave it at the
        // contentRect origin (0,0 = bottom-left of the main screen) and cascade it from
        // there. Center it, but let a position the user has chosen win on later launches.
        shouldCascadeWindows = false
        if !window.setFrameUsingName(Self.frameAutosaveName) {
            window.center()
        }
        window.setFrameAutosaveName(Self.frameAutosaveName)

        configureUI(in: window)
        loadPersistedValuesIntoForm()
        refresh()
        selectSection(.general)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func refresh() {
        refreshPermissionsUI()
    }

    func showPermissions() {
        selectSection(.permissions)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Data Loading

    private func loadPersistedValuesIntoForm() {
        let settings = settingsStore.load()
        let bindings = shortcutStore.allBindings()

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

    // MARK: - Section Selection

    private func selectSection(_ section: PreferencesSection) {
        guard let view = sectionViews[section] else { return }
        currentWidthConstraint?.isActive = false
        detailScrollView.documentView = view
        let wc = view.widthAnchor.constraint(equalTo: detailScrollView.contentView.widthAnchor)
        wc.isActive = true
        currentWidthConstraint = wc
        detailScrollView.contentView.scroll(to: .zero)
        sidebarTableView.selectRowIndexes(IndexSet(integer: section.rawValue), byExtendingSelection: false)
    }

    // MARK: - UI Configuration

    private func configureUI(in window: NSWindow) {
        guard let contentView = window.contentView else { return }

        screenRecordingButton.target = self
        screenRecordingButton.action = #selector(handleScreenRecordingPermission)
        accessibilityButton.target = self
        accessibilityButton.action = #selector(handleAccessibilityPermission)
        inputMonitoringButton.target = self
        inputMonitoringButton.action = #selector(handleInputMonitoringPermission)

        // --- Sidebar ---
        let sidebarScrollView = NSScrollView()
        sidebarScrollView.translatesAutoresizingMaskIntoConstraints = false
        sidebarScrollView.hasVerticalScroller = true
        sidebarScrollView.borderType = .noBorder
        sidebarScrollView.drawsBackground = false

        sidebarTableView.style = .sourceList
        sidebarTableView.headerView = nil
        sidebarTableView.rowHeight = 30
        sidebarTableView.dataSource = self
        sidebarTableView.delegate = self

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("SidebarColumn"))
        column.title = ""
        sidebarTableView.addTableColumn(column)
        sidebarScrollView.documentView = sidebarTableView

        // --- Detail scroll view (documentView swapped per section) ---
        detailScrollView = NSScrollView()
        detailScrollView.translatesAutoresizingMaskIntoConstraints = false
        detailScrollView.hasVerticalScroller = true
        detailScrollView.borderType = .noBorder
        detailScrollView.drawsBackground = false
        detailScrollView.automaticallyAdjustsContentInsets = false
        detailScrollView.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)

        // Build all section views once (swapped into scrollView on selection)
        sectionViews = [
            .general: buildGeneralSection(),
            .recording: buildRecordingSection(),
            .shortcuts: buildShortcutsSection(),
            .permissions: buildPermissionsSection(),
        ]

        // --- Footer bar (persistent, outside scroll) ---
        let footerBar = buildFooterBar()

        // --- Detail pane (scroll + footer) ---
        let detailPane = NSView()
        detailPane.translatesAutoresizingMaskIntoConstraints = false
        detailPane.addSubview(detailScrollView)
        detailPane.addSubview(footerBar)

        NSLayoutConstraint.activate([
            detailScrollView.topAnchor.constraint(equalTo: detailPane.topAnchor),
            detailScrollView.leadingAnchor.constraint(equalTo: detailPane.leadingAnchor),
            detailScrollView.trailingAnchor.constraint(equalTo: detailPane.trailingAnchor),
            detailScrollView.bottomAnchor.constraint(equalTo: footerBar.topAnchor),
            footerBar.leadingAnchor.constraint(equalTo: detailPane.leadingAnchor),
            footerBar.trailingAnchor.constraint(equalTo: detailPane.trailingAnchor),
            footerBar.bottomAnchor.constraint(equalTo: detailPane.bottomAnchor),
        ])

        // --- Root layout: sidebar | detail ---
        contentView.addSubview(sidebarScrollView)
        contentView.addSubview(detailPane)

        NSLayoutConstraint.activate([
            sidebarScrollView.topAnchor.constraint(equalTo: contentView.topAnchor),
            sidebarScrollView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            sidebarScrollView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            sidebarScrollView.widthAnchor.constraint(equalToConstant: 200),

            detailPane.topAnchor.constraint(equalTo: contentView.topAnchor),
            detailPane.leadingAnchor.constraint(equalTo: sidebarScrollView.trailingAnchor),
            detailPane.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            detailPane.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
        ])
    }

    // MARK: - Footer Bar

    private func buildFooterBar() -> NSView {
        let footerBar = NSView()
        footerBar.translatesAutoresizingMaskIntoConstraints = false

        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false

        let saveButton = NSButton(title: "Save Changes", target: self, action: #selector(saveSettings))
        saveButton.bezelStyle = .rounded
        saveButton.keyEquivalent = "\r"
        saveButton.controlSize = .large

        let resetSettingsButton = NSButton(title: "Reset Settings", target: self, action: #selector(resetAppSettings))
        resetSettingsButton.bezelStyle = .rounded
        resetSettingsButton.controlSize = .regular

        let resetShortcutsButton = NSButton(title: "Reset Shortcuts", target: self, action: #selector(resetShortcuts))
        resetShortcutsButton.bezelStyle = .rounded
        resetShortcutsButton.controlSize = .regular

        feedbackLabel.textColor = .secondaryLabelColor
        feedbackLabel.font = .systemFont(ofSize: 11)
        feedbackLabel.maximumNumberOfLines = 2
        feedbackLabel.lineBreakMode = .byTruncatingTail
        feedbackLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let buttonStack = NSStackView(views: [feedbackLabel, spacer, resetSettingsButton, resetShortcutsButton, saveButton])
        buttonStack.translatesAutoresizingMaskIntoConstraints = false
        buttonStack.orientation = .horizontal
        buttonStack.spacing = 8
        buttonStack.alignment = .centerY

        footerBar.addSubview(separator)
        footerBar.addSubview(buttonStack)

        NSLayoutConstraint.activate([
            separator.topAnchor.constraint(equalTo: footerBar.topAnchor),
            separator.leadingAnchor.constraint(equalTo: footerBar.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: footerBar.trailingAnchor),
            buttonStack.topAnchor.constraint(equalTo: separator.bottomAnchor, constant: 10),
            buttonStack.leadingAnchor.constraint(equalTo: footerBar.leadingAnchor, constant: 24),
            buttonStack.trailingAnchor.constraint(equalTo: footerBar.trailingAnchor, constant: -24),
            buttonStack.bottomAnchor.constraint(equalTo: footerBar.bottomAnchor, constant: -10),
        ])

        return footerBar
    }

    // MARK: - Section Builders

    private func buildGeneralSection() -> NSView {
        let container = FlippedView()
        container.translatesAutoresizingMaskIntoConstraints = false
        let stack = makeSectionStack(in: container)

        addFullWidth(makeSectionTitle("General"), to: stack)

        addFullWidth(makeGroupCard(
            header: "ZOOM",
            rows: [
                makeSettingsRow(label: "Initial zoom factor", control: zoomFactorField),
            ],
            footer: "The magnification level when zoom is activated."
        ), to: stack)

        addFullWidth(makeGroupCard(
            header: "BREAK TIMER",
            rows: [
                makeSettingsRow(label: "Duration (minutes)", control: breakDurationField),
            ]
        ), to: stack)

        addFullWidth(makeGroupCard(
            header: "ANNOTATIONS",
            rows: [
                makeSettingsRow(label: "Font size", control: annotationFontSizeField),
            ]
        ), to: stack)

        addFullWidth(makeGroupCard(
            header: "DEMOTYPE",
            rows: [
                makeSettingsRow(label: "Characters per tick", control: demoTypeSpeedField),
            ],
            footer: "How many characters are typed per animation tick."
        ), to: stack)

        return container
    }

    private func buildRecordingSection() -> NSView {
        let container = FlippedView()
        container.translatesAutoresizingMaskIntoConstraints = false
        let stack = makeSectionStack(in: container)

        addFullWidth(makeSectionTitle("Recording"), to: stack)

        addFullWidth(makeGroupCard(
            header: "SAVE LOCATIONS",
            rows: [
                makeSettingsRow(
                    label: "Recordings",
                    control: makePathControl(field: recordingDirectoryField, action: #selector(chooseRecordingDirectory))
                ),
                makeSettingsRow(
                    label: "Screenshots",
                    control: makePathControl(field: screenshotDirectoryField, action: #selector(chooseScreenshotDirectory))
                ),
            ],
            footer: "Choose where recordings and screenshots are saved."
        ), to: stack)

        return container
    }

    private func buildShortcutsSection() -> NSView {
        let container = FlippedView()
        container.translatesAutoresizingMaskIntoConstraints = false
        let stack = makeSectionStack(in: container)

        addFullWidth(makeSectionTitle("Shortcuts"), to: stack)

        var rows: [NSView] = []
        for action in ShortcutAction.allCases {
            let field = NSTextField()
            field.placeholderString = ShortcutCatalog.windowsEquivalentDefaults[action]?.windowsStyleDescription
            shortcutFields[action] = field
            rows.append(makeSettingsRow(label: action.title, control: field))
        }

        addFullWidth(makeGroupCard(
            header: "KEYBOARD SHORTCUTS",
            rows: rows,
            footer: "Format: Ctrl+Key (e.g. Ctrl+1). Leave empty to use the default."
        ), to: stack)

        return container
    }

    private func buildPermissionsSection() -> NSView {
        let container = FlippedView()
        container.translatesAutoresizingMaskIntoConstraints = false
        let stack = makeSectionStack(in: container)

        addFullWidth(makeSectionTitle("Permissions"), to: stack)

        let helpLabel = NSTextField(wrappingLabelWithString: "Enable the items below to make recording, shortcuts, and overlays work reliably.")
        helpLabel.textColor = .secondaryLabelColor
        helpLabel.font = .systemFont(ofSize: 12)
        addFullWidth(helpLabel, to: stack)

        addFullWidth(makeGroupCard(rows: [
            makePermissionRow(
                title: "Screen Recording",
                statusLabel: screenRecordingStatusLabel,
                button: screenRecordingButton
            ),
            makePermissionRow(
                title: "Accessibility",
                statusLabel: accessibilityStatusLabel,
                button: accessibilityButton
            ),
            makePermissionRow(
                title: "Input Monitoring",
                statusLabel: inputMonitoringStatusLabel,
                button: inputMonitoringButton
            ),
        ]), to: stack)

        return container
    }

    // MARK: - iOS-Style Card & Row Builders

    private func makeSectionStack(in container: NSView) -> NSStackView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 20),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -24),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -20),
        ])
        return stack
    }

    private func addFullWidth(_ view: NSView, to stack: NSStackView) {
        view.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: stack.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
        ])
    }

    private func makeSectionTitle(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 22, weight: .bold)
        return label
    }

    private func makeGroupCard(header: String? = nil, rows: [NSView], footer: String? = nil) -> NSView {
        let wrapper = NSView()
        wrapper.translatesAutoresizingMaskIntoConstraints = false

        var topAnchorRef = wrapper.topAnchor
        let topOffset: CGFloat = 0

        if let header {
            let headerLabel = NSTextField(labelWithString: header)
            headerLabel.font = .systemFont(ofSize: 11, weight: .regular)
            headerLabel.textColor = .secondaryLabelColor
            headerLabel.translatesAutoresizingMaskIntoConstraints = false
            wrapper.addSubview(headerLabel)
            NSLayoutConstraint.activate([
                headerLabel.topAnchor.constraint(equalTo: wrapper.topAnchor),
                headerLabel.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor, constant: 12),
            ])
            topAnchorRef = headerLabel.bottomAnchor
        }

        let card = CardBackgroundView()
        card.translatesAutoresizingMaskIntoConstraints = false
        wrapper.addSubview(card)

        NSLayoutConstraint.activate([
            card.topAnchor.constraint(equalTo: topAnchorRef, constant: header != nil ? 4 : topOffset),
            card.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor),
            card.trailingAnchor.constraint(equalTo: wrapper.trailingAnchor),
        ])

        // Stack rows inside the card
        var prevAnchor = card.topAnchor
        for (i, row) in rows.enumerated() {
            row.translatesAutoresizingMaskIntoConstraints = false
            card.addSubview(row)
            NSLayoutConstraint.activate([
                row.topAnchor.constraint(equalTo: prevAnchor),
                row.leadingAnchor.constraint(equalTo: card.leadingAnchor),
                row.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            ])
            prevAnchor = row.bottomAnchor

            if i < rows.count - 1 {
                let sep = NSBox()
                sep.boxType = .separator
                sep.translatesAutoresizingMaskIntoConstraints = false
                card.addSubview(sep)
                NSLayoutConstraint.activate([
                    sep.topAnchor.constraint(equalTo: prevAnchor),
                    sep.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
                    sep.trailingAnchor.constraint(equalTo: card.trailingAnchor),
                    sep.heightAnchor.constraint(equalToConstant: 1),
                ])
                prevAnchor = sep.bottomAnchor
            }
        }
        card.bottomAnchor.constraint(equalTo: prevAnchor).isActive = true

        var bottomRef = card.bottomAnchor
        if let footer {
            let footerLabel = NSTextField(wrappingLabelWithString: footer)
            footerLabel.font = .systemFont(ofSize: 11)
            footerLabel.textColor = .secondaryLabelColor
            footerLabel.translatesAutoresizingMaskIntoConstraints = false
            wrapper.addSubview(footerLabel)
            NSLayoutConstraint.activate([
                footerLabel.topAnchor.constraint(equalTo: card.bottomAnchor, constant: 4),
                footerLabel.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor, constant: 12),
                footerLabel.trailingAnchor.constraint(equalTo: wrapper.trailingAnchor, constant: -12),
            ])
            bottomRef = footerLabel.bottomAnchor
        }

        wrapper.bottomAnchor.constraint(equalTo: bottomRef).isActive = true
        return wrapper
    }

    private func makeSettingsRow(label: String, control: NSView) -> NSView {
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false

        let titleLabel = NSTextField(labelWithString: label)
        titleLabel.font = .systemFont(ofSize: 13)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        titleLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        control.translatesAutoresizingMaskIntoConstraints = false

        row.addSubview(titleLabel)
        row.addSubview(control)

        NSLayoutConstraint.activate([
            row.heightAnchor.constraint(greaterThanOrEqualToConstant: 36),
            titleLabel.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 16),
            titleLabel.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            control.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -16),
            control.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            control.topAnchor.constraint(greaterThanOrEqualTo: row.topAnchor, constant: 6),
            control.bottomAnchor.constraint(lessThanOrEqualTo: row.bottomAnchor, constant: -6),
            control.leadingAnchor.constraint(greaterThanOrEqualTo: titleLabel.trailingAnchor, constant: 12),
            control.widthAnchor.constraint(lessThanOrEqualToConstant: 260),
        ])

        return row
    }

    private func makePermissionRow(title: String, statusLabel: NSTextField, button: NSButton) -> NSView {
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 13, weight: .medium)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.maximumNumberOfLines = 2
        statusLabel.lineBreakMode = .byWordWrapping
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        button.translatesAutoresizingMaskIntoConstraints = false
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)

        let leftStack = NSStackView(views: [titleLabel, statusLabel])
        leftStack.orientation = .vertical
        leftStack.alignment = .leading
        leftStack.spacing = 2
        leftStack.translatesAutoresizingMaskIntoConstraints = false

        row.addSubview(leftStack)
        row.addSubview(button)

        NSLayoutConstraint.activate([
            row.heightAnchor.constraint(greaterThanOrEqualToConstant: 52),
            leftStack.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 16),
            leftStack.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            leftStack.topAnchor.constraint(greaterThanOrEqualTo: row.topAnchor, constant: 8),
            leftStack.bottomAnchor.constraint(lessThanOrEqualTo: row.bottomAnchor, constant: -8),
            button.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -16),
            button.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            leftStack.trailingAnchor.constraint(lessThanOrEqualTo: button.leadingAnchor, constant: -12),
        ])

        return row
    }

    private func makePathControl(field: NSTextField, action: Selector) -> NSView {
        field.translatesAutoresizingMaskIntoConstraints = false
        field.isBordered = true
        field.lineBreakMode = .byTruncatingMiddle
        field.cell?.truncatesLastVisibleLine = true
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let button = NSButton(title: "Browse…", target: self, action: action)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        let stack = NSStackView(views: [field, button])
        stack.orientation = .horizontal
        stack.spacing = 6
        stack.distribution = .fill
        // Pin the text field to a consistent width so the textbox stays visible
        // even when the path string is empty (otherwise the field's intrinsic
        // content size collapses and only the Browse button is rendered).
        field.widthAnchor.constraint(equalToConstant: 180).isActive = true
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
            statusLabel.stringValue = "✓ Granted — \(grantedText)"
            statusLabel.textColor = .systemGreen
            button.title = buttonTitleWhenGranted
        case .notGranted:
            statusLabel.stringValue = "⚠ Needs attention — \(missingText)"
            statusLabel.textColor = .systemOrange
            button.title = buttonTitleWhenMissing
        case .requiresManualGrant:
            statusLabel.stringValue = "⚠ Grant manually in System Settings — \(missingText)"
            statusLabel.textColor = .systemOrange
            button.title = buttonTitleWhenMissing
        }
    }

    // MARK: - Actions

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

    // MARK: - Validation & Persistence Helpers

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

// MARK: - Sidebar Data Source & Delegate

extension PreferencesWindowController: NSTableViewDataSource {
    nonisolated func numberOfRows(in tableView: NSTableView) -> Int {
        PreferencesSection.allCases.count
    }
}

extension PreferencesWindowController: NSTableViewDelegate {
    nonisolated func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        MainActor.assumeIsolated {
            guard let section = PreferencesSection(rawValue: row) else { return nil }

            let cellId = NSUserInterfaceItemIdentifier("SidebarCell")
            let cell: NSTableCellView
            if let reused = tableView.makeView(withIdentifier: cellId, owner: nil) as? NSTableCellView {
                cell = reused
            } else {
                cell = NSTableCellView()
                cell.identifier = cellId

                let imageView = NSImageView()
                imageView.translatesAutoresizingMaskIntoConstraints = false
                cell.addSubview(imageView)
                cell.imageView = imageView

                let textField = NSTextField(labelWithString: "")
                textField.translatesAutoresizingMaskIntoConstraints = false
                textField.font = .systemFont(ofSize: 13)
                textField.lineBreakMode = .byTruncatingTail
                cell.addSubview(textField)
                cell.textField = textField

                NSLayoutConstraint.activate([
                    imageView.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                    imageView.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                    imageView.widthAnchor.constraint(equalToConstant: 18),
                    imageView.heightAnchor.constraint(equalToConstant: 18),
                    textField.leadingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: 6),
                    textField.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -4),
                    textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                ])
            }

            cell.textField?.stringValue = section.title
            cell.imageView?.image = NSImage(systemSymbolName: section.systemImageName, accessibilityDescription: section.title)
            cell.imageView?.contentTintColor = .controlAccentColor

            return cell
        }
    }

    nonisolated func tableViewSelectionDidChange(_ notification: Notification) {
        MainActor.assumeIsolated {
            let row = sidebarTableView.selectedRow
            guard row >= 0, let section = PreferencesSection(rawValue: row) else { return }
            selectSection(section)
        }
    }
}

// MARK: - Custom Views

private class CardBackgroundView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.masksToBounds = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        if effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
            layer?.backgroundColor = NSColor(white: 1.0, alpha: 0.06).cgColor
        } else {
            layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        }
    }
}

private class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

// MARK: - Validation Errors

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
