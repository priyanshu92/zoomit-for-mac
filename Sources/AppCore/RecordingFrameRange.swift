import Foundation

public struct RecordingFrameRange: Equatable, Hashable, Sendable {
    public let startIndex: Int
    public let endIndexExclusive: Int

    public init?(startIndex: Int, endIndexExclusive: Int, frameCount: Int) {
        guard frameCount > 0,
              startIndex >= 0,
              startIndex < endIndexExclusive,
              endIndexExclusive <= frameCount
        else {
            return nil
        }

        self.startIndex = startIndex
        self.endIndexExclusive = endIndexExclusive
    }

    public static func full(frameCount: Int) -> RecordingFrameRange? {
        RecordingFrameRange(startIndex: 0, endIndexExclusive: frameCount, frameCount: frameCount)
    }

    public var count: Int {
        endIndexExclusive - startIndex
    }

    public var indices: Range<Int> {
        startIndex..<endIndexExclusive
    }

    public func startTime(atFramesPerSecond framesPerSecond: Double) -> TimeInterval {
        Self.seconds(forFrameCount: startIndex, framesPerSecond: framesPerSecond)
    }

    public func endTime(atFramesPerSecond framesPerSecond: Double) -> TimeInterval {
        Self.seconds(forFrameCount: endIndexExclusive, framesPerSecond: framesPerSecond)
    }

    public func duration(atFramesPerSecond framesPerSecond: Double) -> TimeInterval {
        Self.seconds(forFrameCount: count, framesPerSecond: framesPerSecond)
    }

    public func formattedStartTime(atFramesPerSecond framesPerSecond: Double) -> String {
        Self.formattedTime(startTime(atFramesPerSecond: framesPerSecond))
    }

    public func formattedEndTime(atFramesPerSecond framesPerSecond: Double) -> String {
        Self.formattedTime(endTime(atFramesPerSecond: framesPerSecond))
    }

    public func formattedDuration(atFramesPerSecond framesPerSecond: Double) -> String {
        Self.formattedTime(duration(atFramesPerSecond: framesPerSecond))
    }

    public func formattedTimeRange(atFramesPerSecond framesPerSecond: Double) -> String {
        "\(formattedStartTime(atFramesPerSecond: framesPerSecond))-\(formattedEndTime(atFramesPerSecond: framesPerSecond))"
    }

    public static func formattedTime(_ seconds: TimeInterval) -> String {
        let normalizedSeconds = seconds.isFinite ? max(0, seconds) : 0
        let roundedTenths = Int((normalizedSeconds * 10).rounded())
        let minutes = roundedTenths / 600
        let wholeSeconds = (roundedTenths / 10) % 60
        let tenths = roundedTenths % 10

        if minutes > 0 {
            return String(format: "%d:%02d.%d", minutes, wholeSeconds, tenths)
        }

        return String(format: "%d.%ds", wholeSeconds, tenths)
    }

    private static func seconds(forFrameCount frameCount: Int, framesPerSecond: Double) -> TimeInterval {
        guard framesPerSecond.isFinite, framesPerSecond > 0 else {
            return 0
        }

        return Double(frameCount) / framesPerSecond
    }
}
