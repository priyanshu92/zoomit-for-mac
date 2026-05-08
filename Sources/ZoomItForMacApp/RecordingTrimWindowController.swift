import AppCore
import AppKit
import CoreGraphics

enum RecordingTrimResult: Equatable {
    case save(RecordingFrameRange)
    case cancel
}

@MainActor
final class RecordingTrimWindowController: NSWindowController, NSWindowDelegate {
    private static let preferredWindowSize = NSSize(width: 600, height: 480)
    private static let minimumWindowSize = NSSize(width: 480, height: 420)
    private static let screenMargin: CGFloat = 64

    private let frames: [CGImage]
    private let modeLabel: String
    private var session: RecordingTrimSession
    private var result: RecordingTrimResult = .cancel
    private var isRunningModal = false
    private var playbackTimer: Timer?

    private let previewImageView = NonIntrinsicImageView()
    private let previewClickReceiver = ClickThroughView()
    private let playOverlayView = PlayOverlayView()
    private let playheadLabel = NSTextField(labelWithString: "")
    private let startTimeLabel = NSTextField(labelWithString: "")
    private let endTimeLabel = NSTextField(labelWithString: "")
    private let selectedDurationLabel = NSTextField(labelWithString: "")
    private let totalDurationLabel = NSTextField(labelWithString: "")
    private let timelineView: RecordingTrimTimelineView

    init?(
        capturedFrames frames: [CGImage],
        modeLabel: String,
        session initialSession: RecordingTrimSession
    ) {
        guard !frames.isEmpty,
              initialSession.totalFrameCount == frames.count
        else {
            return nil
        }

        let trimmedModeLabel = modeLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        self.frames = frames
        self.modeLabel = trimmedModeLabel.isEmpty ? "recording" : trimmedModeLabel
        self.session = initialSession
        self.timelineView = RecordingTrimTimelineView(frames: frames, session: initialSession)

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.preferredWindowSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Trim Recording"
        window.isReleasedWhenClosed = false
        Self.fitWindowToVisibleScreen(window)
        window.minSize = Self.minimumSizeForCurrentScreen()

        super.init(window: window)

        window.delegate = self
        configureTimelineCallbacks()
        configureUI(in: window)
        refreshUI(updateTimeline: true)
    }

    convenience init?(
        capturedFrames frames: [CGImage],
        framesPerSecond: Double,
        modeLabel: String,
        initialRange: RecordingFrameRange? = nil
    ) {
        guard let session = RecordingTrimSession(
            totalFrameCount: frames.count,
            framesPerSecond: framesPerSecond,
            selectedRange: initialRange
        ) else {
            return nil
        }

        self.init(capturedFrames: frames, modeLabel: modeLabel, session: session)
    }

    convenience init?(
        capturedFrames frames: [CGImage],
        settings: AppSettings,
        modeLabel: String,
        initialRange: RecordingFrameRange? = nil
    ) {
        self.init(
            capturedFrames: frames,
            framesPerSecond: settings.validatedRecordingFramesPerSecond,
            modeLabel: modeLabel,
            initialRange: initialRange
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func runModal() -> RecordingTrimResult {
        guard let window else {
            return .cancel
        }
        guard !isRunningModal else {
            return result
        }

        result = .cancel
        refreshUI(updateTimeline: true)
        NSApp.activate(ignoringOtherApps: true)
        window.minSize = Self.minimumSizeForCurrentScreen()
        Self.fitWindowToVisibleScreen(window)
        showWindow(nil)
        window.makeKeyAndOrderFront(nil)

        isRunningModal = true
        NSApp.runModal(for: window)
        isRunningModal = false

        window.orderOut(nil)
        stopPlayback()
        return result
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        finish(with: .cancel)
        return false
    }

    private func configureTimelineCallbacks() {
        timelineView.onSessionChanged = { [weak self] updatedSession in
            self?.timelineDidChangeSession(updatedSession)
        }
    }

    private func configureUI(in window: NSWindow) {
        let contentView = NSView()
        contentView.autoresizingMask = [.width, .height]
        window.contentView = contentView

        let headerView = makeHeaderView()
        let previewView = makePreviewView()
        let statsView = makeStatsView()
        let footerView = makeFooterView()

        timelineView.translatesAutoresizingMaskIntoConstraints = false

        contentView.addSubview(headerView)
        contentView.addSubview(previewView)
        contentView.addSubview(timelineView)
        contentView.addSubview(statsView)
        contentView.addSubview(footerView)

        NSLayoutConstraint.activate([
            headerView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 18),
            headerView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            headerView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),

            previewView.topAnchor.constraint(equalTo: headerView.bottomAnchor, constant: 12),
            previewView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            previewView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            previewView.heightAnchor.constraint(greaterThanOrEqualToConstant: 72),

            timelineView.topAnchor.constraint(equalTo: previewView.bottomAnchor, constant: 12),
            timelineView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            timelineView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            timelineView.heightAnchor.constraint(equalToConstant: 132),

            statsView.topAnchor.constraint(equalTo: timelineView.bottomAnchor, constant: 10),
            statsView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            statsView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),

            footerView.topAnchor.constraint(equalTo: statsView.bottomAnchor, constant: 12),
            footerView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            footerView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            footerView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
        ])
    }

    private func makeHeaderView() -> NSView {
        let titleLabel = NSTextField(labelWithString: "Trim recording")
        titleLabel.font = .systemFont(ofSize: 20, weight: .bold)

        let subtitleLabel = NSTextField(labelWithString: "Review your \(modeLabel) capture before choosing where to save it.")
        subtitleLabel.font = .systemFont(ofSize: 12)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.lineBreakMode = .byWordWrapping
        subtitleLabel.maximumNumberOfLines = 2

        let stack = NSStackView(views: [titleLabel, subtitleLabel])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2

        return stack
    }

    private static func fitWindowToVisibleScreen(_ window: NSWindow) {
        let visibleFrame = visibleFrameForCurrentScreen()
        let maxFrameSize = NSSize(
            width: max(320, visibleFrame.width - screenMargin),
            height: max(320, visibleFrame.height - screenMargin)
        )
        let fittedSize = NSSize(
            width: min(window.frame.width, maxFrameSize.width),
            height: min(window.frame.height, maxFrameSize.height)
        )
        let fittedOrigin = NSPoint(
            x: visibleFrame.midX - fittedSize.width / 2,
            y: visibleFrame.midY - fittedSize.height / 2
        )
        window.setFrame(NSRect(origin: fittedOrigin, size: fittedSize).integral, display: false)
        window.setFrame(window.constrainFrameRect(window.frame, to: screenForCurrentMouseLocation()), display: false)
    }

    private static func minimumSizeForCurrentScreen() -> NSSize {
        let visibleFrame = visibleFrameForCurrentScreen()
        return NSSize(
            width: min(minimumWindowSize.width, max(320, visibleFrame.width - screenMargin)),
            height: min(minimumWindowSize.height, max(320, visibleFrame.height - screenMargin))
        )
    }

    private static func visibleFrameForCurrentScreen() -> NSRect {
        screenForCurrentMouseLocation()?.visibleFrame ?? NSRect(origin: .zero, size: preferredWindowSize)
    }

    private static func screenForCurrentMouseLocation() -> NSScreen? {
        let mouseLocation = NSEvent.mouseLocation
        return NSScreen.screens.first(where: { $0.visibleFrame.contains(mouseLocation) })
            ?? NSScreen.main
            ?? NSScreen.screens.first
    }

    private func makePreviewView() -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.black.cgColor
        container.layer?.cornerRadius = 14
        container.layer?.masksToBounds = true

        previewImageView.translatesAutoresizingMaskIntoConstraints = false
        previewImageView.imageAlignment = .alignCenter
        previewImageView.imageScaling = .scaleProportionallyUpOrDown
        previewImageView.wantsLayer = true
        previewImageView.setContentHuggingPriority(.defaultLow, for: .horizontal)
        previewImageView.setContentHuggingPriority(.defaultLow, for: .vertical)
        previewImageView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        previewImageView.setContentCompressionResistancePriority(.defaultLow, for: .vertical)

        previewClickReceiver.translatesAutoresizingMaskIntoConstraints = false
        previewClickReceiver.onClick = { [weak self] in
            self?.togglePlayback()
        }

        playOverlayView.translatesAutoresizingMaskIntoConstraints = false

        let labelBackground = NSVisualEffectView()
        labelBackground.translatesAutoresizingMaskIntoConstraints = false
        labelBackground.material = .hudWindow
        labelBackground.state = .active
        labelBackground.wantsLayer = true
        labelBackground.layer?.cornerRadius = 8
        labelBackground.layer?.masksToBounds = true

        playheadLabel.translatesAutoresizingMaskIntoConstraints = false
        playheadLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        playheadLabel.textColor = .white
        playheadLabel.alignment = .center

        labelBackground.addSubview(playheadLabel)
        container.addSubview(previewImageView)
        container.addSubview(labelBackground)
        container.addSubview(playOverlayView)
        container.addSubview(previewClickReceiver)

        NSLayoutConstraint.activate([
            previewImageView.topAnchor.constraint(equalTo: container.topAnchor),
            previewImageView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            previewImageView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            previewImageView.bottomAnchor.constraint(equalTo: container.bottomAnchor),

            previewClickReceiver.topAnchor.constraint(equalTo: container.topAnchor),
            previewClickReceiver.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            previewClickReceiver.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            previewClickReceiver.bottomAnchor.constraint(equalTo: container.bottomAnchor),

            playOverlayView.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            playOverlayView.centerYAnchor.constraint(equalTo: container.centerYAnchor),

            labelBackground.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 10),
            labelBackground.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -10),

            playheadLabel.topAnchor.constraint(equalTo: labelBackground.topAnchor, constant: 7),
            playheadLabel.leadingAnchor.constraint(equalTo: labelBackground.leadingAnchor, constant: 12),
            playheadLabel.trailingAnchor.constraint(equalTo: labelBackground.trailingAnchor, constant: -12),
            playheadLabel.bottomAnchor.constraint(equalTo: labelBackground.bottomAnchor, constant: -7),
        ])

        return container
    }

    private func makeStatsView() -> NSView {
        let startRow = makeStatRow(title: "Start", valueLabel: startTimeLabel)
        let endRow = makeStatRow(title: "End", valueLabel: endTimeLabel)
        let selectedRow = makeStatRow(title: "Selected", valueLabel: selectedDurationLabel)
        let totalRow = makeStatRow(title: "Total", valueLabel: totalDurationLabel)

        let grid = NSGridView(views: [
            [startRow, endRow],
            [selectedRow, totalRow],
        ])
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.rowSpacing = 6
        grid.columnSpacing = 12
        grid.xPlacement = .fill
        grid.yPlacement = .fill

        return grid
    }

    private func makeStatRow(title: String, valueLabel: NSTextField) -> NSView {
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 11, weight: .medium)
        titleLabel.textColor = .secondaryLabelColor

        valueLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        valueLabel.lineBreakMode = .byTruncatingTail
        valueLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let stack = NSStackView(views: [titleLabel, valueLabel])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .horizontal
        stack.alignment = .firstBaseline
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 5, left: 10, bottom: 5, right: 10)
        stack.wantsLayer = true
        stack.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        stack.layer?.cornerRadius = 8

        titleLabel.widthAnchor.constraint(equalToConstant: 62).isActive = true
        return stack
    }

    private func makeFooterView() -> NSView {
        let footer = NSView()
        footer.translatesAutoresizingMaskIntoConstraints = false

        let separator = NSBox()
        separator.translatesAutoresizingMaskIntoConstraints = false
        separator.boxType = .separator

        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancelClicked))
        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = "\u{1b}"

        let resetButton = NSButton(title: "Reset Trim", target: self, action: #selector(resetClicked))
        resetButton.bezelStyle = .rounded

        let saveButton = NSButton(title: "Save...", target: self, action: #selector(saveClicked))
        saveButton.bezelStyle = .rounded
        saveButton.keyEquivalent = "\r"

        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let buttonStack = NSStackView(views: [spacer, cancelButton, resetButton, saveButton])
        buttonStack.translatesAutoresizingMaskIntoConstraints = false
        buttonStack.orientation = .horizontal
        buttonStack.alignment = .centerY
        buttonStack.spacing = 8

        footer.addSubview(separator)
        footer.addSubview(buttonStack)

        NSLayoutConstraint.activate([
            separator.topAnchor.constraint(equalTo: footer.topAnchor),
            separator.leadingAnchor.constraint(equalTo: footer.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: footer.trailingAnchor),

            buttonStack.topAnchor.constraint(equalTo: separator.bottomAnchor, constant: 8),
            buttonStack.leadingAnchor.constraint(equalTo: footer.leadingAnchor, constant: 20),
            buttonStack.trailingAnchor.constraint(equalTo: footer.trailingAnchor, constant: -20),
            buttonStack.bottomAnchor.constraint(equalTo: footer.bottomAnchor, constant: -10),
        ])

        return footer
    }

    private func refreshUI(updateTimeline: Bool) {
        refreshPreviewImage()
        refreshLabels()
        if updateTimeline {
            timelineView.update(session: session)
        }
    }

    private func refreshPreviewImage() {
        let frameIndex = clampedFrameIndex(session.playheadFrameIndex)
        let frame = frames[frameIndex]
        previewImageView.image = NSImage(
            cgImage: frame,
            size: NSSize(width: frame.width, height: frame.height)
        )
    }

    private func refreshLabels() {
        let playheadNumber = clampedFrameIndex(session.playheadFrameIndex) + 1
        playheadLabel.stringValue = "Frame \(playheadNumber) of \(session.totalFrameCount) - \(session.formattedPlayheadTime)"

        startTimeLabel.stringValue = "\(session.formattedSelectedStartTime) (frame \(session.selectedStartFrameIndex + 1))"
        endTimeLabel.stringValue = "\(session.formattedSelectedEndTime) (frame \(session.selectedEndFrameIndex + 1))"
        selectedDurationLabel.stringValue = "\(session.formattedSelectedDuration) (\(session.selectedFrameCount) frames)"
        totalDurationLabel.stringValue = "\(session.formattedTotalDuration) (\(session.totalFrameCount) frames)"
    }

    private func timelineDidChangeSession(_ updatedSession: RecordingTrimSession) {
        guard updatedSession.totalFrameCount == session.totalFrameCount else {
            return
        }

        guard updatedSession != session else {
            return
        }

        stopPlayback()
        session = updatedSession
        refreshUI(updateTimeline: false)
    }

    private func finish(with result: RecordingTrimResult) {
        stopPlayback()
        self.result = result
        if isRunningModal {
            NSApp.stopModal()
        } else {
            window?.orderOut(nil)
        }
    }

    private func clampedFrameIndex(_ frameIndex: Int) -> Int {
        min(max(frameIndex, 0), frames.count - 1)
    }

    private func togglePlayback() {
        if playbackTimer == nil {
            startPlayback()
        } else {
            stopPlayback()
        }
    }

    @objc private func cancelClicked() {
        finish(with: .cancel)
    }

    @objc private func resetClicked() {
        stopPlayback()
        session.resetToDefaultRange()
        refreshUI(updateTimeline: true)
    }

    @objc private func saveClicked() {
        finish(with: .save(session.selectedRange))
    }

    private func startPlayback() {
        stopPlayback()

        if session.playheadFrameIndex >= session.selectedEndFrameIndex {
            session.resetPlayheadToSelectionStart()
        }
        refreshUI(updateTimeline: true)
        playOverlayView.isPlaying = true

        let interval = max(1.0 / session.framesPerSecond, 1.0 / 60.0)
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.advancePlayback()
            }
        }
        playbackTimer = timer
        RunLoop.main.add(timer, forMode: .common)
        RunLoop.main.add(timer, forMode: .modalPanel)
    }

    private func advancePlayback() {
        guard playbackTimer != nil else {
            return
        }

        if session.playheadFrameIndex >= session.selectedEndFrameIndex {
            stopPlayback()
            return
        }

        session.setPlayheadFrame(session.playheadFrameIndex + 1)
        refreshUI(updateTimeline: true)
    }

    private func stopPlayback() {
        playbackTimer?.invalidate()
        playbackTimer = nil
        playOverlayView.isPlaying = false
    }
}

private final class NonIntrinsicImageView: NSImageView {
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }
}

@MainActor
private final class ClickThroughView: NSView {
    var onClick: (@MainActor () -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard bounds.contains(local) else {
            return nil
        }
        return self
    }

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }
}

@MainActor
private final class PlayOverlayView: NSView {
    private static let diameter: CGFloat = 64

    var isPlaying: Bool = false {
        didSet {
            if oldValue != isPlaying {
                refreshSymbol()
            }
        }
    }

    private let imageView = NSImageView()

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: Self.diameter, height: Self.diameter))
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
        layer?.cornerRadius = Self.diameter / 2
        layer?.masksToBounds = true

        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.contentTintColor = .white
        imageView.imageScaling = .scaleProportionallyUpOrDown
        addSubview(imageView)

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.diameter),
            heightAnchor.constraint(equalToConstant: Self.diameter),
            imageView.centerXAnchor.constraint(equalTo: centerXAnchor),
            imageView.centerYAnchor.constraint(equalTo: centerYAnchor),
            imageView.widthAnchor.constraint(equalToConstant: 30),
            imageView.heightAnchor.constraint(equalToConstant: 30),
        ])

        refreshSymbol()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: Self.diameter, height: Self.diameter)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    private func refreshSymbol() {
        let symbolName = isPlaying ? "pause.fill" : "play.fill"
        let config = NSImage.SymbolConfiguration(pointSize: 26, weight: .semibold)
        let label = isPlaying ? "Pause preview" : "Play preview"
        if let symbol = NSImage(systemSymbolName: symbolName, accessibilityDescription: label) {
            imageView.image = symbol.withSymbolConfiguration(config) ?? symbol
        }
        toolTip = label
        setAccessibilityLabel(label)
    }
}
