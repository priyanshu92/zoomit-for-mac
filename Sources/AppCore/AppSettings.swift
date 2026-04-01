import CoreGraphics
import Foundation

public enum RecordingFormat: String, CaseIterable, Codable, Sendable {
    case gif
    case mp4

    public var title: String {
        rawValue.uppercased()
    }
}

public struct AppSettings: Codable, Equatable, Sendable {
    public var initialZoomFactor: Double
    public var breakDurationMinutes: Int
    public var breakOpacity: Double
    public var recordingFormat: RecordingFormat
    public var recordingFramesPerSecond: Double
    public var recordingScale: Double
    public var recordingSaveLocation: String
    public var screenshotSaveLocation: String
    public var annotationFontSize: Double
    public var demoTypeText: String
    public var demoTypeCharactersPerTick: Int

    public init(
        initialZoomFactor: Double,
        breakDurationMinutes: Int,
        breakOpacity: Double,
        recordingFormat: RecordingFormat,
        recordingFramesPerSecond: Double,
        recordingScale: Double,
        recordingSaveLocation: String,
        screenshotSaveLocation: String,
        annotationFontSize: Double,
        demoTypeText: String,
        demoTypeCharactersPerTick: Int
    ) {
        self.initialZoomFactor = initialZoomFactor
        self.breakDurationMinutes = breakDurationMinutes
        self.breakOpacity = breakOpacity
        self.recordingFormat = recordingFormat
        self.recordingFramesPerSecond = recordingFramesPerSecond
        self.recordingScale = recordingScale
        self.recordingSaveLocation = recordingSaveLocation
        self.screenshotSaveLocation = screenshotSaveLocation
        self.annotationFontSize = annotationFontSize
        self.demoTypeText = demoTypeText
        self.demoTypeCharactersPerTick = demoTypeCharactersPerTick
    }

    public static var `default`: AppSettings {
        let desktopPath = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop", isDirectory: true).path
        return AppSettings(
            initialZoomFactor: 2.0,
            breakDurationMinutes: 10,
            breakOpacity: 0.84,
            recordingFormat: .mp4,
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
            - Ctrl+Alt+6 OCR Snip
            """,
            demoTypeCharactersPerTick: 2
        )
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
