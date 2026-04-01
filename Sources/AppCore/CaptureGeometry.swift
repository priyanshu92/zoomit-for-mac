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
