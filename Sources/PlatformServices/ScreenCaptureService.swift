import AppKit
import CoreGraphics
import Foundation

public struct ScreenSnapshot: Sendable {
    public let displayID: CGDirectDisplayID
    public let image: CGImage
    public let screenFrame: CGRect
    public let scaleFactor: CGFloat

    public init(displayID: CGDirectDisplayID, image: CGImage, screenFrame: CGRect, scaleFactor: CGFloat) {
        self.displayID = displayID
        self.image = image
        self.screenFrame = screenFrame
        self.scaleFactor = scaleFactor
    }
}

@MainActor
public protocol ScreenCaptureService {
    func captureScreen(containing point: CGPoint) -> ScreenSnapshot?
    func captureAllScreens() -> [ScreenSnapshot]
}

@MainActor
public struct MacScreenCaptureService: ScreenCaptureService {
    public init() {}

    public func captureScreen(containing point: CGPoint) -> ScreenSnapshot? {
        guard
            let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }),
            let snapshot = makeSnapshot(for: screen)
        else {
            return nil
        }

        return snapshot
    }

    public func captureAllScreens() -> [ScreenSnapshot] {
        NSScreen.screens.compactMap(makeSnapshot(for:))
    }

    private func makeSnapshot(for screen: NSScreen) -> ScreenSnapshot? {
        guard
            let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
        else {
            return nil
        }

        // Try CGWindowListCreateImage first — works on all displays including secondary monitors
        let bounds = CGDisplayBounds(displayID)
        if let image = CGWindowListCreateImage(bounds, .optionOnScreenOnly, kCGNullWindowID, .bestResolution) {
            return ScreenSnapshot(
                displayID: displayID,
                image: image,
                screenFrame: screen.frame,
                scaleFactor: screen.backingScaleFactor
            )
        }

        // Fallback to CGDisplayCreateImage
        guard let image = CGDisplayCreateImage(displayID) else {
            return nil
        }

        return ScreenSnapshot(
            displayID: displayID,
            image: image,
            screenFrame: screen.frame,
            scaleFactor: screen.backingScaleFactor
        )
    }
}
