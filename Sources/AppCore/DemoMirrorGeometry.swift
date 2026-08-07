import CoreGraphics
import Foundation

public enum DemoMirrorGeometry {
    public static func fittedRect(contentSize: CGSize, in bounds: CGRect) -> CGRect? {
        let normalizedBounds = bounds.standardized
        guard
            contentSize.width.isFinite,
            contentSize.height.isFinite,
            contentSize.width > 0,
            contentSize.height > 0,
            normalizedBounds.width > 0,
            normalizedBounds.height > 0
        else {
            return nil
        }

        let scale = min(
            normalizedBounds.width / contentSize.width,
            normalizedBounds.height / contentSize.height
        )
        let size = CGSize(
            width: (contentSize.width * scale).rounded(),
            height: (contentSize.height * scale).rounded()
        )
        return CGRect(
            x: (normalizedBounds.midX - size.width / 2).rounded(),
            y: (normalizedBounds.midY - size.height / 2).rounded(),
            width: size.width,
            height: size.height
        )
    }

    public static func displayLocalRect(
        fromAppKitGlobal rect: CGRect,
        displayFrame: CGRect
    ) -> CGRect? {
        let bounded = rect.standardized.intersection(displayFrame.standardized)
        guard !bounded.isNull, bounded.width >= 1, bounded.height >= 1 else {
            return nil
        }

        return CGRect(
            x: bounded.minX - displayFrame.minX,
            y: displayFrame.maxY - bounded.maxY,
            width: bounded.width,
            height: bounded.height
        ).integral
    }

    public static func displayLocalRect(
        fromQuartzGlobal rect: CGRect,
        displayFrame: CGRect,
        primaryDisplayHeight: CGFloat
    ) -> CGRect? {
        guard
            let appKitRect = CaptureGeometry.screenRect(
                forDisplayRect: rect,
                displayOriginReferenceHeight: primaryDisplayHeight
            )
        else {
            return nil
        }
        return displayLocalRect(fromAppKitGlobal: appKitRect, displayFrame: displayFrame)
    }
}
