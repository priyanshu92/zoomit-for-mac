import CoreGraphics
import Foundation

public struct AppSettings: Codable, Equatable, Sendable {
    public var initialZoomFactor: Double
    public var breakDurationMinutes: Int
    public var breakOpacity: Double
    public var recordingFramesPerSecond: Double
    public var recordingScale: Double
    public var recordingSaveLocation: String
    public var screenshotSaveLocation: String
    public var annotationFontSize: Double
    public var demoTypeText: String
    public var demoTypeCharactersPerTick: Int
    public var demoMirrorTrackWindowRegion: Bool
    public var demoMirrorTargetDisplayID: UInt32?

    public init(
        initialZoomFactor: Double,
        breakDurationMinutes: Int,
        breakOpacity: Double,
        recordingFramesPerSecond: Double,
        recordingScale: Double,
        recordingSaveLocation: String,
        screenshotSaveLocation: String,
        annotationFontSize: Double,
        demoTypeText: String,
        demoTypeCharactersPerTick: Int,
        demoMirrorTrackWindowRegion: Bool = true,
        demoMirrorTargetDisplayID: UInt32? = nil
    ) {
        self.initialZoomFactor = initialZoomFactor
        self.breakDurationMinutes = breakDurationMinutes
        self.breakOpacity = breakOpacity
        self.recordingFramesPerSecond = recordingFramesPerSecond
        self.recordingScale = recordingScale
        self.recordingSaveLocation = recordingSaveLocation
        self.screenshotSaveLocation = screenshotSaveLocation
        self.annotationFontSize = annotationFontSize
        self.demoTypeText = demoTypeText
        self.demoTypeCharactersPerTick = demoTypeCharactersPerTick
        self.demoMirrorTrackWindowRegion = demoMirrorTrackWindowRegion
        self.demoMirrorTargetDisplayID = demoMirrorTargetDisplayID
    }

    public static var `default`: AppSettings {
        let desktopPath = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop", isDirectory: true).path
        return AppSettings(
            initialZoomFactor: 2.0,
            breakDurationMinutes: 10,
            breakOpacity: 0.84,
            recordingFramesPerSecond: 6,
            recordingScale: 1.0,
            recordingSaveLocation: desktopPath,
            screenshotSaveLocation: desktopPath,
            annotationFontSize: 28,
            demoTypeText: """
            ZoomIt for Mac DemoType

            This build keeps the Windows ZoomIt shortcut model:
            - Ctrl+1 Zoom
            - Ctrl+2 Draw
            - Ctrl+3 Break Timer
            - Ctrl+4 Live Zoom
            - Ctrl+5 Record
            - Ctrl+6 Snip
            - Ctrl+7 DemoType
            - Ctrl+8 Panorama Snip
            - Ctrl+9 Demo Mirror
            - Ctrl+Alt+6 OCR Snip
            """,
            demoTypeCharactersPerTick: 2,
            demoMirrorTrackWindowRegion: true,
            demoMirrorTargetDisplayID: nil
        )
    }

    private enum CodingKeys: String, CodingKey {
        case initialZoomFactor
        case breakDurationMinutes
        case breakOpacity
        case recordingFramesPerSecond
        case recordingScale
        case recordingSaveLocation
        case screenshotSaveLocation
        case annotationFontSize
        case demoTypeText
        case demoTypeCharactersPerTick
        case demoMirrorTrackWindowRegion
        case demoMirrorTargetDisplayID
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        initialZoomFactor = try values.decode(Double.self, forKey: .initialZoomFactor)
        breakDurationMinutes = try values.decode(Int.self, forKey: .breakDurationMinutes)
        breakOpacity = try values.decode(Double.self, forKey: .breakOpacity)
        recordingFramesPerSecond = try values.decode(Double.self, forKey: .recordingFramesPerSecond)
        recordingScale = try values.decode(Double.self, forKey: .recordingScale)
        recordingSaveLocation = try values.decode(String.self, forKey: .recordingSaveLocation)
        screenshotSaveLocation = try values.decode(String.self, forKey: .screenshotSaveLocation)
        annotationFontSize = try values.decode(Double.self, forKey: .annotationFontSize)
        demoTypeText = try values.decode(String.self, forKey: .demoTypeText)
        demoTypeCharactersPerTick = try values.decode(Int.self, forKey: .demoTypeCharactersPerTick)
        demoMirrorTrackWindowRegion = try values.decodeIfPresent(
            Bool.self,
            forKey: .demoMirrorTrackWindowRegion
        ) ?? true
        demoMirrorTargetDisplayID = try values.decodeIfPresent(
            UInt32.self,
            forKey: .demoMirrorTargetDisplayID
        )
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(initialZoomFactor, forKey: .initialZoomFactor)
        try values.encode(breakDurationMinutes, forKey: .breakDurationMinutes)
        try values.encode(breakOpacity, forKey: .breakOpacity)
        try values.encode(recordingFramesPerSecond, forKey: .recordingFramesPerSecond)
        try values.encode(recordingScale, forKey: .recordingScale)
        try values.encode(recordingSaveLocation, forKey: .recordingSaveLocation)
        try values.encode(screenshotSaveLocation, forKey: .screenshotSaveLocation)
        try values.encode(annotationFontSize, forKey: .annotationFontSize)
        try values.encode(demoTypeText, forKey: .demoTypeText)
        try values.encode(demoTypeCharactersPerTick, forKey: .demoTypeCharactersPerTick)
        try values.encode(demoMirrorTrackWindowRegion, forKey: .demoMirrorTrackWindowRegion)
        try values.encodeIfPresent(demoMirrorTargetDisplayID, forKey: .demoMirrorTargetDisplayID)
    }
}

public protocol AppSettingsStore: Sendable {
    func load() -> AppSettings
    func save(_ settings: AppSettings) throws
    func resetToDefaults() throws
}

public enum AppSettingsStoreError: Error {
    case failedToEncode
}

public final class UserDefaultsAppSettingsStore: AppSettingsStore, @unchecked Sendable {
    private let userDefaults: UserDefaults
    private let storageKey = "appSettings"
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    public func load() -> AppSettings {
        guard
            let data = userDefaults.data(forKey: storageKey),
            let settings = try? decoder.decode(AppSettings.self, from: data)
        else {
            return .default
        }

        return settings
    }

    public func save(_ settings: AppSettings) throws {
        guard let data = try? encoder.encode(settings) else {
            throw AppSettingsStoreError.failedToEncode
        }

        userDefaults.set(data, forKey: storageKey)
    }

    public func resetToDefaults() throws {
        try save(.default)
    }
}

public extension AppSettings {
    var validatedRecordingFramesPerSecond: Double {
        min(max(recordingFramesPerSecond, 1), 30)
    }

    var validatedRecordingScale: Double {
        min(max(recordingScale, 0.25), 2)
    }

    var validatedDemoTypeCharactersPerTick: Int {
        min(max(demoTypeCharactersPerTick, 1), 12)
    }

    var validatedAnnotationFontSize: CGFloat {
        CGFloat(min(max(annotationFontSize, 14), 72))
    }

    var trimmedDemoTypeText: String {
        let trimmed = demoTypeText.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? AppSettings.default.demoTypeText : trimmed
    }

    var demoTypeSnippets: [String] {
        let trimmed = trimmedDemoTypeText
        let snippets = trimmed
            .components(separatedBy: "\n---\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if snippets.count > 1 {
            return snippets
        }
        return [trimmed]
    }
}
