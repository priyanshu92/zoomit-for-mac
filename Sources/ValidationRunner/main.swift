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
        try validateTextCaptureFormatter()
        try validateTextCaptureClassifier()
        try validateTextCaptureComposer()
        try validateTextTableDetector()
        try validateTableComposition()
        try validateTextCaptureHTML()
        try validateTextCaptureHistory()
        try validateTextCaptureHistoryStore()
        try validateAppURLCommands()
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
        settings.textRecognitionLanguage = "de-DE"
        settings.textRecognitionMode = .fast
        settings.textCaptureKeepsLineBreaks = false
        settings.textCaptureDetectsTables = false
        settings.textCaptureDetectsCodes = false
        settings.textCaptureOpensCodeLinks = true
        settings.textCaptureSavesHistory = false
        try store.save(settings)

        let reloaded = store.load()
        try expect(reloaded.recordingScale == 1.5, "Recording scale did not persist")
        try expect(reloaded.breakDurationMinutes == 15, "Break duration did not persist")
        try expect(reloaded.initialZoomFactor == 2.5, "Zoom factor did not persist")
        try expect(!reloaded.demoMirrorTrackWindowRegion, "Demo Mirror tracking setting did not persist")
        try expect(reloaded.demoMirrorTargetDisplayID == 42, "Demo Mirror target display did not persist")
        try expect(reloaded.textRecognitionLanguage == "de-DE", "Text recognition language did not persist")
        try expect(reloaded.textRecognitionMode == .fast, "Text recognition mode did not persist")
        try expect(!reloaded.textCaptureKeepsLineBreaks, "Keep line breaks setting did not persist")
        try expect(!reloaded.textCaptureDetectsTables, "Keep table layout setting did not persist")
        try expect(!reloaded.textCaptureDetectsCodes, "Code detection setting did not persist")
        try expect(reloaded.textCaptureOpensCodeLinks, "Open code links setting did not persist")
        try expect(!reloaded.textCaptureSavesHistory, "Save history setting did not persist")
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
        try expect(decoded.textRecognitionLanguage == nil, "Legacy settings should detect the text language automatically")
        try expect(decoded.textRecognitionMode == .accurate, "Legacy settings should use accurate text recognition")
        try expect(decoded.textCaptureKeepsLineBreaks, "Legacy settings should keep OCR line breaks")
        try expect(decoded.textCaptureDetectsTables, "Legacy settings should keep table layout")
        try expect(decoded.textCaptureDetectsCodes, "Legacy settings should read QR codes")
        try expect(!decoded.textCaptureOpensCodeLinks, "Legacy settings must not open QR links automatically")
        try expect(decoded.textCaptureSavesHistory, "Legacy settings should save text capture history")

        var futureSettings = legacySettings
        futureSettings["textRecognitionMode"] = "quantum"
        futureSettings["textCaptureSavesHistory"] = false
        let futureData = try JSONSerialization.data(withJSONObject: futureSettings)
        let futureDecoded = try JSONDecoder().decode(AppSettings.self, from: futureData)
        try expect(futureDecoded.textRecognitionMode == .accurate, "Unknown recognition mode should fall back to accurate")
        try expect(futureDecoded.initialZoomFactor == 3, "Unknown recognition mode must not reset other settings")
        try expect(!futureDecoded.textCaptureSavesHistory, "Unknown recognition mode must not reset other text settings")
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

        var languageSettings = settings
        languageSettings.textRecognitionLanguage = "  "
        try expect(languageSettings.validatedTextRecognitionLanguage == nil, "Blank recognition language should mean automatic")
        languageSettings.textRecognitionLanguage = " fr-FR "
        try expect(languageSettings.validatedTextRecognitionLanguage == "fr-FR", "Recognition language should be trimmed")

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

    // MARK: - Text capture

    /// Builds a line in Vision's normalized space (origin bottom-left). `top` is the
    /// distance from the top edge, which reads more naturally in fixtures.
    private static func line(_ text: String, x: CGFloat = 0.05, top: CGFloat, width: CGFloat = 0.6, height: CGFloat = 0.04) -> RecognizedTextLine {
        RecognizedTextLine(text: text, boundingBox: CGRect(x: x, y: 1 - top - height, width: width, height: height))
    }

    private static func validateTextCaptureFormatter() throws {
        let wrappedParagraph = [
            line("Tenant may end this lease with sixty (60)", top: 0.10),
            line("days' written notice after the first", top: 0.15),
            line("twelve months.", top: 0.20),
        ]
        try expect(
            TextCaptureFormatter.format(wrappedParagraph, keepLineBreaks: true)
                == "Tenant may end this lease with sixty (60)\ndays' written notice after the first\ntwelve months.",
            "Keep line breaks should join lines with newlines"
        )
        try expect(
            TextCaptureFormatter.format(wrappedParagraph, keepLineBreaks: false)
                == "Tenant may end this lease with sixty (60) days' written notice after the first twelve months.",
            "Reflow should join wrapped lines with spaces"
        )

        let twoParagraphs = [
            line("First paragraph line one", top: 0.10),
            line("line two.", top: 0.15),
            line("Second paragraph.", top: 0.30),
        ]
        try expect(
            TextCaptureFormatter.format(twoParagraphs, keepLineBreaks: false)
                == "First paragraph line one line two.\nSecond paragraph.",
            "Reflow should break paragraphs at large vertical gaps"
        )

        let sameRow = [
            line("Password:", x: 0.05, top: 0.10, width: 0.2),
            line("tulip-river-4829", x: 0.30, top: 0.105, width: 0.3),
            line("Network:", x: 0.05, top: 0.15, width: 0.2),
        ]
        try expect(
            TextCaptureFormatter.format(sameRow, keepLineBreaks: true) == "Password: tulip-river-4829\nNetwork:",
            "Fragments on the same row should join with a space"
        )

        let hyphenated = [line("well-", top: 0.10), line("known fact", top: 0.15)]
        try expect(
            TextCaptureFormatter.format(hyphenated, keepLineBreaks: false) == "well-known fact",
            "Reflow should keep a trailing hyphen without inserting a space"
        )

        let japanese = [line("東京都", top: 0.10), line("千代田区", top: 0.15)]
        try expect(
            TextCaptureFormatter.format(japanese, keepLineBreaks: false) == "東京都千代田区",
            "Reflow should not add spaces between CJK lines"
        )

        let list = [
            line("Staging checklist", top: 0.10),
            line("1. Run migrations", top: 0.15),
            line("2. Turn on the flag", top: 0.20),
            line("• Ship it", top: 0.25),
        ]
        try expect(
            TextCaptureFormatter.format(list, keepLineBreaks: false)
                == "Staging checklist\n1. Run migrations\n2. Turn on the flag\n• Ship it",
            "Reflow should keep list items on their own lines"
        )

        let nextColumn = [
            line("Column one end", x: 0.05, top: 0.80, width: 0.4),
            line("Column two start", x: 0.55, top: 0.10, width: 0.4),
        ]
        try expect(
            TextCaptureFormatter.format(nextColumn, keepLineBreaks: false) == "Column one end\nColumn two start",
            "Reflow should break when Vision moves back up into the next column"
        )

        try expect(TextCaptureFormatter.format([], keepLineBreaks: true).isEmpty, "No lines should format to empty text")
        try expect(
            TextCaptureFormatter.format([line("  ", top: 0.1), line(" Hello ", top: 0.2)], keepLineBreaks: true) == "Hello",
            "Blank lines should be dropped and text trimmed"
        )
    }

    private static func validateTextCaptureClassifier() throws {
        try expect(TextCaptureClassifier.kind(for: "https://nerdynikhil.com") == .link, "HTTPS URL should be a link")
        try expect(
            TextCaptureClassifier.webURL(for: "  https://staging.northwind.dev/admin?flag=new-billing\n")?.absoluteString
                == "https://staging.northwind.dev/admin?flag=new-billing",
            "Whitespace around a URL should be ignored"
        )
        try expect(
            TextCaptureClassifier.webURL(for: "cafe.menu/t12")?.absoluteString == "https://cafe.menu/t12",
            "A bare domain should become an HTTPS link"
        )
        try expect(
            TextCaptureClassifier.webURL(for: "beta.northwind.dev/join")?.absoluteString == "https://beta.northwind.dev/join",
            "A bare link on a newer TLD should be detected when it has a path"
        )
        try expect(TextCaptureClassifier.kind(for: "notes.txt") == .text, "A file name is not a link")
        try expect(TextCaptureClassifier.kind(for: "Hotel.Sternenfeld") == .text, "Words joined by a period are not a link")
        try expect(TextCaptureClassifier.kind(for: "src/main.swift") == .text, "A relative path is not a link")
        try expect(TextCaptureClassifier.kind(for: "Visit example.com today") == .text, "A sentence containing a URL is text")
        try expect(TextCaptureClassifier.kind(for: "Hotel Sternenfeld") == .text, "Plain words are text")
        try expect(TextCaptureClassifier.webURL(for: "john@example.com") == nil, "Email addresses are not web links")
        try expect(TextCaptureClassifier.webURL(for: "mailto:john@example.com") == nil, "mailto: is not a web link")
        try expect(TextCaptureClassifier.webURL(for: "file:///etc/passwd") == nil, "file: URLs must never be opened")
        try expect(TextCaptureClassifier.webURL(for: "javascript:alert(1)") == nil, "javascript: URLs must never be opened")
        try expect(TextCaptureClassifier.webURL(for: "zoomit://record") == nil, "App URL schemes must never be opened")
    }

    private static func validateTextCaptureComposer() throws {
        let qr = RecognizedCode(payload: "https://beta.northwind.dev/join", symbology: "QR")
        let caption = [line("Scan for early access.", top: 0.8)]

        let slide = TextCaptureComposer.compose(
            [.recognized(TextRecognitionResult(lines: caption, codes: [qr]))],
            keepLineBreaks: true
        )
        try expect(slide?.kind == .code, "A code in a single image should win over its caption")
        try expect(slide?.text == qr.payload, "Code capture should copy the payload")
        try expect(slide?.codeSymbology == "QR" && slide?.codeCount == 1, "Single code should report its symbology")
        try expect(slide?.webURL?.absoluteString == qr.payload, "A single QR web link should be openable")

        let twoCodes = TextCaptureComposer.compose(
            [.recognized(TextRecognitionResult(lines: [], codes: [
                RecognizedCode(payload: "WIFI:S:Home;T:WPA;P:secret;;", symbology: "QR"),
                RecognizedCode(payload: "4006381333931", symbology: "EAN-13"),
                RecognizedCode(payload: "4006381333931", symbology: "EAN-13"),
            ]))],
            keepLineBreaks: true
        )
        try expect(twoCodes?.text == "WIFI:S:Home;T:WPA;P:secret;;\n4006381333931", "Duplicate code payloads should collapse")
        try expect(twoCodes?.codeCount == 2 && twoCodes?.codeSymbology == nil, "Multiple codes should not report one symbology")
        try expect(twoCodes?.webURL == nil, "Multiple codes must not open a link")

        let document = TextCaptureComposer.compose(
            [
                .embedded("Page one text"),
                .recognized(TextRecognitionResult(lines: caption, codes: [qr])),
            ],
            keepLineBreaks: true
        )
        try expect(document?.kind == .text, "A code on one page must not hide a multi-page document's text")
        try expect(document?.text == "Page one text\n\nScan for early access.", "Pages should be separated by a blank line")

        let blankDocument = TextCaptureComposer.compose(
            [.embedded("   "), .recognized(TextRecognitionResult(lines: [], codes: [qr]))],
            keepLineBreaks: true
        )
        try expect(blankDocument?.kind == .code, "A document with only a code should copy the code")

        let link = TextCaptureComposer.compose(
            [.recognized(TextRecognitionResult(lines: [line("figma.com/design/4hX2", top: 0.2)], codes: []))],
            keepLineBreaks: true
        )
        try expect(link?.kind == .link, "Recognized link text should be classified as a link")

        try expect(TextCaptureComposer.compose([], keepLineBreaks: true) == nil, "No pages should produce nothing")
        try expect(
            TextCaptureComposer.compose([.recognized(TextRecognitionResult(lines: [], codes: []))], keepLineBreaks: true) == nil,
            "An empty recognition result should produce nothing"
        )
    }

    /// Cells of a 3x3 table in Vision's column-by-column order, as VNRecognizeTextRequest returns them.
    private static func pricingTableLines(top: CGFloat = 0.30) -> [RecognizedTextLine] {
        let columns: [(x: CGFloat, width: CGFloat, cells: [String])] = [
            (0.05, 0.20, ["Plan", "Starter", "Team"]),
            (0.35, 0.12, ["Seats", "5", "25"]),
            (0.60, 0.18, ["Price", "$12.00", "$49.00"]),
        ]
        return columns.flatMap { column in
            column.cells.enumerated().map { row, text in
                line(text, x: column.x, top: top + CGFloat(row) * 0.08, width: column.width, height: 0.05)
            }
        }
    }

    private static func validateTextTableDetector() throws {
        let expected = [["Plan", "Seats", "Price"], ["Starter", "5", "$12.00"], ["Team", "25", "$49.00"]]
        let columnMajor = pricingTableLines()
        try expect(TextTableDetector.looksTabular(columnMajor), "A grid of cells should look tabular")
        try expect(TextTableDetector.detectTable(in: columnMajor)?.rows == expected, "Column-major cells should rebuild row by row")
        try expect(
            TextTableDetector.detectTable(in: columnMajor.reversed())?.rows == expected,
            "Table detection must not depend on Vision's line order"
        )

        let withTitleAndNote = [line("Pricing", top: 0.15, width: 0.3)] + pricingTableLines() + [line("Prices exclude tax.", top: 0.62, width: 0.5)]
        let table = TextTableDetector.detectTable(in: withTitleAndNote)
        try expect(table?.rows == expected, "Title and note rows should stay outside the table")
        try expect(table.map { $0.boundingBox.maxY < 1 - 0.15 - 0.05 } == true, "Table bounds should exclude the title")

        let missingCell = pricingTableLines().filter { $0.text != "25" }
        try expect(
            TextTableDetector.detectTable(in: missingCell)?.rows == [["Plan", "Seats", "Price"], ["Starter", "5", "$12.00"], ["Team", "", "$49.00"]],
            "An empty cell should stay in its column"
        )

        let paragraph = [line("First line of a paragraph", top: 0.1), line("second line", top: 0.15)]
        try expect(!TextTableDetector.looksTabular(paragraph), "A paragraph should not look tabular")
        try expect(TextTableDetector.detectTable(in: paragraph) == nil, "A paragraph is not a table")

        let twoColumnArticle = (0..<3).flatMap { row -> [RecognizedTextLine] in
            let top = 0.1 + CGFloat(row) * 0.06
            return [
                line("The quarterly results were stronger than expected", x: 0.05, top: top, width: 0.4),
                line("while support volume fell after the rewrite shipped", x: 0.55, top: top, width: 0.4),
            ]
        }
        try expect(TextTableDetector.detectTable(in: twoColumnArticle) == nil, "Two columns of prose are not a table")

        let glossary = (0..<3).flatMap { row -> [RecognizedTextLine] in
            let top = 0.1 + CGFloat(row) * 0.06
            return [
                line(["Churn", "ARR", "NPS"][row], x: 0.05, top: top, width: 0.12),
                line("A long definition that explains the term in a full sentence", x: 0.30, top: top, width: 0.65),
            ]
        }
        try expect(TextTableDetector.detectTable(in: glossary)?.rowCount == 3, "A term/definition table with long definitions is still a table")
        try expect(
            RecognizedTable(rows: [["Plan", "Seats"], ["Starter", "5"]], boundingBox: .zero).looksLikeColumnsOfProse == false,
            "Short cells are not prose"
        )
    }

    private static func validateTableComposition() throws {
        let lines = [line("Pricing", top: 0.15, width: 0.3)] + pricingTableLines() + [line("Prices exclude tax.", top: 0.62, width: 0.5)]
        guard let table = TextTableDetector.detectTable(in: lines) else {
            throw ValidationError("Fixture table was not detected")
        }
        let capture = TextCaptureComposer.compose(
            [.recognized(TextRecognitionResult(lines: lines, codes: [], tables: [table]))],
            keepLineBreaks: true
        )
        try expect(capture?.kind == .table, "A capture containing a table should be a table capture")
        try expect(
            capture?.text == "Pricing\n\nPlan\tSeats\tPrice\nStarter\t5\t$12.00\nTeam\t25\t$49.00\n\nPrices exclude tax.",
            "Table capture should keep surrounding text and tab-separate cells"
        )
        try expect(capture?.html?.contains("<td>$49.00</td>") == true, "Table capture should include an HTML table")
        try expect(capture?.tables.first?.rowCount == 3 && capture?.tables.first?.columnCount == 3, "Table size mismatch")
        try expect(capture?.webURL == nil, "A table is never opened as a link")

        let plain = TextCaptureComposer.compose([.recognized(TextRecognitionResult(lines: lines, codes: []))], keepLineBreaks: true)
        try expect(plain?.kind == .text && plain?.html == nil, "Without detected tables the capture stays plain text")

        let qr = RecognizedCode(payload: "https://example.com/menu", symbology: "QR")
        let codeWins = TextCaptureComposer.compose(
            [.recognized(TextRecognitionResult(lines: lines, codes: [qr], tables: [table]))],
            keepLineBreaks: true
        )
        try expect(codeWins?.kind == .code, "A code in a single image should still win over a table")

        let messy = RecognizedTable(rows: [["A\tB", "multi\nline  cell"], ["only one"]], boundingBox: .zero)
        try expect(messy.rows == [["A B", "multi line cell"], ["only one", ""]], "Cells should be single-line, tab-free, and rectangular")
        try expect(messy.tabSeparatedText == "A B\tmulti line cell\nonly one\t", "Tab-separated text mismatch")
    }

    private static func validateTextCaptureHTML() throws {
        let html = TextCaptureHTML.document(fromTabSeparatedText: "Title & <notes>\nsecond line\n\nName\tPrice\n\"Pro\"\t$5\nSolo\n")
        try expect(html.hasPrefix("<meta charset=\"utf-8\">"), "HTML should declare UTF-8")
        try expect(html.contains("<p>Title &amp; &lt;notes&gt;<br>second line</p>"), "Paragraph lines should be escaped and joined with <br>")
        try expect(
            html.contains("<tr><td>Name</td><td>Price</td></tr><tr><td>&quot;Pro&quot;</td><td>$5</td></tr></table>"),
            "Tab-separated rows should become an escaped table"
        )
        try expect(html.hasSuffix("<p>Solo</p>"), "A line without tabs after a table should start a paragraph")

        let ragged = TextCaptureHTML.document(fromTabSeparatedText: "a\tb\tc\nd\te")
        try expect(ragged.contains("<tr><td>d</td><td>e</td><td></td></tr>"), "Short rows should be padded to the widest row")
    }

    private static func validateTextCaptureHistory() throws {
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let text = TextCaptureRecord(text: "Hotel Sternenfeld", kind: .text, origin: .screen, sourceName: "Safari", capturedAt: base)
        let link = TextCaptureRecord(text: "https://nerdynikhil.com", kind: .link, origin: .screen, sourceName: "Zoom", capturedAt: base + 1)
        let code = TextCaptureRecord(text: "cafe.menu/t12", kind: .code, origin: .clipboard, sourceName: "Clipboard", capturedAt: base + 2)

        var records: [TextCaptureRecord] = []
        records = TextCaptureHistory.inserting(text, into: records)
        records = TextCaptureHistory.inserting(link, into: records)
        records = TextCaptureHistory.inserting(code, into: records)
        try expect(records.map(\.id) == [code.id, link.id, text.id], "History should be newest first")

        let recaptured = TextCaptureRecord(text: "Hotel Sternenfeld", kind: .text, origin: .file, sourceName: "scan.pdf", capturedAt: base + 3)
        records = TextCaptureHistory.inserting(recaptured, into: records)
        try expect(records.count == 3 && records.first?.id == recaptured.id, "Re-capturing the same text should move it to the top")

        let capped = TextCaptureHistory.inserting(
            TextCaptureRecord(text: "Newest", kind: .text, origin: .screen, sourceName: nil),
            into: records,
            limit: 2
        )
        try expect(capped.count == 2 && capped.first?.text == "Newest", "History should be capped to the limit")

        try expect(TextCaptureHistory.filtered(records, kind: .link, query: "").map(\.id) == [link.id], "Kind filter mismatch")
        try expect(TextCaptureHistory.filtered(records, kind: nil, query: "sternen").count == 1, "Search should be case-insensitive")
        try expect(TextCaptureHistory.filtered(records, kind: nil, query: "ZOOM").map(\.id) == [link.id], "Search should match the source app")
        try expect(TextCaptureHistory.filtered(records, kind: .code, query: "Sternenfeld").isEmpty, "Kind and query should both apply")

        let accented = [TextCaptureRecord(text: "Café Zürich", kind: .text, origin: .screen, sourceName: nil)]
        try expect(TextCaptureHistory.filtered(accented, kind: nil, query: "cafe zurich").count == 1, "Search should ignore diacritics")

        let counts = TextCaptureHistory.counts(in: records)
        try expect(counts[.text] == 1 && counts[.link] == 1 && counts[.code] == 1, "Kind counts mismatch")
    }

    private static func validateTextCaptureHistoryStore() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TextCaptureHistoryStore-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("History.json")

        let store = FileTextCaptureHistoryStore(fileURL: fileURL, limit: 3)
        try expect(store.load().isEmpty, "Missing history file should load as empty")

        let first = TextCaptureRecord(text: "first", kind: .text, origin: .screen, sourceName: "Notes")
        let second = TextCaptureRecord(text: "https://example.com", kind: .link, origin: .file, sourceName: "scan.png")
        try store.append(first)
        try store.append(second)
        try expect(store.load() == [second, first], "Appended history should round-trip newest first")
        try store.append(TextCaptureRecord(text: "a\tb\nc\td", kind: .table, origin: .screen, sourceName: "Numbers"))
        try expect(store.load().first?.kind == .table, "Table captures should round-trip through history")

        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        try expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600, "History file should be owner-only")

        for index in 0..<5 {
            try store.append(TextCaptureRecord(text: "extra \(index)", kind: .text, origin: .screen, sourceName: nil))
        }
        try expect(store.load().count == 3, "Store should enforce its history limit")

        let reopened = FileTextCaptureHistoryStore(fileURL: fileURL, limit: 3)
        let kept = reopened.load()
        try expect(kept.first?.text == "extra 4", "A new store instance should read the saved history")
        try reopened.remove(id: kept[1].id)
        try expect(reopened.load().map(\.text) == ["extra 4", "extra 2"], "Remove should delete one record")

        // A record written by a newer build must not wipe the rest of the file.
        var entries = try JSONSerialization.jsonObject(with: Data(contentsOf: fileURL)) as? [[String: Any]] ?? []
        var future = entries[0]
        future["kind"] = "hologram"
        future["id"] = UUID().uuidString
        entries.insert(future, at: 0)
        try JSONSerialization.data(withJSONObject: entries).write(to: fileURL)
        try expect(reopened.load().map(\.text) == ["extra 4", "extra 2"], "Unknown history entries should be skipped, not fatal")

        try Data("not json".utf8).write(to: fileURL)
        try expect(reopened.load().isEmpty, "A corrupt history file should load as empty")

        try reopened.removeAll()
        try expect(!FileManager.default.fileExists(atPath: fileURL.path), "Clearing history should delete the file")
        try reopened.removeAll()
    }

    private static func validateAppURLCommands() throws {
        for command in AppURLCommand.allCommands {
            try expect(AppURLCommand(url: command.url) == command, "URL round trip failed for \(command.name)")
        }
        try expect(
            Set(AppURLCommand.allCommands.map(\.name)).count == AppURLCommand.allCommands.count,
            "URL command names must be unique"
        )

        try expect(ShortcutAction.demoMirrorRegion.urlName == "demo-mirror-region", "Kebab-case URL name mismatch")
        try expect(ShortcutAction.ocrSnip.urlName == "ocr-snip", "OCR Snip URL name mismatch")
        try expect(AppURLCommand.action(.breakTimer).url.absoluteString == "zoomit://break-timer", "Canonical URL mismatch")

        func command(_ string: String) -> AppURLCommand? {
            URL(string: string).flatMap(AppURLCommand.init(url:))
        }
        try expect(command("zoomit://ocr-snip") == .action(.ocrSnip), "ocr-snip should map to OCR Snip")
        try expect(command("ZoomIt://OCR_Snip/") == .action(.ocrSnip), "Scheme and name matching should ignore case and separators")
        try expect(command("zoomit:ocr-clipboard") == .textFromClipboard, "Opaque zoomit: URLs should be accepted")
        try expect(command("zoomit:///ocr-history") == .textCaptureHistory, "Path-only zoomit URLs should be accepted")
        try expect(command("zoomit://ocr-file") == .textFromFile, "ocr-file should open the file picker")
        try expect(command("zoomit://settings") == .preferences, "settings should alias preferences")
        try expect(command("zoomit://preferences") == .preferences, "preferences command mismatch")
        try expect(command("zoomit://format-disk") == nil, "Unknown commands should be rejected")
        try expect(command("zoomit://") == nil, "An empty command should be rejected")
        try expect(command("https://ocr-snip") == nil, "Other schemes should be rejected")
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
