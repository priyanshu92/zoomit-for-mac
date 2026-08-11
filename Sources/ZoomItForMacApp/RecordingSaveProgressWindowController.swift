import AppKit

@MainActor
final class RecordingSaveProgressWindowController: NSWindowController {
    private let progressIndicator = NSProgressIndicator()
    private let detailLabel = NSTextField(labelWithString: "")

    init(formatTitle: String, frameCount: Int) {
        let window = OverlayPanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 112),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        window.level = .statusBar
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.hidesOnDeactivate = false
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window.isReleasedWhenClosed = false

        super.init(window: window)

        let card = NSVisualEffectView()
        card.material = .hudWindow
        card.state = .active
        card.wantsLayer = true
        card.layer?.cornerRadius = 14
        card.layer?.masksToBounds = true
        card.translatesAutoresizingMaskIntoConstraints = false

        let titleLabel = NSTextField(labelWithString: "Saving \(formatTitle) recording...")
        titleLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        titleLabel.textColor = .labelColor

        detailLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.stringValue = "Preparing \(frameCount) frames"

        progressIndicator.style = .bar
        progressIndicator.isIndeterminate = false
        progressIndicator.minValue = 0
        progressIndicator.maxValue = Double(max(1, frameCount))
        progressIndicator.doubleValue = 0

        let stack = NSStackView(views: [titleLabel, detailLabel, progressIndicator])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false

        card.addSubview(stack)
        window.contentView = card

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 16),
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 18),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -18),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -16),
            progressIndicator.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show() {
        guard let window else { return }
        window.center()
        window.orderFrontRegardless()
    }

    func update(completedFrames: Int, totalFrames: Int) {
        let completed = min(max(0, completedFrames), max(1, totalFrames))
        progressIndicator.maxValue = Double(max(1, totalFrames))
        progressIndicator.doubleValue = Double(completed)
        detailLabel.stringValue = "Encoding frame \(completed) of \(totalFrames)"
    }

    func finish() {
        close()
    }
}
