import AppCore
import Foundation

@main
enum ValidationRunner {
    static func main() throws {
        try validateWindowsEquivalentDefaults()
        try validateMenuActionGroups()
        try validateShortcutParser()
        try validateShortcutStoreFallbacks()
        try validateShortcutStorePersistence()
        try validateAppSettingsPersistence()
        try validateLegacyAppSettingsMigration()
        try validateAppSettingsReset()
        try validateDerivedAppSettings()
        try validateCaptureGeometry()
        try validateDemoMirrorGeometry()
        try validateCursorGeometry()
        try validateDisplayCoordinateConversion()
        try validateRecordingFrameRange()
        try validateRecordingTrimSession()
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
        try expect(ShortcutCatalog.windowsEquivalentDefaults[.ocrSnip]?.windowsStyleDescription == "Ctrl+Alt+6", "OCR snip shortcut mismatch")
        try expect(ShortcutCatalog.windowsEquivalentDefaults[.panorama]?.windowsStyleDescription == "Ctrl+8", "Panorama shortcut mismatch")
        try expect(ShortcutCatalog.windowsEquivalentDefaults[.savePanorama]?.windowsStyleDescription == "Ctrl+Shift+8", "Save Panorama shortcut mismatch")
        try expect(ShortcutCatalog.windowsEquivalentDefaults[.demoMirror]?.windowsStyleDescription == "Ctrl+9", "Demo Mirror shortcut mismatch")
        try expect(ShortcutCatalog.windowsEquivalentDefaults[.demoMirrorRegion]?.windowsStyleDescription == "Ctrl+Shift+9", "Demo Mirror region shortcut mismatch")
        try expect(ShortcutCatalog.windowsEquivalentDefaults[.demoMirrorWindow]?.windowsStyleDescription == "Ctrl+Alt+9", "Demo Mirror window shortcut mismatch")
    }

    private static func validateMenuActionGroups() throws {
        let grouped = ShortcutCatalog.menuActionGroups.flatMap { $0 }
        try expect(
            Set(grouped) == Set(ShortcutAction.allCases),
            "Menu action groups must cover every ShortcutAction"
        )
        try expect(
            grouped.count == ShortcutAction.allCases.count,
            "Menu action groups must not repeat a ShortcutAction"
        )
        try expect(
            ShortcutCatalog.menuActionGroups.allSatisfy { !$0.isEmpty },
            "Menu action groups must not contain an empty group"
        )
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
        settings.recordingScale = 1.5
        settings.breakDurationMinutes = 15
        settings.initialZoomFactor = 2.5
        settings.demoMirrorTrackWindowRegion = false
        settings.demoMirrorTargetDisplayID = 42
        try store.save(settings)

        let reloaded = store.load()
        try expect(reloaded.recordingScale == 1.5, "Recording scale did not persist")
        try expect(reloaded.breakDurationMinutes == 15, "Break duration did not persist")
        try expect(reloaded.initialZoomFactor == 2.5, "Zoom factor did not persist")
        try expect(!reloaded.demoMirrorTrackWindowRegion, "Demo Mirror tracking setting did not persist")
        try expect(reloaded.demoMirrorTargetDisplayID == 42, "Demo Mirror target display did not persist")
    }

    private static func validateLegacyAppSettingsMigration() throws {
        let legacySettings: [String: Any] = [
            "initialZoomFactor": 3.0,
            "breakDurationMinutes": 12,
            "breakOpacity": 0.75,
            "recordingFramesPerSecond": 8.0,
            "recordingScale": 1.0,
            "recordingSaveLocation": "Recordings",
            "screenshotSaveLocation": "Screenshots",
            "annotationFontSize": 24.0,
            "demoTypeText": "Legacy DemoType",
            "demoTypeCharactersPerTick": 3,
        ]
        let data = try JSONSerialization.data(withJSONObject: legacySettings)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)

        try expect(decoded.initialZoomFactor == 3, "Legacy settings values should be preserved")
        try expect(decoded.demoMirrorTrackWindowRegion, "Legacy settings should enable tracked window regions")
        try expect(decoded.demoMirrorTargetDisplayID == nil, "Legacy settings should use automatic target display selection")
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
    }

    private static func validateCursorGeometry() throws {
        let screenFrame = CGRect(x: 100, y: 200, width: 1000, height: 800)
        let cursorRect = CaptureGeometry.cursorRect(
            at: CGPoint(x: 250, y: 900),
            cursorSize: CGSize(width: 28, height: 40),
            cursorHotSpot: CGPoint(x: 4, y: 2),
            within: screenFrame,
            scaleFactor: 2
        )

        try expect(cursorRect == CGRect(x: 292, y: 196, width: 56, height: 80), "Cursor rect should convert hotspot to pixel coordinates")

        let partiallyClippedRect = CaptureGeometry.cursorRect(
            at: CGPoint(x: 101, y: 999),
            cursorSize: CGSize(width: 28, height: 40),
            cursorHotSpot: CGPoint(x: 4, y: 2),
            within: screenFrame,
            scaleFactor: 2
        )
        try expect(partiallyClippedRect != nil, "Partially visible cursor should be retained for drawing")

        let outsideRect = CaptureGeometry.cursorRect(
            at: CGPoint(x: 99, y: 999),
            cursorSize: CGSize(width: 28, height: 40),
            cursorHotSpot: CGPoint(x: 4, y: 2),
            within: screenFrame,
            scaleFactor: 2
        )
        try expect(outsideRect == nil, "Cursor outside the captured screen should be ignored")
    }

    private static func validateDemoMirrorGeometry() throws {
        try expect(
            DemoMirrorGeometry.reconciledTargetDisplayID(
                5,
                availableDisplayIDs: [1, 4, 5]
            ) == 5,
            "Connected Demo Mirror target should remain selected"
        )
        try expect(
            DemoMirrorGeometry.reconciledTargetDisplayID(
                5,
                availableDisplayIDs: [1, 4]
            ) == nil,
            "Disconnected Demo Mirror target should fall back to Automatic"
        )

        let target = CGRect(x: 1920, y: 0, width: 1920, height: 1200)
        let fitted = DemoMirrorGeometry.fittedRect(
            contentSize: CGSize(width: 1920, height: 1080),
            in: target
        )
        try expect(
            fitted == CGRect(x: 1920, y: 60, width: 1920, height: 1080),
            "Demo Mirror should letterbox content on the target display"
        )

        let displayFrame = CGRect(x: 100, y: 200, width: 1000, height: 800)
        let appKitSelection = CGRect(x: 250, y: 300, width: 200, height: 120)
        try expect(
            DemoMirrorGeometry.displayLocalRect(
                fromAppKitGlobal: appKitSelection,
                displayFrame: displayFrame
            ) == CGRect(x: 150, y: 580, width: 200, height: 120),
            "Demo Mirror region should convert to top-left display coordinates"
        )

        try expect(
            DemoMirrorGeometry.displayLocalRect(
                fromQuartzGlobal: CGRect(x: 100, y: 200, width: 400, height: 300),
                displayFrame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
                primaryDisplayHeight: 1080
            ) == CGRect(x: 100, y: 200, width: 400, height: 300),
            "Demo Mirror window geometry should preserve Quartz-local coordinates"
        )
    }

    private static func validateDisplayCoordinateConversion() throws {
        let referenceHeight: CGFloat = 1117
        let appKitPoint = CGPoint(x: -100, y: 1200)
        let displayPoint = CaptureGeometry.displayPoint(
            forScreenPoint: appKitPoint,
            displayOriginReferenceHeight: referenceHeight
        )
        try expect(displayPoint == CGPoint(x: -100, y: -83), "AppKit point should flip into display coordinates")

        let externalDisplayRect = CGRect(x: -1725, y: -1440, width: 2560, height: 1440)
        let externalScreenRect = CaptureGeometry.screenRect(
            forDisplayRect: externalDisplayRect,
            displayOriginReferenceHeight: referenceHeight
        )
        try expect(externalScreenRect == CGRect(x: -1725, y: 1117, width: 2560, height: 1440), "Display rect should flip into AppKit coordinates")

        let primaryDisplayRect = CGRect(x: 100, y: 80, width: 640, height: 480)
        let primaryScreenRect = CaptureGeometry.screenRect(
            forDisplayRect: primaryDisplayRect,
            displayOriginReferenceHeight: referenceHeight
        )
        try expect(primaryScreenRect == CGRect(x: 100, y: 557, width: 640, height: 480), "Primary display rect conversion mismatch")

        try expect(
            CaptureGeometry.displayPoint(forScreenPoint: CGPoint(x: 0, y: 0), displayOriginReferenceHeight: 0) == nil,
            "Invalid display reference height should reject point conversion"
        )
        try expect(
            CaptureGeometry.screenRect(forDisplayRect: .zero, displayOriginReferenceHeight: referenceHeight) == nil,
            "Empty display rect should reject screen conversion"
        )
    }

    private static func validateRecordingFrameRange() throws {
        guard let fullRange = RecordingFrameRange.full(frameCount: 12) else {
            throw ValidationError("Full recording frame range should be valid")
        }

        try expect(fullRange.startIndex == 0, "Full frame range should start at zero")
        try expect(fullRange.endIndexExclusive == 12, "Full frame range should end after the last frame")
        try expect(fullRange.count == 12, "Full frame range should expose frame count")
        try expect(Array(fullRange.indices) == Array(0..<12), "Full frame range should expose export indices")

        guard let trimmedRange = RecordingFrameRange(startIndex: 2, endIndexExclusive: 8, frameCount: 10) else {
            throw ValidationError("Trimmed recording frame range should be valid")
        }

        try expect(trimmedRange.count == 6, "Trimmed frame range should expose selected frame count")
        try expect(trimmedRange.startTime(atFramesPerSecond: 2) == 1, "Trimmed frame range start time mismatch")
        try expect(trimmedRange.endTime(atFramesPerSecond: 2) == 4, "Trimmed frame range end time mismatch")
        try expect(trimmedRange.duration(atFramesPerSecond: 2) == 3, "Trimmed frame range duration mismatch")
        try expect(trimmedRange.formattedTimeRange(atFramesPerSecond: 2) == "1.0s-4.0s", "Trimmed frame range formatted bounds mismatch")
        try expect(trimmedRange.formattedDuration(atFramesPerSecond: 2) == "3.0s", "Trimmed frame range formatted duration mismatch")

        try expect(RecordingFrameRange(startIndex: 0, endIndexExclusive: 0, frameCount: 10) == nil, "Empty frame range should be rejected")
        try expect(RecordingFrameRange(startIndex: -1, endIndexExclusive: 3, frameCount: 10) == nil, "Negative frame range should be rejected")
        try expect(RecordingFrameRange(startIndex: 4, endIndexExclusive: 11, frameCount: 10) == nil, "Out-of-bounds frame range should be rejected")
        try expect(RecordingFrameRange.full(frameCount: 0) == nil, "Empty recording should not produce a full frame range")
        try expect(trimmedRange.duration(atFramesPerSecond: 0) == 0, "Invalid FPS should produce zero duration")
    }

    private static func validateRecordingTrimSession() throws {
        guard var session = RecordingTrimSession(totalFrameCount: 10, framesPerSecond: 2) else {
            throw ValidationError("Recording trim session should initialize for non-empty recordings")
        }

        try expect(session.totalFrameCount == 10, "Trim session should expose total frame count")
        try expect(session.framesPerSecond == 2, "Trim session should expose FPS")
        try expect(session.selectedRange == RecordingFrameRange.full(frameCount: 10), "Trim session should default to full frame range")
        try expect(session.selectedStartFrameIndex == 0, "Default trim range should start at the first frame")
        try expect(session.selectedEndFrameIndex == 9, "Default trim range should end at the last frame")
        try expect(session.playheadFrameIndex == 0, "Default playhead should start at the first selected frame")
        try expect(session.totalDuration == 5, "Trim session total duration mismatch")
        try expect(session.formattedTotalDuration == "5.0s", "Trim session formatted total duration mismatch")
        try expect(session.formattedSelectedTimeRange == "0.0s-5.0s", "Default trim time range mismatch")

        session.setStartFrame(12)
        try expect(session.selectedRange == RecordingFrameRange(startIndex: 9, endIndexExclusive: 10, frameCount: 10), "Start handle should clamp before the selected end")
        try expect(session.playheadFrameIndex == 9, "Playhead should clamp into the selected range after moving start")

        session.setEndFrame(-4)
        try expect(session.selectedRange == RecordingFrameRange(startIndex: 9, endIndexExclusive: 10, frameCount: 10), "End handle should clamp after the selected start")

        session.resetToDefaultRange()
        try expect(session.selectedRange == RecordingFrameRange.full(frameCount: 10), "Reset should restore the full recording range")
        try expect(session.playheadFrameIndex == 0, "Reset should move the playhead to the selection start")

        session.setEndFrame(4)
        session.setPlayheadFrame(9)
        try expect(session.selectedRange == RecordingFrameRange(startIndex: 0, endIndexExclusive: 5, frameCount: 10), "End handle should use an inclusive frame index")
        try expect(session.playheadFrameIndex == 4, "Playhead should clamp to the selected end")

        session.setPlayheadFrame(-2)
        try expect(session.playheadFrameIndex == 0, "Playhead should clamp to the selected start")

        session.setStartFrame(3)
        try expect(session.selectedRange == RecordingFrameRange(startIndex: 3, endIndexExclusive: 5, frameCount: 10), "Start handle should preserve the current selected end")
        try expect(session.playheadFrameIndex == 3, "Playhead should clamp to the new selected start")
        try expect(session.selectedFrameCount == 2, "Selected frame count mismatch")
        try expect(session.selectedDuration == 1, "Selected duration mismatch")
        try expect(session.selectedRelativeFrameIndex(forFrame: 99) == 1, "Relative frame conversion should clamp to selection")
        try expect(session.absoluteFrameIndex(forSelectedRelativeFrame: -8) == 3, "Negative relative frame should clamp to selection start")
        try expect(session.absoluteFrameIndex(forSelectedRelativeFrame: 8) == 4, "Large relative frame should clamp to selection end")
        try expect(session.selectedRelativeTime(forFrame: 4) == 0.5, "Selected relative time mismatch")
        try expect(session.frameIndex(atSelectedRelativeTime: 0.5) == 4, "Relative time should convert back to an absolute frame")
        try expect(session.frameIndex(atSelectedProgress: 1.5) == 4, "Selected progress should clamp to the selected end")
        try expect(session.frameIndex(atSelectedProgress: -1) == 3, "Selected progress should clamp to the selected start")
        try expect(session.selectedRelativeProgress(forFrame: 4) == 1, "Selected relative progress mismatch")
        try expect(session.frameIndex(atTime: 100) == 9, "Absolute time should clamp to recording end")

        session.setSelectedFrameRange(startFrameIndex: 8, endFrameIndex: 3)
        try expect(session.selectedRange == RecordingFrameRange(startIndex: 3, endIndexExclusive: 9, frameCount: 10), "Frame range setter should normalize reversed handles")

        guard let trimmedRange = RecordingFrameRange(startIndex: 2, endIndexExclusive: 6, frameCount: 6),
              let initializedTrimmedSession = RecordingTrimSession(
                totalFrameCount: 6,
                framesPerSecond: 4,
                selectedRange: trimmedRange,
                playheadFrameIndex: 99
              )
        else {
            throw ValidationError("Trim session should accept an initial selected range")
        }

        try expect(initializedTrimmedSession.selectedRange == trimmedRange, "Initial trim range mismatch")
        try expect(initializedTrimmedSession.playheadFrameIndex == 5, "Initial playhead should clamp to the selected range")
        try expect(initializedTrimmedSession.formattedSelectedDuration == "1.0s", "Initial selected duration formatting mismatch")

        let outOfBoundsRange = RecordingFrameRange(startIndex: 0, endIndexExclusive: 6, frameCount: 6)
        try expect(RecordingTrimSession(totalFrameCount: 5, framesPerSecond: 2, selectedRange: outOfBoundsRange) == nil, "Initial trim range should not exceed total frames")
        try expect(RecordingTrimSession(totalFrameCount: 0, framesPerSecond: 2) == nil, "Empty recording should not create a trim session")
        try expect(RecordingTrimSession(totalFrameCount: 10, framesPerSecond: 0) == nil, "Invalid FPS should not create a trim session")
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
