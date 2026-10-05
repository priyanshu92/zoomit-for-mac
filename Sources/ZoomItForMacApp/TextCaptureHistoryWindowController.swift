import AppCore
import AppKit

/// Searchable list of past text captures, plus buttons to start new ones.
@MainActor
final class TextCaptureHistoryWindowController: NSWindowController {
    /// Key the window position is saved under in `UserDefaults`.
    private static let frameAutosaveName = NSWindow.FrameAutosaveName("ZoomItTextCaptureHistoryWindow")
    /// Lets the window server remove this window before the screen is frozen for a
    /// capture; otherwise the history window ends up in the captured image.
    private static let hideSettleDelay: TimeInterval = 0.25
    private static let filterKinds: [TextCaptureKind?] = [nil, .text, .table, .link, .code]

    var onCaptureScreen: (() -> Void)?
    var onCaptureClipboard: (() -> Void)?
    var onOpenFile: (() -> Void)?
    var onCopy: ((TextCaptureRecord) -> Void)?
    var onDelete: ((TextCaptureRecord) -> Void)?
    var onClear: (() -> Void)?

    private let historyStore: TextCaptureHistoryStore
    private let settingsStore: AppSettingsStore
    private let shortcutStore: ShortcutStore

    private var allRecords: [TextCaptureRecord] = []
    private var visibleRecords: [TextCaptureRecord] = []
    private var selectedKind: TextCaptureKind?

    private let captureButton = NSButton()
    private let clipboardButton = NSButton()
    private let fileButton = NSButton()
    private let searchField = NSSearchField()
    private let filterControl = NSSegmentedControl()
    private let tableView = TextCaptureHistoryTableView()
    private let scrollView = NSScrollView()
    private let emptyStateView = NSStackView()
    private let emptyStateTitle = NSTextField(labelWithString: "")
    private let emptyStateDetail = NSTextField(wrappingLabelWithString: "")
    private let footerIcon = NSImageView()
    private let footerLabel = NSTextField(labelWithString: "")
    private let clearButton = NSButton(title: "Clear History…", target: nil, action: nil)

    init(historyStore: TextCaptureHistoryStore, settingsStore: AppSettingsStore, shortcutStore: ShortcutStore) {
        self.historyStore = historyStore
        self.settingsStore = settingsStore
        self.shortcutStore = shortcutStore

        let window = TextCaptureHistoryWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 580),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Text Capture History"
        window.minSize = NSSize(width: 400, height: 420)
        window.isReleasedWhenClosed = false
        super.init(window: window)

        shouldCascadeWindows = false
        if !window.setFrameUsingName(Self.frameAutosaveName) {
            window.center()
        }
        window.setFrameAutosaveName(Self.frameAutosaveName)
        window.delegate = self
        window.onFind = { [weak self] in
            guard let self else { return }
            self.window?.makeFirstResponder(self.searchField)
        }

        configureUI(in: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func present() {
        reload()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeFirstResponder(visibleRecords.isEmpty ? searchField : tableView)
    }

    func reload() {
        allRecords = historyStore.load()
        let shortcut = shortcutStore.binding(for: .ocrSnip).windowsStyleDescription
        captureButton.toolTip = "Drag over text, a link, or a QR code on screen (\(shortcut))"
        applyFilter()
    }

    // MARK: - Filtering

    private func applyFilter() {
        let selectedID = selectedRecord?.id
        let searched = TextCaptureHistory.filtered(allRecords, kind: nil, query: searchField.stringValue)
        let counts = TextCaptureHistory.counts(in: searched)

        for (segment, kind) in Self.filterKinds.enumerated() {
            let count = kind.map { counts[$0] ?? 0 } ?? searched.count
            let title = kind?.pluralTitle ?? "All"
            filterControl.setLabel("\(title) \(count)", forSegment: segment)
        }

        visibleRecords = selectedKind.map { kind in searched.filter { $0.kind == kind } } ?? searched
        tableView.reloadData()

        if let selectedID, let row = visibleRecords.firstIndex(where: { $0.id == selectedID }) {
            tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }

        updateEmptyState()
        updateFooter()
    }

    private func updateEmptyState() {
        let settings = settingsStore.load()
        let shortcut = shortcutStore.binding(for: .ocrSnip).windowsStyleDescription
        emptyStateView.isHidden = !visibleRecords.isEmpty
        if !allRecords.isEmpty {
            emptyStateTitle.stringValue = "No matches"
            emptyStateDetail.stringValue = "Try a different search or filter."
        } else if !settings.textCaptureSavesHistory {
            emptyStateTitle.stringValue = "History is off"
            emptyStateDetail.stringValue = "Captures still go to the clipboard. Turn on Save capture history in Preferences › Text Capture to keep them here."
        } else {
            emptyStateTitle.stringValue = "No captures yet"
            emptyStateDetail.stringValue = "Press \(shortcut) and drag over text, a link, or a QR code. Captures land on the clipboard and in this list."
        }
    }

    private func updateFooter() {
        let savesHistory = settingsStore.load().textCaptureSavesHistory
        footerLabel.stringValue = savesHistory
            ? "On-device · History stays on this Mac"
            : "On-device · History is off"
        clearButton.isEnabled = !allRecords.isEmpty
    }

    private var selectedRecord: TextCaptureRecord? {
        record(at: tableView.selectedRow)
    }

    private func record(at row: Int) -> TextCaptureRecord? {
        visibleRecords.indices.contains(row) ? visibleRecords[row] : nil
    }

    // MARK: - Actions

    @objc private func captureScreen() {
        window?.orderOut(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.hideSettleDelay) { [weak self] in
            self?.onCaptureScreen?()
        }
    }

    @objc private func captureClipboard() {
        onCaptureClipboard?()
    }

    @objc private func openFile() {
        onOpenFile?()
    }

    @objc private func searchChanged() {
        applyFilter()
    }

    @objc private func filterChanged() {
        let segment = filterControl.selectedSegment
        selectedKind = Self.filterKinds.indices.contains(segment) ? Self.filterKinds[segment] : nil
        applyFilter()
    }

    @objc private func copySelectedRecord() {
        let row = tableView.clickedRow >= 0 ? tableView.clickedRow : tableView.selectedRow
        guard let record = record(at: row) else { return }
        onCopy?(record)
    }

    @objc private func openSelectedLink() {
        let row = tableView.clickedRow >= 0 ? tableView.clickedRow : tableView.selectedRow
        guard let record = record(at: row), let url = Self.webURL(for: record) else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func deleteSelectedRecord() {
        let row = tableView.clickedRow >= 0 ? tableView.clickedRow : tableView.selectedRow
        guard let record = record(at: row) else { return }
        onDelete?(record)
        let nextRow = min(row, visibleRecords.count - 1)
        if nextRow >= 0 {
            tableView.selectRowIndexes(IndexSet(integer: nextRow), byExtendingSelection: false)
        }
    }

    @objc private func confirmClearHistory() {
        guard let window, !allRecords.isEmpty else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Clear text capture history?"
        let count = allRecords.count
        alert.informativeText = "This removes \(count) saved capture\(count == 1 ? "" : "s") from this Mac. Text already on the clipboard stays there."
        let clearButton = alert.addButton(withTitle: "Clear History")
        clearButton.hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            MainActor.assumeIsolated {
                self?.onClear?()
            }
        }
    }

    fileprivate static func webURL(for record: TextCaptureRecord) -> URL? {
        switch record.kind {
        case .link, .code: TextCaptureClassifier.webURL(for: record.text)
        case .text, .table: nil
        }
    }

    // MARK: - Layout

    private func configureUI(in window: NSWindow) {
        guard let contentView = window.contentView else { return }

        configureActionButton(captureButton, title: "Capture Text", symbolName: "text.viewfinder", action: #selector(captureScreen))
        captureButton.bezelColor = .controlAccentColor
        configureActionButton(clipboardButton, title: "From Clipboard", symbolName: "doc.on.clipboard", action: #selector(captureClipboard))
        clipboardButton.toolTip = "Read text from the image, PDF, or image file on the clipboard"
        configureActionButton(fileButton, title: "Open File…", symbolName: "photo.on.rectangle", action: #selector(openFile))
        fileButton.toolTip = "Read text from an image or PDF file"

        let actionRow = NSStackView(views: [captureButton, clipboardButton, fileButton])
        actionRow.orientation = .horizontal
        actionRow.distribution = .fillEqually
        actionRow.spacing = 8

        searchField.placeholderString = "Search captures"
        searchField.sendsSearchStringImmediately = true
        searchField.target = self
        searchField.action = #selector(searchChanged)
        searchField.setAccessibilityLabel("Search captures")

        filterControl.segmentCount = Self.filterKinds.count
        filterControl.trackingMode = .selectOne
        filterControl.segmentDistribution = .fillEqually
        filterControl.selectedSegment = 0
        filterControl.target = self
        filterControl.action = #selector(filterChanged)
        filterControl.setAccessibilityLabel("Filter captures by kind")

        let header = NSStackView(views: [actionRow, searchField, filterControl])
        header.orientation = .vertical
        header.alignment = .leading
        header.spacing = 10
        header.edgeInsets = NSEdgeInsets(top: 12, left: 16, bottom: 10, right: 16)
        header.translatesAutoresizingMaskIntoConstraints = false
        for view in [actionRow, searchField, filterControl] {
            view.translatesAutoresizingMaskIntoConstraints = false
            view.widthAnchor.constraint(equalTo: header.widthAnchor, constant: -32).isActive = true
        }

        configureTable()
        configureEmptyState()
        let footer = makeFooter()

        let topSeparator = makeSeparator()
        let bottomSeparator = makeSeparator()

        for view in [header, topSeparator, scrollView, emptyStateView, bottomSeparator, footer] {
            view.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview(view)
        }

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: contentView.topAnchor),
            header.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),

            topSeparator.topAnchor.constraint(equalTo: header.bottomAnchor),
            topSeparator.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            topSeparator.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),

            scrollView.topAnchor.constraint(equalTo: topSeparator.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomSeparator.topAnchor),

            emptyStateView.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            emptyStateView.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor, constant: -16),
            emptyStateView.widthAnchor.constraint(lessThanOrEqualTo: scrollView.widthAnchor, constant: -64),
            emptyStateView.widthAnchor.constraint(lessThanOrEqualToConstant: 320),

            bottomSeparator.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            bottomSeparator.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            bottomSeparator.bottomAnchor.constraint(equalTo: footer.topAnchor),

            footer.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
        ])
    }

    private func configureActionButton(_ button: NSButton, title: String, symbolName: String, action: Selector) {
        button.title = title
        button.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
        button.imagePosition = .imageLeading
        button.imageHugsTitle = true
        button.bezelStyle = .rounded
        button.controlSize = .large
        button.target = self
        button.action = action
        button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    private func configureTable() {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("TextCaptureColumn"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.style = .inset
        tableView.usesAutomaticRowHeights = true
        tableView.intercellSpacing = NSSize(width: 0, height: 2)
        tableView.allowsMultipleSelection = false
        tableView.allowsEmptySelection = true
        tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(copySelectedRecord)
        tableView.setAccessibilityLabel("Text captures")
        tableView.onCopy = { [weak self] in self?.copySelectedRecord() }
        tableView.onDelete = { [weak self] in self?.deleteSelectedRecord() }
        tableView.onCancel = { [weak self] in self?.window?.performClose(nil) }

        let menu = NSMenu()
        menu.delegate = self
        tableView.menu = menu

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.autohidesScrollers = true
    }

    private func configureEmptyState() {
        let icon = NSImageView(image: NSImage(systemSymbolName: "text.viewfinder", accessibilityDescription: nil) ?? NSImage())
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 30, weight: .light)
        icon.contentTintColor = .tertiaryLabelColor

        emptyStateTitle.font = .systemFont(ofSize: 15, weight: .semibold)
        emptyStateTitle.textColor = .secondaryLabelColor
        emptyStateTitle.alignment = .center

        emptyStateDetail.font = .systemFont(ofSize: 12)
        emptyStateDetail.textColor = .tertiaryLabelColor
        emptyStateDetail.alignment = .center

        emptyStateView.setViews([icon, emptyStateTitle, emptyStateDetail], in: .center)
        emptyStateView.orientation = .vertical
        emptyStateView.alignment = .centerX
        emptyStateView.spacing = 6
        emptyStateView.setCustomSpacing(10, after: icon)
    }

    private func makeFooter() -> NSView {
        footerIcon.image = NSImage(systemSymbolName: "lock.shield", accessibilityDescription: nil)
        footerIcon.contentTintColor = .secondaryLabelColor
        footerIcon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 11, weight: .regular)

        footerLabel.font = .systemFont(ofSize: 11)
        footerLabel.textColor = .secondaryLabelColor
        footerLabel.lineBreakMode = .byTruncatingTail
        footerLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        clearButton.target = self
        clearButton.action = #selector(confirmClearHistory)
        clearButton.bezelStyle = .rounded
        clearButton.controlSize = .small

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let footer = NSStackView(views: [footerIcon, footerLabel, spacer, clearButton])
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.spacing = 6
        footer.edgeInsets = NSEdgeInsets(top: 8, left: 16, bottom: 8, right: 16)
        return footer
    }

    private func makeSeparator() -> NSBox {
        let separator = NSBox()
        separator.boxType = .separator
        return separator
    }
}

// MARK: - Table

extension TextCaptureHistoryWindowController: NSTableViewDataSource {
    nonisolated func numberOfRows(in tableView: NSTableView) -> Int {
        MainActor.assumeIsolated {
            visibleRecords.count
        }
    }
}

extension TextCaptureHistoryWindowController: NSTableViewDelegate {
    nonisolated func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        MainActor.assumeIsolated {
            guard let record = record(at: row) else { return nil }
            let identifier = TextCaptureHistoryCellView.identifier
            let cell = tableView.makeView(withIdentifier: identifier, owner: nil) as? TextCaptureHistoryCellView
                ?? TextCaptureHistoryCellView()
            cell.configure(
                with: record,
                now: Date(),
                textWidth: TextCaptureHistoryCellView.textWidth(forColumnWidth: tableView.rect(ofColumn: 0).width)
            )
            cell.onCopy = { [weak self] in self?.onCopy?(record) }
            cell.onOpen = Self.webURL(for: record).map { url in { NSWorkspace.shared.open(url) } }
            return cell
        }
    }
}

extension TextCaptureHistoryWindowController: NSWindowDelegate {
    /// Row heights depend on the wrap width of each row's text, so rows are rebuilt for
    /// the new column width.
    nonisolated func windowDidResize(_ notification: Notification) {
        MainActor.assumeIsolated {
            let selectedRows = tableView.selectedRowIndexes
            tableView.reloadData()
            tableView.selectRowIndexes(selectedRows, byExtendingSelection: false)
        }
    }
}

extension TextCaptureHistoryWindowController: NSMenuDelegate {
    nonisolated func menuNeedsUpdate(_ menu: NSMenu) {
        MainActor.assumeIsolated {
            // The table's context menu is the only menu this delegate serves. Reading it
            // from the table instead of the parameter keeps the non-Sendable NSMenu from
            // crossing into the main-actor closure.
            guard let menu = tableView.menu else { return }
            menu.removeAllItems()
            guard let record = record(at: tableView.clickedRow) else { return }

            let copyItem = NSMenuItem(title: "Copy", action: #selector(copySelectedRecord), keyEquivalent: "")
            copyItem.target = self
            menu.addItem(copyItem)

            if Self.webURL(for: record) != nil {
                let openItem = NSMenuItem(title: "Open Link", action: #selector(openSelectedLink), keyEquivalent: "")
                openItem.target = self
                menu.addItem(openItem)
            }

            menu.addItem(.separator())
            let deleteItem = NSMenuItem(title: "Delete", action: #selector(deleteSelectedRecord), keyEquivalent: "")
            deleteItem.target = self
            menu.addItem(deleteItem)
        }
    }
}

// MARK: - Views

/// ZoomIt runs without a main menu (it is a menu bar app), so standard editing key
/// equivalents never reach text fields or the table. Route them by hand.
@MainActor
private final class TextCaptureHistoryWindow: NSWindow {
    var onFind: (() -> Void)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard modifiers == .command, let key = event.charactersIgnoringModifiers?.lowercased() else {
            return super.performKeyEquivalent(with: event)
        }

        let action: Selector?
        switch key {
        case "c": action = #selector(NSText.copy(_:))
        case "v": action = #selector(NSText.paste(_:))
        case "x": action = #selector(NSText.cut(_:))
        case "a": action = #selector(NSText.selectAll(_:))
        case "z": action = Selector(("undo:"))
        case "f":
            onFind?()
            return true
        case "w":
            performClose(nil)
            return true
        default: action = nil
        }

        if let action, NSApp.sendAction(action, to: nil, from: self) {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

@MainActor
private final class TextCaptureHistoryTableView: NSTableView {
    var onCopy: (() -> Void)?
    var onDelete: (() -> Void)?
    var onCancel: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36, 76: // Return, Enter
            onCopy?()
        case 51, 117: // Delete, Forward Delete
            onDelete?()
        default:
            super.keyDown(with: event)
        }
    }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }

    @objc func copy(_ sender: Any?) {
        onCopy?()
    }
}

@MainActor
private final class TextCaptureHistoryCellView: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("TextCaptureHistoryCell")

    var onCopy: (() -> Void)?
    var onOpen: (() -> Void)? {
        didSet { openButton.isHidden = onOpen == nil }
    }

    private let badge = NSView()
    private let iconView = NSImageView()
    private let contentLabel = NSTextField(wrappingLabelWithString: "")
    private let metadataLabel = NSTextField(labelWithString: "")
    private let copyButton = NSButton()
    private let openButton = NSButton()

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        configure()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Space the row text can use inside a column of `columnWidth`: the inset table's
    /// row padding, the badge, and the room reserved for the two accessory buttons.
    static func textWidth(forColumnWidth columnWidth: CGFloat) -> CGFloat {
        let rowPadding: CGFloat = 12
        let leadingChrome: CGFloat = 4 + 26 + 10
        let trailingChrome: CGFloat = 8 + 24 + 2 + 24 + 4
        return max(120, columnWidth - rowPadding - leadingChrome - trailingChrome)
    }

    func configure(with record: TextCaptureRecord, now: Date, textWidth: CGFloat) {
        // Word wrapping only honors `maximumNumberOfLines` in the intrinsic height when
        // `preferredMaxLayoutWidth` is set; tail truncation would instead give every hard
        // line break its own row and ignore the cap, making rows arbitrarily tall.
        contentLabel.preferredMaxLayoutWidth = textWidth
        let style = Self.style(for: record.kind)
        iconView.image = NSImage(systemSymbolName: style.symbolName, accessibilityDescription: style.label)
        iconView.contentTintColor = style.color
        badge.layer?.backgroundColor = style.color.withAlphaComponent(0.14).cgColor

        // A full-page capture can be many kilobytes; only three lines are ever visible.
        contentLabel.stringValue = record.text.count > 600 ? String(record.text.prefix(600)) : record.text
        let source = record.sourceName ?? Self.fallbackSourceName(for: record.origin)
        metadataLabel.stringValue = "\(source) · \(Self.relativeTime(record.capturedAt, now: now))"

        setAccessibilityLabel("\(style.label): \(record.text). \(metadataLabel.stringValue)")
    }

    private func configure() {
        badge.wantsLayer = true
        badge.layer?.cornerRadius = 7
        badge.translatesAutoresizingMaskIntoConstraints = false

        iconView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
        iconView.translatesAutoresizingMaskIntoConstraints = false
        badge.addSubview(iconView)

        contentLabel.font = .systemFont(ofSize: 13)
        contentLabel.textColor = .labelColor
        contentLabel.maximumNumberOfLines = 3
        contentLabel.lineBreakMode = .byWordWrapping
        contentLabel.cell?.truncatesLastVisibleLine = true
        contentLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        contentLabel.translatesAutoresizingMaskIntoConstraints = false

        metadataLabel.font = .systemFont(ofSize: 11)
        metadataLabel.textColor = .secondaryLabelColor
        metadataLabel.lineBreakMode = .byTruncatingTail
        metadataLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        metadataLabel.translatesAutoresizingMaskIntoConstraints = false

        configureAccessoryButton(copyButton, symbolName: "doc.on.doc", label: "Copy", action: #selector(copyClicked))
        configureAccessoryButton(openButton, symbolName: "arrow.up.forward.app", label: "Open Link", action: #selector(openClicked))

        let buttons = NSStackView(views: [openButton, copyButton])
        buttons.orientation = .horizontal
        buttons.spacing = 2
        buttons.translatesAutoresizingMaskIntoConstraints = false
        buttons.setContentHuggingPriority(.required, for: .horizontal)
        buttons.setContentCompressionResistancePriority(.required, for: .horizontal)

        for view in [badge, contentLabel, metadataLabel, buttons] {
            addSubview(view)
        }

        NSLayoutConstraint.activate([
            badge.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            badge.topAnchor.constraint(equalTo: topAnchor, constant: 9),
            badge.widthAnchor.constraint(equalToConstant: 26),
            badge.heightAnchor.constraint(equalToConstant: 26),
            iconView.centerXAnchor.constraint(equalTo: badge.centerXAnchor),
            iconView.centerYAnchor.constraint(equalTo: badge.centerYAnchor),

            contentLabel.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            contentLabel.leadingAnchor.constraint(equalTo: badge.trailingAnchor, constant: 10),
            contentLabel.trailingAnchor.constraint(lessThanOrEqualTo: buttons.leadingAnchor, constant: -8),

            metadataLabel.topAnchor.constraint(equalTo: contentLabel.bottomAnchor, constant: 3),
            metadataLabel.leadingAnchor.constraint(equalTo: contentLabel.leadingAnchor),
            metadataLabel.trailingAnchor.constraint(lessThanOrEqualTo: buttons.leadingAnchor, constant: -8),
            metadataLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),

            buttons.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            buttons.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    private func configureAccessoryButton(_ button: NSButton, symbolName: String, label: String, action: Selector) {
        button.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: label)
        button.imagePosition = .imageOnly
        button.isBordered = false
        button.bezelStyle = .regularSquare
        button.contentTintColor = .secondaryLabelColor
        button.toolTip = label
        button.setAccessibilityLabel(label)
        button.target = self
        button.action = action
        button.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 24),
            button.heightAnchor.constraint(equalToConstant: 24),
        ])
    }

    @objc private func copyClicked() {
        onCopy?()
    }

    @objc private func openClicked() {
        onOpen?()
    }

    private static func style(for kind: TextCaptureKind) -> (symbolName: String, color: NSColor, label: String) {
        switch kind {
        case .text: ("text.alignleft", .systemBlue, "Text")
        case .table: ("tablecells", .systemOrange, "Table")
        case .link: ("link", .systemTeal, "Link")
        case .code: ("qrcode", .systemPurple, "Code")
        }
    }

    private static func fallbackSourceName(for origin: TextCaptureOrigin) -> String {
        switch origin {
        case .screen: "Screen"
        case .clipboard: "Clipboard"
        case .file: "File"
        }
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        formatter.dateTimeStyle = .named
        return formatter
    }()

    private static func relativeTime(_ date: Date, now: Date) -> String {
        if now.timeIntervalSince(date) < 60 {
            return "Just now"
        }
        return relativeFormatter.localizedString(for: date, relativeTo: now)
    }
}
