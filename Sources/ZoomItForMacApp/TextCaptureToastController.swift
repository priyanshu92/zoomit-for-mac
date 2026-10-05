import AppKit

/// Small heads-up panel for text capture feedback ("Copied", "QR code copied", "No text
/// found"). It never takes focus and ignores the mouse, so the user can paste into the
/// app they were in while it is still visible.
@MainActor
final class TextCaptureToastController {
    enum Style {
        case success
        case warning
        case progress
    }

    private static let maximumWidth: CGFloat = 380
    private static let minimumWidth: CGFloat = 200
    private static let horizontalPadding: CGFloat = 14
    private static let verticalPadding: CGFloat = 11
    private static let iconSize: CGFloat = 20
    private static let iconSpacing: CGFloat = 10
    private static let anchorSpacing: CGFloat = 12
    private static let screenMargin: CGFloat = 10

    private var panel: OverlayPanel?
    private var dismissWorkItem: DispatchWorkItem?
    /// Bumped on every show so a fade-out that finishes after a newer toast appeared does
    /// not hide the newer one.
    private var generation = 0

    func show(
        title: String,
        detail: String? = nil,
        symbolName: String? = nil,
        style: Style,
        near anchor: CGRect? = nil,
        duration: TimeInterval? = nil
    ) {
        dismissWorkItem?.cancel()
        dismissWorkItem = nil
        generation += 1

        let content = makeContent(title: title, detail: detail, symbolName: symbolName, style: style)
        let panel = self.panel ?? makePanel()
        self.panel = panel
        panel.contentView = content

        let size = content.fittingSize
        let frame = CGRect(origin: origin(for: size, near: anchor), size: size)
        let wasVisible = panel.isVisible && panel.alphaValue > 0
        panel.setFrame(frame, display: true)
        if !wasVisible {
            panel.alphaValue = 0
        }
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            panel.animator().alphaValue = 1
        }

        announce([title, detail].compactMap { $0 }.joined(separator: ". "))

        guard style != .progress else { return }
        let workItem = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.dismiss()
            }
        }
        dismissWorkItem = workItem
        let visibleDuration = duration ?? (style == .warning ? 3.5 : 1.8)
        DispatchQueue.main.asyncAfter(deadline: .now() + visibleDuration, execute: workItem)
    }

    func dismiss() {
        dismissWorkItem?.cancel()
        dismissWorkItem = nil
        guard let panel, panel.isVisible else { return }
        let dismissedGeneration = generation
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.2
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard self?.generation == dismissedGeneration else { return }
                panel.orderOut(nil)
            }
        })
    }

    private func makePanel() -> OverlayPanel {
        let panel = OverlayPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        return panel
    }

    private func makeContent(title: String, detail: String?, symbolName: String?, style: Style) -> NSView {
        let background = NSVisualEffectView()
        background.material = .hudWindow
        background.state = .active
        background.blendingMode = .behindWindow
        background.appearance = NSAppearance(named: .vibrantDark)
        background.wantsLayer = true
        background.layer?.cornerRadius = 12
        background.layer?.masksToBounds = true

        let textWidth = Self.maximumWidth - Self.horizontalPadding * 2 - Self.iconSize - Self.iconSpacing

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = .white
        titleLabel.maximumNumberOfLines = 1
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.preferredMaxLayoutWidth = textWidth

        let textStack = NSStackView(views: [titleLabel])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 2

        if let detail, !detail.isEmpty {
            let detailLabel = NSTextField(wrappingLabelWithString: Self.preview(of: detail))
            detailLabel.font = .systemFont(ofSize: 12)
            detailLabel.textColor = NSColor.white.withAlphaComponent(0.78)
            // Word wrapping (not tail truncation) so `maximumNumberOfLines` caps the
            // height at three lines; tail truncation would clamp the preview to one line.
            detailLabel.maximumNumberOfLines = 3
            detailLabel.lineBreakMode = .byWordWrapping
            detailLabel.cell?.truncatesLastVisibleLine = true
            detailLabel.preferredMaxLayoutWidth = textWidth
            detailLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            textStack.addArrangedSubview(detailLabel)
            detailLabel.widthAnchor.constraint(lessThanOrEqualToConstant: textWidth).isActive = true
        }

        let leading = makeLeadingView(symbolName: symbolName, style: style)
        let row = NSStackView(views: [leading, textStack])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = Self.iconSpacing
        row.translatesAutoresizingMaskIntoConstraints = false

        // Padding is pinned with required constraints rather than `edgeInsets`: a stack
        // view only hugs its insets at low priority, and `fittingSize` drops them, which
        // left the text touching the top and bottom edges.
        background.addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: background.topAnchor, constant: Self.verticalPadding),
            row.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: Self.horizontalPadding),
            row.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -Self.horizontalPadding),
            row.bottomAnchor.constraint(equalTo: background.bottomAnchor, constant: -Self.verticalPadding),
            background.widthAnchor.constraint(greaterThanOrEqualToConstant: Self.minimumWidth),
            background.widthAnchor.constraint(lessThanOrEqualToConstant: Self.maximumWidth),
            titleLabel.widthAnchor.constraint(lessThanOrEqualToConstant: textWidth),
        ])
        return background
    }

    private func makeLeadingView(symbolName: String?, style: Style) -> NSView {
        let leading: NSView
        if style == .progress {
            let spinner = NSProgressIndicator()
            spinner.style = .spinning
            spinner.controlSize = .small
            spinner.appearance = NSAppearance(named: .vibrantDark)
            spinner.startAnimation(nil)
            leading = spinner
        } else {
            let fallbackSymbol = style == .warning ? "exclamationmark.triangle.fill" : "checkmark.circle.fill"
            let configuration = NSImage.SymbolConfiguration(pointSize: 16, weight: .semibold)
            let image = NSImage(systemSymbolName: symbolName ?? fallbackSymbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(configuration)
            let imageView = NSImageView(image: image ?? NSImage())
            imageView.contentTintColor = style == .warning ? .systemYellow : .systemGreen
            leading = imageView
        }
        leading.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            leading.widthAnchor.constraint(equalToConstant: Self.iconSize),
            leading.heightAnchor.constraint(equalToConstant: Self.iconSize),
        ])
        return leading
    }

    /// Below the anchor when there is room, otherwise above it, otherwise centered on it.
    /// Without an anchor, top-center of the screen under the pointer.
    private func origin(for size: CGSize, near anchor: CGRect?) -> CGPoint {
        let referencePoint = anchor.map { CGPoint(x: $0.midX, y: $0.midY) } ?? NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { $0.frame.contains(referencePoint) })
            ?? NSScreen.main
            ?? NSScreen.screens.first
        let visible = screen?.visibleFrame ?? CGRect(origin: .zero, size: size)

        var origin: CGPoint
        if let anchor {
            origin = CGPoint(x: anchor.midX - size.width / 2, y: anchor.minY - Self.anchorSpacing - size.height)
            if origin.y < visible.minY + Self.screenMargin {
                origin.y = anchor.maxY + Self.anchorSpacing
            }
            if origin.y + size.height > visible.maxY - Self.screenMargin {
                origin.y = anchor.midY - size.height / 2
            }
        } else {
            origin = CGPoint(x: visible.midX - size.width / 2, y: visible.maxY - size.height - 24)
        }

        origin.x = min(max(origin.x, visible.minX + Self.screenMargin), visible.maxX - size.width - Self.screenMargin)
        origin.y = min(max(origin.y, visible.minY + Self.screenMargin), visible.maxY - size.height - Self.screenMargin)
        return CGPoint(x: origin.x.rounded(), y: origin.y.rounded())
    }

    /// The panel ignores the mouse and never becomes key, so VoiceOver would not read it
    /// on its own.
    private func announce(_ message: String) {
        guard !message.isEmpty else { return }
        NSAccessibility.post(
            element: NSApp as Any,
            notification: .announcementRequested,
            userInfo: [
                .announcement: message,
                .priority: NSAccessibilityPriorityLevel.high.rawValue,
            ]
        )
    }

    /// One-paragraph preview: collapses newlines and runs of whitespace and caps length
    /// so a full-page capture doesn't lay out thousands of characters.
    private static func preview(of text: String) -> String {
        let collapsed = text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard collapsed.count > 240 else { return collapsed }
        return String(collapsed.prefix(240)) + "…"
    }
}
