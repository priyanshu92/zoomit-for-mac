import AppCore
import AppKit
import PlatformServices
import UniformTypeIdentifiers

/// Screen-to-text capture: read a dragged screen region, a clipboard image, or an
/// image/PDF file; put the text on the clipboard; record it in history; show feedback.
@MainActor
final class TextCaptureController {
    private static let selectionPrompt =
        "Drag over text or a code to copy it. Return reads the whole display; Esc cancels."
    /// Delay before the "Reading text…" spinner appears. Most region captures finish
    /// sooner and go straight to "Copied" without a spinner flash.
    private static let progressDelay: TimeInterval = 0.35
    /// A capture still running after this long is almost always waiting on the one-time
    /// model compile (see `VisionOCRService.prepare`), so the spinner explains the wait.
    private static let slowProgressDelay: TimeInterval = 3

    private let snipController: SnipController
    private let clipboardService: ClipboardService
    private let ocrService: OCRService
    private let settingsStore: AppSettingsStore
    private let historyStore: TextCaptureHistoryStore
    private let shortcutStore: ShortcutStore
    private let toast = TextCaptureToastController()
    private var historyWindowController: TextCaptureHistoryWindowController?
    private var activeTask: Task<Void, Never>?
    private var pendingProgress: [DispatchWorkItem] = []
    private var preparedOptions: TextRecognitionOptions?
    private var isPreparing = false
    /// The region selector runs a modal loop, and the hotkey handler still dispatches
    /// onto the main queue while it is up. Without this guard a second press would
    /// start a nested selector on top of the first.
    private var isSelectingRegion = false

    /// Starts a screen capture through the coordinator so it passes the same Screen
    /// Recording permission gate as the hotkey. The argument asks to reopen the history
    /// window afterwards.
    var onRequestScreenCapture: ((Bool) -> Void)?

    init(
        snipController: SnipController,
        clipboardService: ClipboardService,
        ocrService: OCRService,
        settingsStore: AppSettingsStore,
        historyStore: TextCaptureHistoryStore,
        shortcutStore: ShortcutStore
    ) {
        self.snipController = snipController
        self.clipboardService = clipboardService
        self.ocrService = ocrService
        self.settingsStore = settingsStore
        self.historyStore = historyStore
        self.shortcutStore = shortcutStore
    }

    // MARK: - Entry points

    /// Gets Vision's models loaded for the current settings in the background. Cheap when
    /// they already are, so it is also called as each capture starts: that covers a mode
    /// change in Preferences, and the load overlaps with the user dragging a region.
    func prepareRecognizer() {
        let options = recognitionOptions(for: settingsStore.load())
        guard !isPreparing, preparedOptions != options else { return }
        isPreparing = true

        let service = ocrService
        Task { [weak self] in
            let start = Date()
            await Task.detached(priority: .utility) {
                await service.prepare(options: options)
            }.value
            zoomItDebugLog("Text recognition ready (\(options.mode.rawValue)) in \(Self.milliseconds(since: start)) ms")
            self?.isPreparing = false
            self?.preparedOptions = options
        }
    }

    func captureFromScreen(snapshot: ScreenSnapshot?, reopensHistory: Bool = false) {
        // The history window hides itself before asking for a capture, so bring it back
        // whenever the capture can't start; otherwise it silently disappears.
        guard !isSelectingRegion else {
            if reopensHistory { showHistory() }
            return
        }
        guard activeTask == nil else {
            NSSound.beep()
            if reopensHistory { showHistory() }
            return
        }
        prepareRecognizer()

        let previousApplication = Self.frontmostOtherApplication()
        let region: SnipRegionCapture
        isSelectingRegion = true
        defer { isSelectingRegion = false }
        do {
            region = try snipController.selectRegionImage(from: snapshot, prompt: Self.selectionPrompt)
        } catch {
            restoreFocus(to: previousApplication, reopensHistory: reopensHistory)
            if case SnipControllerError.selectionCancelled = error {
                return
            }
            toast.show(title: "Text capture failed", detail: error.localizedDescription, style: .warning)
            return
        }

        let center = CGPoint(x: region.selection.midX, y: region.selection.midY)
        restoreFocus(to: previousApplication, reopensHistory: reopensHistory)
        run(
            .image(region.image, orientation: .up),
            origin: .screen,
            sourceName: { Self.applicationName(atScreenPoint: center) ?? previousApplication?.localizedName },
            anchor: region.selection
        )
    }

    func captureFromClipboard() {
        guard activeTask == nil else {
            NSSound.beep()
            return
        }
        guard let input = clipboardService.textCaptureInput() else {
            toast.show(
                title: "No image on the clipboard",
                detail: "Copy a screenshot, photo, or PDF, then try again.",
                symbolName: "doc.on.clipboard",
                style: .warning
            )
            return
        }
        run(input, origin: .clipboard, sourceName: { "Clipboard" }, anchor: nil)
    }

    func captureFromFile() {
        guard activeTask == nil else {
            NSSound.beep()
            return
        }

        let panel = NSOpenPanel()
        panel.title = "Read Text from an Image or PDF"
        panel.prompt = "Read Text"
        panel.message = "ZoomIt copies the text it finds to the clipboard."
        panel.allowedContentTypes = [.image, .pdf]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true

        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }
        captureFromFile(at: url)
    }

    func captureFromFile(at url: URL) {
        guard activeTask == nil else {
            NSSound.beep()
            return
        }
        run(.file(url), origin: .file, sourceName: { url.lastPathComponent }, anchor: nil)
    }

    func showHistory() {
        let controller = historyWindowController ?? makeHistoryWindowController()
        historyWindowController = controller
        controller.present()
    }

    func clearHistory() {
        do {
            try historyStore.removeAll()
        } catch {
            zoomItDebugLog("Clearing text capture history failed: \(error.localizedDescription)")
        }
        historyWindowController?.reload()
    }

    // MARK: - Recognition

    /// `sourceName` is resolved on the main thread *after* recognition has started. The
    /// window-list lookup behind it took about 13 ms on a busy desktop, which would
    /// otherwise sit in front of the OCR call on every screen capture.
    private func run(
        _ input: TextCaptureInput,
        origin: TextCaptureOrigin,
        sourceName: () -> String?,
        anchor: CGRect?
    ) {
        let settings = settingsStore.load()
        let options = recognitionOptions(for: settings)
        let extractor = TextExtractor(ocrService: ocrService)

        scheduleProgress(after: Self.progressDelay, detail: nil, near: anchor)
        scheduleProgress(
            after: Self.slowProgressDelay,
            detail: "Getting on-device text recognition ready. This only takes long the first time.",
            near: anchor
        )

        let start = Date()
        let recognition = Task.detached(priority: .userInitiated) { () -> Result<ExtractedText, Error> in
            do {
                return .success(try await extractor.extract(from: input, options: options))
            } catch {
                return .failure(error)
            }
        }
        let resolvedSourceName = sourceName()
        activeTask = Task { [weak self] in
            let outcome = await recognition.value
            zoomItDebugLog("Text capture (\(origin.rawValue)) finished in \(Self.milliseconds(since: start)) ms")
            self?.preparedOptions = options
            self?.finish(outcome, settings: settings, origin: origin, sourceName: resolvedSourceName, anchor: anchor)
        }
    }

    private func scheduleProgress(after delay: TimeInterval, detail: String?, near anchor: CGRect?) {
        let progress = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.toast.show(title: "Reading text…", detail: detail, style: .progress, near: anchor)
            }
        }
        pendingProgress.append(progress)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: progress)
    }

    private func recognitionOptions(for settings: AppSettings) -> TextRecognitionOptions {
        TextRecognitionOptions(
            mode: settings.textRecognitionMode,
            languageCode: settings.validatedTextRecognitionLanguage,
            detectsCodes: settings.textCaptureDetectsCodes,
            detectsTables: settings.textCaptureDetectsTables
        )
    }

    private static func milliseconds(since start: Date) -> Int {
        Int((Date().timeIntervalSince(start) * 1000).rounded())
    }

    private func finish(
        _ outcome: Result<ExtractedText, Error>,
        settings: AppSettings,
        origin: TextCaptureOrigin,
        sourceName: String?,
        anchor: CGRect?
    ) {
        activeTask = nil
        pendingProgress.forEach { $0.cancel() }
        pendingProgress.removeAll()

        let extracted: ExtractedText
        switch outcome {
        case let .success(value):
            extracted = value
        case let .failure(error):
            zoomItDebugLog("Text capture failed: \(error.localizedDescription)")
            toast.show(title: "Couldn't read text", detail: error.localizedDescription, style: .warning, near: anchor)
            return
        }

        guard let capture = TextCaptureComposer.compose(
            extracted.pages,
            keepLineBreaks: settings.textCaptureKeepsLineBreaks
        ) else {
            toast.show(
                title: "No text found",
                detail: origin == .screen
                    ? "Try a larger region, or zoom in on small text first."
                    : "The image doesn't contain readable text or codes.",
                symbolName: "text.magnifyingglass",
                style: .warning,
                near: anchor
            )
            return
        }

        clipboardService.copy(text: capture.text, html: capture.html)

        var title = Self.feedbackTitle(for: capture, skippedPageCount: extracted.skippedPageCount)
        if capture.kind == .code, settings.textCaptureOpensCodeLinks, let url = capture.webURL {
            NSWorkspace.shared.open(url)
            title = "Opened \(capture.codeSymbology ?? "code") link"
        }

        toast.show(
            title: title,
            detail: Self.feedbackDetail(for: capture),
            symbolName: Self.symbolName(for: capture),
            style: .success,
            near: anchor
        )

        // Feedback first; the history write is file I/O and the user is waiting on neither.
        if settings.textCaptureSavesHistory {
            let record = TextCaptureRecord(
                text: capture.text,
                kind: capture.kind,
                origin: origin,
                sourceName: sourceName
            )
            do {
                try historyStore.append(record)
            } catch {
                zoomItDebugLog("Saving text capture history failed: \(error.localizedDescription)")
            }
            historyWindowController?.reload()
        }
    }

    private static func feedbackTitle(for capture: ComposedTextCapture, skippedPageCount: Int) -> String {
        switch capture.kind {
        case .text:
            return skippedPageCount > 0
                ? "Copied the first \(TextExtractor.maximumOCRPages) scanned pages"
                : "Copied"
        case .link:
            return "Link copied"
        case .table:
            return capture.tables.count > 1 ? "\(capture.tables.count) tables copied" : "Table copied"
        case .code:
            if capture.codeCount > 1 {
                return "\(capture.codeCount) codes copied"
            }
            return "\(capture.codeSymbology ?? "Code") code copied"
        }
    }

    /// A table preview as running text is unreadable, so describe its shape instead.
    private static func feedbackDetail(for capture: ComposedTextCapture) -> String {
        guard capture.kind == .table, let table = capture.tables.first else {
            return capture.text
        }
        let size = "\(table.rowCount) rows × \(table.columnCount) columns"
        let header = table.rows.first?.filter { !$0.isEmpty }.joined(separator: ", ") ?? ""
        return header.isEmpty ? size : "\(size): \(header)"
    }

    private static func symbolName(for capture: ComposedTextCapture) -> String {
        switch capture.kind {
        case .text:
            return "checkmark.circle.fill"
        case .table:
            return "tablecells"
        case .link:
            return "link"
        case .code:
            let isQR = capture.codeSymbology == nil || capture.codeSymbology?.contains("QR") == true
            return isQR ? "qrcode" : "barcode"
        }
    }

    // MARK: - History window

    private func makeHistoryWindowController() -> TextCaptureHistoryWindowController {
        let controller = TextCaptureHistoryWindowController(
            historyStore: historyStore,
            settingsStore: settingsStore,
            shortcutStore: shortcutStore
        )
        controller.onCaptureScreen = { [weak self] in
            self?.onRequestScreenCapture?(true)
        }
        controller.onCaptureClipboard = { [weak self] in
            self?.captureFromClipboard()
        }
        controller.onOpenFile = { [weak self] in
            self?.captureFromFile()
        }
        controller.onCopy = { [weak self] record in
            // Tables are stored as tab-separated text, which rebuilds the same HTML table.
            let html = record.kind == .table ? TextCaptureHTML.document(fromTabSeparatedText: record.text) : nil
            self?.clipboardService.copy(text: record.text, html: html)
            self?.toast.show(title: record.kind == .table ? "Table copied" : "Copied", detail: record.text, style: .success)
        }
        controller.onDelete = { [weak self] record in
            do {
                try self?.historyStore.remove(id: record.id)
            } catch {
                zoomItDebugLog("Removing a text capture failed: \(error.localizedDescription)")
            }
            self?.historyWindowController?.reload()
        }
        controller.onClear = { [weak self] in
            self?.clearHistory()
        }
        return controller
    }

    // MARK: - Focus and source app

    private static func frontmostOtherApplication() -> NSRunningApplication? {
        guard
            let application = NSWorkspace.shared.frontmostApplication,
            application.processIdentifier != ProcessInfo.processInfo.processIdentifier
        else {
            return nil
        }
        return application
    }

    /// The selection overlay activates ZoomIt so it can take keyboard input. Hand focus
    /// back afterwards so ⌘V lands in the app the user was working in, without a click.
    private func restoreFocus(to application: NSRunningApplication?, reopensHistory: Bool) {
        if reopensHistory {
            showHistory()
            return
        }
        guard let application, !application.isTerminated else { return }
        if #available(macOS 14.0, *) {
            application.activate()
        } else {
            application.activate(options: [.activateIgnoringOtherApps])
        }
    }

    /// Name of the app whose normal window is frontmost at `point` (AppKit coordinates).
    /// Only the owner name is read, which does not need Screen Recording permission.
    private static func applicationName(atScreenPoint point: CGPoint) -> String? {
        guard
            let displayPoint = CaptureGeometry.displayPoint(
                forScreenPoint: point,
                displayOriginReferenceHeight: displayOriginReferenceHeight()
            ),
            let windows = CGWindowListCopyWindowInfo(
                [.optionOnScreenOnly, .excludeDesktopElements],
                kCGNullWindowID
            ) as? [[CFString: Any]]
        else {
            return nil
        }

        let ownProcessID = ProcessInfo.processInfo.processIdentifier
        // The list is ordered front to back. Layer 0 holds ordinary app windows; higher
        // layers are the menu bar, Dock, and floating system UI.
        for window in windows {
            guard
                (window[kCGWindowLayer] as? NSNumber)?.intValue == 0,
                let ownerPID = (window[kCGWindowOwnerPID] as? NSNumber)?.int32Value,
                ownerPID != ownProcessID,
                let bounds = window[kCGWindowBounds] as? NSDictionary,
                let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary),
                frame.contains(displayPoint)
            else {
                continue
            }
            return NSRunningApplication(processIdentifier: ownerPID)?.localizedName
                ?? window[kCGWindowOwnerName] as? String
        }
        return nil
    }

    private static func displayOriginReferenceHeight() -> CGFloat {
        let mainDisplayID = CGMainDisplayID()
        if let mainDisplayScreen = NSScreen.screens.first(where: { screen in
            (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == mainDisplayID
        }) {
            return mainDisplayScreen.frame.maxY
        }
        return NSScreen.screens.first?.frame.maxY ?? 0
    }
}
