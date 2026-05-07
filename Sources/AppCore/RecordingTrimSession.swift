import Foundation

public struct RecordingTrimSession: Equatable, Sendable {
    public let totalFrameCount: Int
    public let framesPerSecond: Double
    public private(set) var selectedRange: RecordingFrameRange
    public private(set) var playheadFrameIndex: Int

    public init?(
        totalFrameCount: Int,
        framesPerSecond: Double,
        selectedRange: RecordingFrameRange? = nil,
        playheadFrameIndex: Int = 0
    ) {
        guard totalFrameCount > 0,
              framesPerSecond.isFinite,
              framesPerSecond > 0
        else {
            return nil
        }

        let initialRange: RecordingFrameRange
        if let selectedRange {
            guard selectedRange.startIndex >= 0,
                  selectedRange.endIndexExclusive <= totalFrameCount
            else {
                return nil
            }
            initialRange = selectedRange
        } else if let fullRange = RecordingFrameRange.full(frameCount: totalFrameCount) {
            initialRange = fullRange
        } else {
            return nil
        }

        self.totalFrameCount = totalFrameCount
        self.framesPerSecond = framesPerSecond
        self.selectedRange = initialRange
        self.playheadFrameIndex = Self.clamped(
            playheadFrameIndex,
            lowerBound: initialRange.startIndex,
            upperBound: initialRange.endIndexExclusive - 1
        )
    }

    public var defaultSelectedRange: RecordingFrameRange {
        RecordingFrameRange.full(frameCount: totalFrameCount)!
    }

    public var lastFrameIndex: Int {
        totalFrameCount - 1
    }

    public var selectedStartFrameIndex: Int {
        selectedRange.startIndex
    }

    public var selectedEndFrameIndex: Int {
        selectedRange.endIndexExclusive - 1
    }

    public var selectedFrameCount: Int {
        selectedRange.count
    }

    public var totalDuration: TimeInterval {
        seconds(forFrameCount: totalFrameCount)
    }

    public var selectedStartTime: TimeInterval {
        selectedRange.startTime(atFramesPerSecond: framesPerSecond)
    }

    public var selectedEndTime: TimeInterval {
        selectedRange.endTime(atFramesPerSecond: framesPerSecond)
    }

    public var selectedDuration: TimeInterval {
        selectedRange.duration(atFramesPerSecond: framesPerSecond)
    }

    public var playheadTime: TimeInterval {
        seconds(forFrameCount: playheadFrameIndex)
    }

    public var playheadSelectedRelativeTime: TimeInterval {
        selectedRelativeTime(forFrame: playheadFrameIndex)
    }

    public var formattedTotalDuration: String {
        Self.formattedTime(totalDuration)
    }

    public var formattedSelectedStartTime: String {
        selectedRange.formattedStartTime(atFramesPerSecond: framesPerSecond)
    }

    public var formattedSelectedEndTime: String {
        selectedRange.formattedEndTime(atFramesPerSecond: framesPerSecond)
    }

    public var formattedSelectedDuration: String {
        selectedRange.formattedDuration(atFramesPerSecond: framesPerSecond)
    }

    public var formattedSelectedTimeRange: String {
        selectedRange.formattedTimeRange(atFramesPerSecond: framesPerSecond)
    }

    public var formattedPlayheadTime: String {
        Self.formattedTime(playheadTime)
    }

    public var formattedPlayheadSelectedRelativeTime: String {
        Self.formattedTime(playheadSelectedRelativeTime)
    }

    public mutating func resetToDefaultRange() {
        selectedRange = defaultSelectedRange
        playheadFrameIndex = selectedRange.startIndex
    }

    public mutating func resetPlayheadToSelectionStart() {
        playheadFrameIndex = selectedRange.startIndex
    }

    public mutating func setStartFrame(_ frameIndex: Int) {
        let nextStartIndex = Self.clamped(
            frameIndex,
            lowerBound: 0,
            upperBound: selectedRange.endIndexExclusive - 1
        )
        applyRange(startIndex: nextStartIndex, endIndexExclusive: selectedRange.endIndexExclusive)
    }

    public mutating func setEndFrame(_ frameIndex: Int) {
        let nextEndIndex = Self.clamped(
            frameIndex,
            lowerBound: selectedRange.startIndex,
            upperBound: lastFrameIndex
        )
        applyRange(startIndex: selectedRange.startIndex, endIndexExclusive: nextEndIndex + 1)
    }

    public mutating func setEndIndexExclusive(_ endIndexExclusive: Int) {
        let nextEndIndexExclusive = Self.clamped(
            endIndexExclusive,
            lowerBound: selectedRange.startIndex + 1,
            upperBound: totalFrameCount
        )
        applyRange(startIndex: selectedRange.startIndex, endIndexExclusive: nextEndIndexExclusive)
    }

    public mutating func setSelectedFrameRange(startFrameIndex: Int, endFrameIndex: Int) {
        let clampedStart = Self.clamped(startFrameIndex, lowerBound: 0, upperBound: lastFrameIndex)
        let clampedEnd = Self.clamped(endFrameIndex, lowerBound: 0, upperBound: lastFrameIndex)
        applyRange(
            startIndex: min(clampedStart, clampedEnd),
            endIndexExclusive: max(clampedStart, clampedEnd) + 1
        )
    }

    public mutating func setSelectedRange(_ range: RecordingFrameRange) {
        let startIndex = Self.clamped(range.startIndex, lowerBound: 0, upperBound: lastFrameIndex)
        let endIndexExclusive = Self.clamped(
            range.endIndexExclusive,
            lowerBound: startIndex + 1,
            upperBound: totalFrameCount
        )
        applyRange(startIndex: startIndex, endIndexExclusive: endIndexExclusive)
    }

    public mutating func setPlayheadFrame(_ frameIndex: Int) {
        playheadFrameIndex = clampedToSelection(frameIndex)
    }

    public mutating func setPlayheadToSelectedRelativeFrame(_ relativeFrameIndex: Int) {
        playheadFrameIndex = absoluteFrameIndex(forSelectedRelativeFrame: relativeFrameIndex)
    }

    public func selectedRelativeFrameIndex(forFrame frameIndex: Int) -> Int {
        clampedToSelection(frameIndex) - selectedRange.startIndex
    }

    public func absoluteFrameIndex(forSelectedRelativeFrame relativeFrameIndex: Int) -> Int {
        selectedRange.startIndex + Self.clamped(
            relativeFrameIndex,
            lowerBound: 0,
            upperBound: selectedFrameCount - 1
        )
    }

    public func selectedRelativeProgress(forFrame frameIndex: Int) -> Double {
        guard selectedFrameCount > 1 else {
            return 0
        }

        return Double(selectedRelativeFrameIndex(forFrame: frameIndex)) / Double(selectedFrameCount - 1)
    }

    public func frameIndex(atSelectedProgress progress: Double) -> Int {
        let normalizedProgress = Self.clampedProgress(progress)
        let relativeFrameIndex = Int((normalizedProgress * Double(selectedFrameCount - 1)).rounded())
        return absoluteFrameIndex(forSelectedRelativeFrame: relativeFrameIndex)
    }

    public func frameIndex(atOverallProgress progress: Double) -> Int {
        let normalizedProgress = Self.clampedProgress(progress)
        return Int((normalizedProgress * Double(lastFrameIndex)).rounded())
    }

    public func selectedRelativeTime(forFrame frameIndex: Int) -> TimeInterval {
        seconds(forFrameCount: selectedRelativeFrameIndex(forFrame: frameIndex))
    }

    public func frameIndex(atSelectedRelativeTime time: TimeInterval) -> Int {
        let relativeFrameIndex = frameOffset(atTime: time, upperBound: selectedFrameCount - 1)
        return absoluteFrameIndex(forSelectedRelativeFrame: relativeFrameIndex)
    }

    public func frameIndex(atTime time: TimeInterval) -> Int {
        frameOffset(atTime: time, upperBound: lastFrameIndex)
    }

    public static func formattedTime(_ seconds: TimeInterval) -> String {
        RecordingFrameRange.formattedTime(seconds)
    }

    private mutating func applyRange(startIndex: Int, endIndexExclusive: Int) {
        selectedRange = RecordingFrameRange(
            startIndex: startIndex,
            endIndexExclusive: endIndexExclusive,
            frameCount: totalFrameCount
        )!
        playheadFrameIndex = clampedToSelection(playheadFrameIndex)
    }

    private func clampedToSelection(_ frameIndex: Int) -> Int {
        Self.clamped(
            frameIndex,
            lowerBound: selectedRange.startIndex,
            upperBound: selectedRange.endIndexExclusive - 1
        )
    }

    private func seconds(forFrameCount frameCount: Int) -> TimeInterval {
        Double(frameCount) / framesPerSecond
    }

    private func frameOffset(atTime time: TimeInterval, upperBound: Int) -> Int {
        let normalizedTime = time.isFinite ? max(0, time) : 0
        guard normalizedTime < seconds(forFrameCount: upperBound) else {
            return upperBound
        }

        return Self.clamped(
            Int((normalizedTime * framesPerSecond).rounded()),
            lowerBound: 0,
            upperBound: upperBound
        )
    }

    private static func clamped(_ value: Int, lowerBound: Int, upperBound: Int) -> Int {
        min(max(value, lowerBound), upperBound)
    }

    private static func clampedProgress(_ progress: Double) -> Double {
        guard progress.isFinite else {
            return 0
        }

        return min(max(progress, 0), 1)
    }
}
