import CoreGraphics
import Foundation

public enum CaptureGeometry {
    public static func cropRect(
        for selection: CGRect,
        within screenFrame: CGRect,
        scaleFactor: CGFloat
    ) -> CGRect? {
        let normalizedSelection = selection.standardized.integral
        let boundedSelection = normalizedSelection.intersection(screenFrame).integral
        guard !boundedSelection.isNull, boundedSelection.width >= 1, boundedSelection.height >= 1 else {
            return nil
        }

        let relativeRect = CGRect(
            x: boundedSelection.minX - screenFrame.minX,
            y: boundedSelection.minY - screenFrame.minY,
            width: boundedSelection.width,
            height: boundedSelection.height
        )

        let scaledWidth = max(1, Int(round(relativeRect.width * scaleFactor)))
        let scaledHeight = max(1, Int(round(relativeRect.height * scaleFactor)))
        let scaledX = max(0, Int(floor(relativeRect.minX * scaleFactor)))
        let scaledY = max(0, Int(floor((screenFrame.height - relativeRect.maxY) * scaleFactor)))

        return CGRect(x: scaledX, y: scaledY, width: scaledWidth, height: scaledHeight)
    }

    public static func cursorRect(
        at mouseLocation: CGPoint,
        cursorSize: CGSize,
        cursorHotSpot: CGPoint,
        within screenFrame: CGRect,
        scaleFactor: CGFloat
    ) -> CGRect? {
        let normalizedFrame = screenFrame.standardized
        guard
            normalizedFrame.contains(mouseLocation),
            cursorSize.width > 0,
            cursorSize.height > 0,
            scaleFactor > 0
        else {
            return nil
        }

        let imageBounds = CGRect(
            x: 0,
            y: 0,
            width: normalizedFrame.width * scaleFactor,
            height: normalizedFrame.height * scaleFactor
        )
        let rect = CGRect(
            x: floor((mouseLocation.x - normalizedFrame.minX - cursorHotSpot.x) * scaleFactor),
            y: floor((normalizedFrame.maxY - mouseLocation.y - cursorHotSpot.y) * scaleFactor),
            width: ceil(cursorSize.width * scaleFactor),
            height: ceil(cursorSize.height * scaleFactor)
        )

        guard rect.intersects(imageBounds) else {
            return nil
        }

        return rect
    }

    /// Converts from AppKit's screen coordinate space to the display/Accessibility
    /// coordinate space used by CoreGraphics and AX APIs.
    public static func displayPoint(
        forScreenPoint point: CGPoint,
        displayOriginReferenceHeight: CGFloat
    ) -> CGPoint? {
        guard
            point.x.isFinite,
            point.y.isFinite,
            displayOriginReferenceHeight.isFinite,
            displayOriginReferenceHeight > 0
        else {
            return nil
        }

        return CGPoint(x: point.x, y: displayOriginReferenceHeight - point.y)
    }

    /// Converts from the display/Accessibility coordinate space used by CoreGraphics
    /// and AX APIs back into AppKit's screen coordinate space.
    public static func screenRect(
        forDisplayRect displayRect: CGRect,
        displayOriginReferenceHeight: CGFloat
    ) -> CGRect? {
        let normalizedRect = displayRect.standardized
        guard
            normalizedRect.minX.isFinite,
            normalizedRect.minY.isFinite,
            normalizedRect.width.isFinite,
            normalizedRect.height.isFinite,
            normalizedRect.width > 0,
            normalizedRect.height > 0,
            displayOriginReferenceHeight.isFinite,
            displayOriginReferenceHeight > 0
        else {
            return nil
        }

        return CGRect(
            x: normalizedRect.minX,
            y: displayOriginReferenceHeight - normalizedRect.maxY,
            width: normalizedRect.width,
            height: normalizedRect.height
        ).integral
    }

    public static func panoramaCanvas(for screenFrames: [CGRect]) -> CGRect? {
        guard var union = screenFrames.first?.standardized else {
            return nil
        }

        for frame in screenFrames.dropFirst() {
            union = union.union(frame.standardized)
        }

        return union.integral
    }

    public static func panoramaDrawRect(for screenFrame: CGRect, canvas: CGRect) -> CGRect {
        let normalizedFrame = screenFrame.standardized
        return CGRect(
            x: normalizedFrame.minX - canvas.minX,
            y: normalizedFrame.minY - canvas.minY,
            width: normalizedFrame.width,
            height: normalizedFrame.height
        ).integral
    }
}
