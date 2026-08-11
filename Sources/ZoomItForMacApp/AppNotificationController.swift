import Foundation
import AppKit
import UserNotifications

@MainActor
final class AppNotificationController: NSObject, UNUserNotificationCenterDelegate {
    private let center: UNUserNotificationCenter?
    private let fallbackController = InAppNotificationBannerController()

    override init() {
        if Bundle.main.bundleIdentifier == nil {
            center = nil
        } else {
            center = .current()
        }
        super.init()
        center?.delegate = self
    }

    func requestAuthorization() {
        guard let center else {
            zoomItDebugLog("Using in-app notifications because this process is not running from an app bundle")
            return
        }
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error {
                zoomItDebugLog("Notification authorization failed: \(error.localizedDescription)")
            } else if !granted {
                zoomItDebugLog("Notification authorization was denied")
            }
        }
    }

    func post(title: String, message: String) {
        guard let center else {
            fallbackController.show(title: title, message: message)
            return
        }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = message
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        center.add(request) { error in
            if let error {
                zoomItDebugLog("Notification delivery failed: \(error.localizedDescription)")
            }
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}

@MainActor
private final class InAppNotificationBannerController {
    private var window: NSWindow?
    private var dismissalTimer: Timer?

    func show(title: String, message: String) {
        dismissalTimer?.invalidate()
        window?.orderOut(nil)

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = .labelColor
        titleLabel.maximumNumberOfLines = 1
        titleLabel.lineBreakMode = .byTruncatingTail

        let messageLabel = NSTextField(wrappingLabelWithString: message)
        messageLabel.font = .systemFont(ofSize: 11)
        messageLabel.textColor = .secondaryLabelColor
        messageLabel.maximumNumberOfLines = 3
        messageLabel.lineBreakMode = .byTruncatingTail

        let stack = NSStackView(views: [titleLabel, messageLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 14, right: 16)

        let card = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 360, height: 96))
        card.material = .popover
        card.state = .active
        card.wantsLayer = true
        card.layer?.cornerRadius = 12
        card.layer?.masksToBounds = true
        stack.frame = card.bounds
        stack.autoresizingMask = [.width, .height]
        card.addSubview(stack)

        let window = OverlayPanel(
            contentRect: card.bounds,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        window.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.ignoresMouseEvents = true
        window.hidesOnDeactivate = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window.contentView = card

        let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) })
            ?? NSScreen.main
            ?? NSScreen.screens.first
        if let visibleFrame = screen?.visibleFrame {
            window.setFrameOrigin(NSPoint(
                x: visibleFrame.maxX - window.frame.width - 18,
                y: visibleFrame.maxY - window.frame.height - 18
            ))
        }

        window.orderFrontRegardless()
        self.window = window
        dismissalTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.window?.orderOut(nil)
                self?.window = nil
            }
        }
    }
}
