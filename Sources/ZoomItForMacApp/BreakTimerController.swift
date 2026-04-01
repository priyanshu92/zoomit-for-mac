import AppKit
import AppCore

@MainActor
final class BreakTimerController {
    private let settingsStore: AppSettingsStore
    private var window: NSWindow?
    private weak var overlayView: BreakTimerOverlayView?
    private var timer: Timer?
    private var startDate: Date?
    private var expirationDate: Date?
    private var didSignalCompletion = false

    init(settingsStore: AppSettingsStore) {
        self.settingsStore = settingsStore
    }

    func toggle() {
        if window == nil {
            start()
        } else {
            dismiss()
        }
    }

    func dismiss() {
        timer?.invalidate()
        timer = nil
        startDate = nil
        expirationDate = nil
        didSignalCompletion = false
        window?.orderOut(nil)
        window = nil
        overlayView = nil
    }

    private func start() {
        let settings = settingsStore.load()
        guard let screen = NSScreen.main ?? NSScreen.screens.first else {
            return
        }

        let window = OverlayWindow(
            contentRect: screen.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false,
            screen: screen
        )
        window.level = .screenSaver
        window.backgroundColor = NSColor.black.withAlphaComponent(settings.breakOpacity)
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window.ignoresMouseEvents = false

        let overlayView = BreakTimerOverlayView(frame: CGRect(origin: .zero, size: screen.frame.size))
        overlayView.autoresizingMask = [.width, .height]
        overlayView.dismissHandler = { [weak self] in
            self?.dismiss()
        }
        overlayView.adjustHandler = { [weak self] delta in
            self?.adjustRemainingTime(by: delta)
        }
        window.contentView = overlayView

        self.window = window
        self.overlayView = overlayView
        startDate = Date()
        expirationDate = Date().addingTimeInterval(TimeInterval(max(1, settings.breakDurationMinutes * 60)))
        didSignalCompletion = false
        refreshDisplay()

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(overlayView)

        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshDisplay()
            }
        }
    }

    private func adjustRemainingTime(by seconds: Int) {
        guard let startDate, let expirationDate else {
            return
        }

        let baseline = max(expirationDate, Date())
        let adjustedExpiration = max(startDate.addingTimeInterval(1), baseline.addingTimeInterval(TimeInterval(seconds)))
        self.expirationDate = adjustedExpiration
        didSignalCompletion = adjustedExpiration <= Date()
        refreshDisplay()
    }

    private func refreshDisplay() {
        guard let startDate, let expirationDate else {
            dismiss()
            return
        }

        let totalSeconds = max(1, Int(expirationDate.timeIntervalSince(startDate)))
        let remainingSeconds = max(0, Int(expirationDate.timeIntervalSinceNow.rounded(.down)))
        let elapsedSeconds = min(totalSeconds, max(0, totalSeconds - remainingSeconds))
        let isComplete = remainingSeconds == 0

        if isComplete, !didSignalCompletion {
            NSSound.beep()
            didSignalCompletion = true
        } else if !isComplete {
            didSignalCompletion = false
        }

        overlayView?.update(
            remainingText: format(seconds: remainingSeconds),
            elapsedText: format(seconds: elapsedSeconds),
            totalText: format(seconds: totalSeconds),
            progress: Double(elapsedSeconds) / Double(totalSeconds),
            statusText: statusMessage(remainingSeconds: remainingSeconds, elapsedSeconds: elapsedSeconds, totalSeconds: totalSeconds),
            isComplete: isComplete
        )
    }

    private func statusMessage(remainingSeconds: Int, elapsedSeconds: Int, totalSeconds: Int) -> String {
        if remainingSeconds == 0 {
            return "Break complete — press Esc, right-click, or the hotkey again when you're ready to return."
        }

        let progress = Double(elapsedSeconds) / Double(max(totalSeconds, 1))
        switch progress {
        case ..<0.2:
            return "Settle in: look away from the screen and unclench your shoulders."
        case ..<0.6:
            return "Keep the break going: blink, breathe, and let your focus reset."
        case ..<0.9:
            return "Almost there: use arrow keys or Ctrl+scroll if you want to fine-tune the timer."
        default:
            return "Wrap up the break slowly so you come back refreshed."
        }
    }

    private func format(seconds: Int) -> String {
        let minutes = seconds / 60
        let remainder = seconds % 60
        return String(format: "%02d:%02d", minutes, remainder)
    }
}

@MainActor
private final class BreakTimerOverlayView: NSView {
    var dismissHandler: (() -> Void)?
    var adjustHandler: ((Int) -> Void)?

    private let titleLabel = NSTextField(labelWithString: "")
    private let timerLabel = NSTextField(labelWithString: "")
    private let progressLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let footerLabel = NSTextField(labelWithString: "Press Esc, right-click, arrows, or Ctrl+scroll while the timer is active")
    private let progressIndicator = NSProgressIndicator()

    override var acceptsFirstResponder: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupView()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(
        remainingText: String,
        elapsedText: String,
        totalText: String,
        progress: Double,
        statusText: String,
        isComplete: Bool
    ) {
        titleLabel.stringValue = isComplete ? "Break finished" : "Break time"
        timerLabel.stringValue = remainingText
        progressLabel.stringValue = "Elapsed \(elapsedText) of \(totalText)"
        statusLabel.stringValue = statusText
        footerLabel.stringValue = isComplete
            ? "Up/Right arrow or Ctrl+scroll adds time • Esc or right-click dismisses"
            : "Up/Right adds 1 minute • Down/Left removes 1 minute • Ctrl+scroll adjusts • Esc or right-click exits"
        progressIndicator.doubleValue = progress * 100
        progressIndicator.controlTint = isComplete ? .defaultControlTint : .graphiteControlTint
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53:
            dismissHandler?()
        case 123, 125:
            adjustHandler?(-60)
        case 124, 126:
            adjustHandler?(60)
        default:
            super.keyDown(with: event)
        }
    }

    override func cancelOperation(_ sender: Any?) {
        dismissHandler?()
    }

    override func rightMouseDown(with event: NSEvent) {
        dismissHandler?()
    }

    override func scrollWheel(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard modifiers.contains(.control) else {
            super.scrollWheel(with: event)
            return
        }

        if event.scrollingDeltaY > 0 {
            adjustHandler?(60)
        } else if event.scrollingDeltaY < 0 {
            adjustHandler?(-60)
        }
    }

    private func setupView() {
        let card = NSVisualEffectView()
        card.translatesAutoresizingMaskIntoConstraints = false
        card.material = .hudWindow
        card.blendingMode = .withinWindow
        card.state = .active
        card.wantsLayer = true
        card.layer?.cornerRadius = 28
        card.layer?.masksToBounds = true
        addSubview(card)

        configureLabel(titleLabel, font: .systemFont(ofSize: 28, weight: .semibold), alpha: 0.96)
        configureLabel(timerLabel, font: .monospacedDigitSystemFont(ofSize: 92, weight: .bold), alpha: 1.0)
        configureLabel(progressLabel, font: .monospacedSystemFont(ofSize: 16, weight: .medium), alpha: 0.86)
        configureLabel(statusLabel, font: .systemFont(ofSize: 18, weight: .medium), alpha: 0.92)
        configureLabel(footerLabel, font: .systemFont(ofSize: 14, weight: .medium), alpha: 0.78)

        timerLabel.alignment = .center
        progressLabel.alignment = .center
        statusLabel.alignment = .center
        footerLabel.alignment = .center
        statusLabel.maximumNumberOfLines = 3

        progressIndicator.translatesAutoresizingMaskIntoConstraints = false
        progressIndicator.isIndeterminate = false
        progressIndicator.minValue = 0
        progressIndicator.maxValue = 100
        progressIndicator.doubleValue = 0
        progressIndicator.style = .bar
        progressIndicator.controlSize = .regular

        let stack = NSStackView(views: [titleLabel, timerLabel, progressIndicator, progressLabel, statusLabel, footerLabel])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 16
        card.addSubview(stack)

        NSLayoutConstraint.activate([
            card.centerXAnchor.constraint(equalTo: centerXAnchor),
            card.centerYAnchor.constraint(equalTo: centerYAnchor),
            card.widthAnchor.constraint(lessThanOrEqualToConstant: 720),
            card.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 32),
            card.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -32),

            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 34),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -34),
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 28),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -28),
            progressIndicator.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
    }

    private func configureLabel(_ label: NSTextField, font: NSFont, alpha: CGFloat) {
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = font
        label.textColor = .white.withAlphaComponent(alpha)
        label.alignment = .center
        label.maximumNumberOfLines = 2
        label.lineBreakMode = .byWordWrapping
    }
}
