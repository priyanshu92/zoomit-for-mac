import AppCore
import Foundation

@main
enum ValidationRunner {
    static func main() throws {
        try validateWindowsEquivalentDefaults()
        try validateShortcutParser()
        try validateShortcutStoreFallbacks()
        try validateShortcutStorePersistence()
        try validateAppSettingsPersistence()
        try validateAppSettingsReset()
        try validateDerivedAppSettings()
        try validateCaptureGeometry()
        print("ValidationRunner: all checks passed")
    }

    private static func validateWindowsEquivalentDefaults() throws {
        try expect(ShortcutCatalog.windowsEquivalentDefaults[.zoom]?.windowsStyleDescription == "Ctrl+1", "Zoom shortcut mismatch")
        try expect(ShortcutCatalog.windowsEquivalentDefaults[.draw]?.windowsStyleDescription == "Ctrl+2", "Draw shortcut mismatch")
        try expect(ShortcutCatalog.windowsEquivalentDefaults[.breakTimer]?.windowsStyleDescription == "Ctrl+3", "Break timer shortcut mismatch")
        try expect(ShortcutCatalog.windowsEquivalentDefaults[.liveZoom]?.windowsStyleDescription == "Ctrl+4", "Live zoom shortcut mismatch")
        try expect(ShortcutCatalog.windowsEquivalentDefaults[.liveDraw]?.windowsStyleDescription == "Ctrl+Shift+4", "Live draw shortcut mismatch")
        try expect(ShortcutCatalog.windowsEquivalentDefaults[.record]?.windowsStyleDescription == "Ctrl+5", "Record shortcut mismatch")
        try expect(ShortcutCatalog.windowsEquivalentDefaults[.cropRecord]?.windowsStyleDescription == "Ctrl+Shift+5", "Crop record shortcut mismatch")
        try expect(ShortcutCatalog.windowsEquivalentDefaults[.windowRecord]?.windowsStyleDescription == "Ctrl+Alt+5", "Window record shortcut mismatch")
        try expect(ShortcutCatalog.windowsEquivalentDefaults[.snip]?.windowsStyleDescription == "Ctrl+6", "Snip shortcut mismatch")
        try expect(ShortcutCatalog.windowsEquivalentDefaults[.saveSnip]?.windowsStyleDescription == "Ctrl+Shift+6", "Save snip shortcut mismatch")
        try expect(ShortcutCatalog.windowsEquivalentDefaults[.demoType]?.windowsStyleDescription == "Ctrl+7", "DemoType shortcut mismatch")
        try expect(ShortcutCatalog.windowsEquivalentDefaults[.previousDemoType]?.windowsStyleDescription == "Ctrl+Shift+7", "Previous DemoType shortcut mismatch")
        try expect(ShortcutCatalog.windowsEquivalentDefaults[.panoramaSnip]?.windowsStyleDescription == "Ctrl+8", "Panorama shortcut mismatch")
        try expect(ShortcutCatalog.windowsEquivalentDefaults[.ocrSnip]?.windowsStyleDescription == "Ctrl+Alt+6", "OCR snip shortcut mismatch")
    }

    private static func validateShortcutStoreFallbacks() throws {
        let suiteName = "ShortcutStoreFallbacks-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            throw ValidationError("Unable to create UserDefaults suite")
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = UserDefaultsShortcutStore(userDefaults: defaults)
        try expect(store.binding(for: .record).windowsStyleDescription == "Ctrl+5", "Fallback shortcut mismatch")
    }

    private static func validateShortcutStorePersistence() throws {
        let suiteName = "ShortcutStorePersistence-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            throw ValidationError("Unable to create UserDefaults suite")
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = UserDefaultsShortcutStore(userDefaults: defaults)
        let customBinding = ShortcutBinding(key: "9", keyCode: 25, modifiers: [.control, .shift])
        try store.setBinding(customBinding, for: .zoom)

        try expect(store.binding(for: .zoom) == customBinding, "Custom shortcut did not persist")
        try expect(store.binding(for: .draw).windowsStyleDescription == "Ctrl+2", "Non-overridden shortcut changed unexpectedly")
    }

    private static func validateShortcutParser() throws {
        let parsed = try ShortcutBinding.parse("Ctrl+Alt+6")
        try expect(parsed.windowsStyleDescription == "Ctrl+Alt+6", "Shortcut parser formatted unexpectedly")
        try expect(parsed.keyCode == 22, "Shortcut parser key code mismatch")
    }

    private static func validateAppSettingsPersistence() throws {
        let suiteName = "AppSettingsPersistence-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            throw ValidationError("Unable to create UserDefaults suite")
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = UserDefaultsAppSettingsStore(userDefaults: defaults)
        var settings = store.load()
        settings.recordingFormat = .gif
        settings.breakDurationMinutes = 15
        settings.initialZoomFactor = 2.5
        try store.save(settings)

        let reloaded = store.load()
        try expect(reloaded.recordingFormat == .gif, "Recording format did not persist")
        try expect(reloaded.breakDurationMinutes == 15, "Break duration did not persist")
        try expect(reloaded.initialZoomFactor == 2.5, "Zoom factor did not persist")
    }

    private static func validateAppSettingsReset() throws {
        let suiteName = "AppSettingsReset-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            throw ValidationError("Unable to create UserDefaults suite")
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = UserDefaultsAppSettingsStore(userDefaults: defaults)
        var settings = store.load()
        settings.annotationFontSize = 42
        settings.demoTypeCharactersPerTick = 9
        try store.save(settings)
        try store.resetToDefaults()

        let reloaded = store.load()
        try expect(reloaded == AppSettings.default, "App settings did not reset to defaults")
    }

    private static func validateDerivedAppSettings() throws {
        let settings = AppSettings(
            initialZoomFactor: 2,
            breakDurationMinutes: 10,
            breakOpacity: 0.84,
            recordingFormat: .mp4,
            recordingFramesPerSecond: 120,
            recordingScale: 10,
            recordingSaveLocation: "Recordings",
            screenshotSaveLocation: "Screenshots",
            annotationFontSize: 4,
            demoTypeText: "   ",
            demoTypeCharactersPerTick: 99
        )

        try expect(settings.validatedRecordingFramesPerSecond == 30, "Recording FPS should clamp to 30")
        try expect(settings.validatedRecordingScale == 2, "Recording scale should clamp to 2x")
        try expect(settings.validatedAnnotationFontSize == 14, "Annotation font size should clamp to minimum")
        try expect(settings.validatedDemoTypeCharactersPerTick == 12, "DemoType speed should clamp to maximum")
        try expect(settings.trimmedDemoTypeText == AppSettings.default.demoTypeText, "Blank DemoType text should fall back to default")

        let snippetSettings = AppSettings(
            initialZoomFactor: 2,
            breakDurationMinutes: 10,
            breakOpacity: 0.84,
            recordingFormat: .mp4,
            recordingFramesPerSecond: 6,
            recordingScale: 1,
            recordingSaveLocation: "Recordings",
            screenshotSaveLocation: "Screenshots",
            annotationFontSize: 18,
            demoTypeText: "First snippet\n---\nSecond snippet",
            demoTypeCharactersPerTick: 2
        )
        try expect(snippetSettings.demoTypeSnippets == ["First snippet", "Second snippet"], "DemoType snippets should split on explicit markers")
    }

    private static func validateCaptureGeometry() throws {
        let screenFrame = CGRect(x: 100, y: 200, width: 1000, height: 800)
        let selection = CGRect(x: 250, y: 300, width: 200, height: 120)
        let cropRect = CaptureGeometry.cropRect(for: selection, within: screenFrame, scaleFactor: 2)

        try expect(cropRect == CGRect(x: 300, y: 1160, width: 400, height: 240), "Crop rect should convert to pixel coordinates")

        let canvas = CaptureGeometry.panoramaCanvas(for: [
            CGRect(x: 0, y: 0, width: 1440, height: 900),
            CGRect(x: 1440, y: 120, width: 1920, height: 1080)
        ])
        try expect(canvas == CGRect(x: 0, y: 0, width: 3360, height: 1200), "Panorama canvas should cover all displays")

        let drawRect = CaptureGeometry.panoramaDrawRect(
            for: CGRect(x: 1440, y: 120, width: 1920, height: 1080),
            canvas: canvas ?? .zero
        )
        try expect(drawRect == CGRect(x: 1440, y: 120, width: 1920, height: 1080), "Panorama draw rect should preserve screen offsets")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() {
            throw ValidationError(message)
        }
    }
}

private struct ValidationError: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}
