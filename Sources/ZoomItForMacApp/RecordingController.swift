@preconcurrency import AVFoundation
import AppCore
import AppKit
import ApplicationServices
import ImageIO
import PlatformServices
import UniformTypeIdentifiers

private enum RecordingFormat: Sendable {
    case gif
    case mp4

    var title: String {
        switch self {
        case .gif: return "GIF"
        case .mp4: return "MP4"
        }
    }

    var fileExtension: String {
        switch self {
        case .gif: return "gif"
        case .mp4: return "mp4"
        }
    }

    var contentType: UTType {
        switch self {
        case .gif: return .gif
        case .mp4: return .mpeg4Movie
        }
    }
}

private struct RecordingSaveSelection: Sendable {
    let url: URL
    let format: RecordingFormat
}

private struct RecordingExportRequest: @unchecked Sendable {
    let frames: [CGImage]
    let selection: RecordingSaveSelection
    let frameRange: RecordingFrameRange
    let framesPerSecond: Double
    let scale: Double
}

private struct PendingRecording: @unchecked Sendable {
    let frames: [CGImage]
    let mode: RecordingMode
    let settings: AppSettings
}

@MainActor
private final class RecordingFormatAccessory: NSObject {
    private weak var panel: NSSavePanel?
    private let popup = NSPopUpButton()
    private let formats: [RecordingFormat] = [.mp4, .gif]
    let view: NSView

    init(panel: NSSavePanel, initialFormat: RecordingFormat) {
        self.panel = panel

        let label = NSTextField(labelWithString: "Format:")
        label.translatesAutoresizingMaskIntoConstraints = false

        popup.translatesAutoresizingMaskIntoConstraints = false
        popup.addItems(withTitles: formats.map(\.title))
        if let initialIndex = formats.firstIndex(of: initialFormat) {
            popup.selectItem(at: initialIndex)
        }

        let stack = NSStackView(views: [label, popup])
        stack.orientation = .horizontal
        stack.alignment = .firstBaseline
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 16, bottom: 12, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        self.view = stack

        super.init()

        popup.target = self
        popup.action = #selector(formatChanged)
    }

    var selectedFormat: RecordingFormat {
        formats[popup.indexOfSelectedItem]
    }

    @objc private func formatChanged() {
        guard let panel else { return }
        let format = selectedFormat
        panel.allowedContentTypes = [format.contentType]
        let currentName = (panel.nameFieldStringValue as NSString).deletingPathExtension
        panel.nameFieldStringValue = "\(currentName).\(format.fileExtension)"
    }
}

@MainActor
struct RecordingToggleResult {
    let title: String
    let message: String
}

enum RecordingControllerError: LocalizedError {
    case captureUnavailable
    case noFramesCaptured
    case exportFailed
    case invalidFrameSelection
    case invalidDestination(String)
    case selectionCancelled
    case hoveredWindowUnavailable
    case finalizationInProgress

    var errorDescription: String? {
        switch self {
        case .captureUnavailable:
            return "The selected display could not be captured."
        case .noFramesCaptured:
            return "No frames were captured before recording stopped."
        case .exportFailed:
            return "Recording export could not be finalized."
        case .invalidFrameSelection:
            return "The trim selection is empty or outside the captured recording."
        case let .invalidDestination(path):
            return "The recording could not be saved to \(path)."
        case .selectionCancelled:
            return "Recording region selection was cancelled."
        case .hoveredWindowUnavailable:
            return "The hovered window could not be determined. Grant Accessibility permission and try again."
        case .finalizationInProgress:
            return "The previous recording is still being saved."
        }
    }
}

private enum RecordingMode: Sendable {
    case fullDisplay
    case selectedRegion(CGRect)
    case hoveredWindow(CGRect)

    var label: String {
        switch self {
        case .fullDisplay:
            return "full screen"
        case .selectedRegion:
            return "cropped region"
        case .hoveredWindow:
            return "hovered window"
        }
    }

    var region: CGRect? {
        switch self {
        case .fullDisplay:
            return nil
        case let .selectedRegion(rect), let .hoveredWindow(rect):
            return rect
        }
    }
}

@MainActor
final class RecordingController {
    private let screenCaptureService: ScreenCaptureService
    private let clipboardService: ClipboardService
    private let settingsStore: AppSettingsStore

    private var timer: Timer?
    private var capturedFrames: [CGImage] = []
    private var targetScreenPoint: CGPoint?
    private var targetScreenFrame: CGRect?
    private var targetCaptureRegion: CGRect?
    private var recordingMode: RecordingMode = .fullDisplay
    private var recordingStartedAt: Date?
    private var recordingHighlightWindow: NSWindow?
    private var trimController: RecordingTrimWindowController?
    private var destinationPanel: NSSavePanel?
    private var destinationAccessory: RecordingFormatAccessory?
    private var progressController: RecordingSaveProgressWindowController?
    private var isFinalizingRecording = false

    var onResult: ((Result<RecordingToggleResult, Error>) -> Void)?

    init(
        screenCaptureService: ScreenCaptureService,
        clipboardService: ClipboardService,
        settingsStore: AppSettingsStore
    ) {
        self.screenCaptureService = screenCaptureService
        self.clipboardService = clipboardService
        self.settingsStore = settingsStore
    }

    var isRecording: Bool {
        timer != nil
    }

    func toggle() throws {
        if isRecording {
            try stop()
            return
        }

        try ensureReadyToRecord()
        try start(mode: .fullDisplay)
    }

    func toggleCropped() throws {
        if isRecording {
            try stop()
            return
        }

        try ensureReadyToRecord()
        let region = try selectRecordingRegion()
        let mode = RecordingMode.selectedRegion(region)
        try start(mode: mode)
    }

    func toggleHoveredWindow() throws {
        if isRecording {
            try stop()
            return
        }

        try ensureReadyToRecord()
        let frame = try hoveredWindowFrame()
        let mode = RecordingMode.hoveredWindow(frame)
        try start(mode: mode)
    }

    func cancel() {
        timer?.invalidate()
        timer = nil
        resetRecordingState()
    }

    private func ensureReadyToRecord() throws {
        if isFinalizingRecording {
            throw RecordingControllerError.finalizationInProgress
        }
    }

    private func start(mode: RecordingMode) throws {
        let targetPoint = NSEvent.mouseLocation
        let capturePoint = mode.region?.center ?? targetPoint
        guard let snapshot = screenCaptureService.captureScreen(containing: capturePoint) else {
            throw RecordingControllerError.captureUnavailable
        }

        capturedFrames.removeAll()
        targetScreenPoint = targetPoint
        targetScreenFrame = snapshot.screenFrame
        targetCaptureRegion = mode.region
        recordingMode = mode
        let recordingBorderRegion = mode.region ?? snapshot.screenFrame
        try runCountdown(on: snapshot.screenFrame, highlighting: recordingBorderRegion)
        showRecordingHighlightIfNeeded(on: snapshot.screenFrame, highlightedRegion: recordingBorderRegion)
        capturedFrames.removeAll()
        recordingStartedAt = Date()
        captureFrame()

        let interval = 1.0 / settingsStore.load().validatedRecordingFramesPerSecond
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.captureFrame()
            }
        }
    }

    private func stop() throws {
        timer?.invalidate()
        timer = nil

        guard !capturedFrames.isEmpty else {
            throw RecordingControllerError.noFramesCaptured
        }

        hideRecordingHighlight()
        let pendingRecording = PendingRecording(
            frames: capturedFrames,
            mode: recordingMode,
            settings: settingsStore.load()
        )
        resetRecordingState()
        isFinalizingRecording = true

        guard let trimController = RecordingTrimWindowController(
            capturedFrames: pendingRecording.frames,
            settings: pendingRecording.settings,
            modeLabel: pendingRecording.mode.label
        ) else {
            isFinalizingRecording = false
            throw RecordingControllerError.invalidFrameSelection
        }

        self.trimController = trimController
        trimController.present { [weak self] result in
            guard let self else { return }
            self.trimController = nil
            self.handleTrimResult(result, pendingRecording: pendingRecording)
        }
    }

    private func validatedExportFrameRange(
        _ selectedRange: RecordingFrameRange,
        frameCount: Int
    ) -> RecordingFrameRange? {
        RecordingFrameRange(
            startIndex: selectedRange.startIndex,
            endIndexExclusive: selectedRange.endIndexExclusive,
            frameCount: frameCount
        )
    }

    private func handleTrimResult(
        _ result: RecordingTrimResult,
        pendingRecording: PendingRecording
    ) {
        guard case let .save(selectedRange) = result else {
            isFinalizingRecording = false
            return
        }
        guard let frameRange = validatedExportFrameRange(
            selectedRange,
            frameCount: pendingRecording.frames.count
        ) else {
            finishFinalization(with: .failure(RecordingControllerError.invalidFrameSelection))
            return
        }

        do {
            try promptForDestination { [weak self] selection in
                guard let self else { return }
                guard let selection else {
                    self.isFinalizingRecording = false
                    return
                }
                self.export(
                    pendingRecording: pendingRecording,
                    frameRange: frameRange,
                    selection: selection
                )
            }
        } catch {
            finishFinalization(with: .failure(error))
        }
    }

    private func export(
        pendingRecording: PendingRecording,
        frameRange: RecordingFrameRange,
        selection: RecordingSaveSelection
    ) {
        let request = RecordingExportRequest(
            frames: pendingRecording.frames,
            selection: selection,
            frameRange: frameRange,
            framesPerSecond: pendingRecording.settings.validatedRecordingFramesPerSecond,
            scale: pendingRecording.settings.validatedRecordingScale
        )

        let progressController = RecordingSaveProgressWindowController(
            formatTitle: selection.format.title,
            frameCount: frameRange.count
        )
        self.progressController = progressController
        progressController.show()

        let exportTask = Task.detached(priority: .userInitiated) {
            try Self.export(request: request) { completedFrames, totalFrames in
                Task { @MainActor [weak self] in
                    self?.progressController?.update(
                        completedFrames: completedFrames,
                        totalFrames: totalFrames
                    )
                }
            }
        }

        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let savedURL = try await exportTask.value
                self.progressController?.finish()
                self.progressController = nil
                self.clipboardService.copy(text: savedURL.path)

                let duration = frameRange.duration(
                    atFramesPerSecond: pendingRecording.settings.validatedRecordingFramesPerSecond
                )
                let fileSize = (try? savedURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                let formatter = ByteCountFormatter()
                formatter.countStyle = .file

                self.finishFinalization(with: .success(RecordingToggleResult(
                    title: "Recording saved",
                    message: "Saved \(pendingRecording.mode.label) \(selection.format.title) recording (\(frameRange.count) frames, \(String(format: "%.1f", duration))s, \(formatter.string(fromByteCount: Int64(fileSize)))) to \(savedURL.path). The file path was copied to the clipboard."
                )))
            } catch {
                self.progressController?.finish()
                self.progressController = nil
                self.finishFinalization(with: .failure(error))
            }
        }
    }

    private func finishFinalization(with result: Result<RecordingToggleResult, Error>) {
        isFinalizingRecording = false
        onResult?(result)
    }

    nonisolated private static func export(
        request: RecordingExportRequest,
        progress: @escaping @Sendable (Int, Int) -> Void
    ) throws -> URL {
        if FileManager.default.fileExists(atPath: request.selection.url.path) {
            try FileManager.default.removeItem(at: request.selection.url)
        }

        switch request.selection.format {
        case .gif:
            guard let url = writeGIF(request: request, progress: progress) else {
                throw RecordingControllerError.exportFailed
            }
            return url
        case .mp4:
            guard let url = try writeMP4(request: request, progress: progress) else {
                throw RecordingControllerError.exportFailed
            }
            return url
        }
    }

    private func captureFrame() {
        let point = targetCaptureRegion?.center ?? targetScreenPoint ?? NSEvent.mouseLocation
        guard let snapshot = captureRecordingSnapshot(containing: point) else {
            return
        }

        let targetFrame = targetScreenFrame ?? snapshot.screenFrame
        guard snapshot.screenFrame.equalTo(targetFrame) else {
            return
        }

        let compositedImage = imageWithCursor(from: snapshot, mouseLocation: NSEvent.mouseLocation)
        let frame: CGImage
        if let targetCaptureRegion {
            guard
                let cropRect = CaptureGeometry.cropRect(
                    for: targetCaptureRegion,
                    within: snapshot.screenFrame,
                    scaleFactor: snapshot.scaleFactor
                ),
                let croppedFrame = compositedImage.cropping(to: cropRect)
            else {
                return
            }
            frame = croppedFrame
        } else {
            frame = compositedImage
        }

        capturedFrames.append(frame)
    }

    private func captureRecordingSnapshot(containing point: CGPoint) -> ScreenSnapshot? {
        guard let recordingHighlightWindow else {
            return screenCaptureService.captureScreen(containing: point)
        }

        guard
            let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }),
            let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
        else {
            return screenCaptureService.captureScreen(containing: point)
        }

        let image = CGWindowListCreateImage(
            CGDisplayBounds(displayID),
            .optionOnScreenBelowWindow,
            CGWindowID(recordingHighlightWindow.windowNumber),
            .bestResolution
        ) ?? CGDisplayCreateImage(displayID)

        guard let image else {
            return screenCaptureService.captureScreen(containing: point)
        }

        return ScreenSnapshot(
            displayID: displayID,
            image: image,
            screenFrame: screen.frame,
            scaleFactor: screen.backingScaleFactor
        )
    }

    private func imageWithCursor(from snapshot: ScreenSnapshot, mouseLocation: CGPoint) -> CGImage {
        let cursor = NSCursor.current
        let cursorSize = cursor.image.size
        guard
            let cursorRect = CaptureGeometry.cursorRect(
                at: mouseLocation,
                cursorSize: cursorSize,
                cursorHotSpot: cursor.hotSpot,
                within: snapshot.screenFrame,
                scaleFactor: snapshot.scaleFactor
            ),
            let cursorImage = cursorCGImage(cursor)
        else {
            return snapshot.image
        }

        guard
            let colorSpace = snapshot.image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB),
            let context = CGContext(
                data: nil,
                width: snapshot.image.width,
                height: snapshot.image.height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
            )
        else {
            return snapshot.image
        }

        let imageBounds = CGRect(x: 0, y: 0, width: snapshot.image.width, height: snapshot.image.height)
        context.draw(snapshot.image, in: imageBounds)
        context.draw(cursorImage, in: CGRect(
            x: cursorRect.minX,
            y: CGFloat(snapshot.image.height) - cursorRect.maxY,
            width: cursorRect.width,
            height: cursorRect.height
        ))
        return context.makeImage() ?? snapshot.image
    }

    private func cursorCGImage(_ cursor: NSCursor) -> CGImage? {
        var proposedRect = CGRect(origin: .zero, size: cursor.image.size)
        return cursor.image.cgImage(forProposedRect: &proposedRect, context: nil, hints: nil)
    }

    private func selectRecordingRegion() throws -> CGRect {
        let mouseLocation = NSEvent.mouseLocation
        guard
            let snapshot = screenCaptureService.captureScreen(containing: mouseLocation),
            let screen = NSScreen.screens.first(where: { $0.frame == snapshot.screenFrame })
        else {
            throw RecordingControllerError.captureUnavailable
        }

        let selector = RecordingRegionSelector(snapshot: snapshot, screen: screen)
        guard let selection = selector.run() else {
            throw RecordingControllerError.selectionCancelled
        }

        return selection
    }

    private func hoveredWindowFrame() throws -> CGRect {
        let mouseLocation = NSEvent.mouseLocation
        guard let accessibilityPoint = accessibilityPoint(for: mouseLocation) else {
            throw RecordingControllerError.hoveredWindowUnavailable
        }

        let systemWide = AXUIElementCreateSystemWide()
        var elementReference: AXUIElement?
        let hitTestResult = AXUIElementCopyElementAtPosition(
            systemWide,
            Float(accessibilityPoint.x),
            Float(accessibilityPoint.y),
            &elementReference
        )

        if hitTestResult == .success,
           let elementReference,
           let window = windowElement(containing: elementReference),
           let frame = recordableFrame(of: window, preferredPoint: mouseLocation) {
            return frame
        }

        if let frontmostApplication = NSWorkspace.shared.frontmostApplication {
            let applicationElement = AXUIElementCreateApplication(frontmostApplication.processIdentifier)
            let focusedWindow: AXUIElement? = attributeValue(kAXFocusedWindowAttribute as CFString, of: applicationElement)
            if let focusedWindow,
               let frame = recordableFrame(of: focusedWindow, preferredPoint: mouseLocation) {
                return frame
            }
        }

        throw RecordingControllerError.hoveredWindowUnavailable
    }

    private func windowElement(containing element: AXUIElement) -> AXUIElement? {
        var currentElement: AXUIElement? = element
        while let unwrappedElement = currentElement {
            if role(of: unwrappedElement) == kAXWindowRole as String {
                return unwrappedElement
            }

            currentElement = attributeValue(kAXParentAttribute as CFString, of: unwrappedElement)
        }

        return nil
    }

    private func role(of element: AXUIElement) -> String? {
        let role: String? = attributeValue(kAXRoleAttribute as CFString, of: element)
        return role
    }

    private func attributeValue<T>(_ attribute: CFString, of element: AXUIElement) -> T? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute, &value)
        guard result == .success, let typedValue = value as? T else {
            return nil
        }
        return typedValue
    }

    private func recordableFrame(of element: AXUIElement, preferredPoint: CGPoint) -> CGRect? {
        guard
            let displayFrame = displayFrame(of: element),
            let screenFrame = CaptureGeometry.screenRect(
                forDisplayRect: displayFrame,
                displayOriginReferenceHeight: displayOriginReferenceHeight()
            )
        else {
            return nil
        }

        return clampedFrameToScreen(screenFrame, preferredPoint: preferredPoint)
    }

    private func displayFrame(of element: AXUIElement) -> CGRect? {
        guard
            let positionValue: AXValue = attributeValue(kAXPositionAttribute as CFString, of: element),
            let sizeValue: AXValue = attributeValue(kAXSizeAttribute as CFString, of: element)
        else {
            return nil
        }

        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue, .cgPoint, &position), AXValueGetValue(sizeValue, .cgSize, &size) else {
            return nil
        }

        return CGRect(origin: position, size: size)
    }

    private func accessibilityPoint(for screenPoint: CGPoint) -> CGPoint? {
        CaptureGeometry.displayPoint(
            forScreenPoint: screenPoint,
            displayOriginReferenceHeight: displayOriginReferenceHeight()
        )
    }

    private func displayOriginReferenceHeight() -> CGFloat {
        let mainDisplayID = CGMainDisplayID()
        if let mainDisplayScreen = NSScreen.screens.first(where: { screen in
            (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == mainDisplayID
        }) {
            return mainDisplayScreen.frame.maxY
        }

        return NSScreen.screens.first?.frame.maxY ?? 0
    }

    private func clampedFrameToScreen(_ frame: CGRect, preferredPoint: CGPoint) -> CGRect? {
        if let preferredScreen = NSScreen.screens.first(where: { $0.frame.contains(preferredPoint) }),
           let clampedFrame = validIntersection(frame, with: preferredScreen.frame) {
            return clampedFrame
        }

        return NSScreen.screens
            .compactMap { validIntersection(frame, with: $0.frame) }
            .max { lhs, rhs in
                (lhs.width * lhs.height) < (rhs.width * rhs.height)
            }
    }

    private func validIntersection(_ frame: CGRect, with screenFrame: CGRect) -> CGRect? {
        let intersection = frame.standardized.intersection(screenFrame.standardized).integral
        guard !intersection.isNull, intersection.width >= 1, intersection.height >= 1 else {
            return nil
        }

        return intersection
    }

    nonisolated private static func writeGIF(
        request: RecordingExportRequest,
        progress: @escaping @Sendable (Int, Int) -> Void
    ) -> URL? {
        guard request.frameRange.endIndexExclusive <= request.frames.count else {
            return nil
        }

        guard let destination = CGImageDestinationCreateWithURL(
            request.selection.url as CFURL,
            UTType.gif.identifier as CFString,
            request.frameRange.count,
            nil
        ) else {
            return nil
        }

        let frameDelay = 1.0 / request.framesPerSecond
        let frameProperties = [
            kCGImagePropertyGIFDictionary: [
                kCGImagePropertyGIFDelayTime: frameDelay
            ]
        ] as CFDictionary
        let gifProperties = [
            kCGImagePropertyGIFDictionary: [
                kCGImagePropertyGIFLoopCount: 0
            ]
        ] as CFDictionary

        CGImageDestinationSetProperties(destination, gifProperties)
        for (offset, frame) in request.frames[request.frameRange.indices].enumerated() {
            CGImageDestinationAddImage(
                destination,
                scaled(frame: frame, scale: request.scale),
                frameProperties
            )
            progress(offset + 1, request.frameRange.count)
        }

        guard CGImageDestinationFinalize(destination) else {
            return nil
        }

        return request.selection.url
    }

    nonisolated private static func writeMP4(
        request: RecordingExportRequest,
        progress: @escaping @Sendable (Int, Int) -> Void
    ) throws -> URL? {
        guard request.frameRange.endIndexExclusive <= request.frames.count else {
            return nil
        }

        let firstFrame = request.frames[request.frameRange.startIndex]
        guard !request.frameRange.indices.isEmpty else {
            return nil
        }

        let scaledFirstFrame = scaled(frame: firstFrame, scale: request.scale)
        let width = scaledFirstFrame.width
        let height = scaledFirstFrame.height
        let fps = request.framesPerSecond

        let writer = try AVAssetWriter(outputURL: request.selection.url, fileType: .mp4)
        let outputSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
        ]

        let input = AVAssetWriterInput(mediaType: .video, outputSettings: outputSettings)
        input.expectsMediaDataInRealTime = false

        let sourceAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32ARGB),
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
        ]

        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: sourceAttributes
        )

        guard writer.canAdd(input) else {
            return nil
        }

        writer.add(input)
        guard writer.startWriting() else {
            throw writer.error ?? RecordingControllerError.exportFailed
        }
        writer.startSession(atSourceTime: .zero)

        let frameDuration = CMTime(seconds: 1.0 / fps, preferredTimescale: 600)
        var presentationTime = CMTime.zero

        for (offset, frame) in request.frames[request.frameRange.indices].enumerated() {
            let scaledFrame = scaled(frame: frame, scale: request.scale)
            guard let pixelBuffer = makePixelBuffer(from: scaledFrame, canvasSize: CGSize(width: width, height: height)) else {
                throw RecordingControllerError.exportFailed
            }

            while !input.isReadyForMoreMediaData {
                guard writer.status == .writing else {
                    throw writer.error ?? RecordingControllerError.exportFailed
                }
                Thread.sleep(forTimeInterval: 0.01)
            }

            guard adaptor.append(pixelBuffer, withPresentationTime: presentationTime) else {
                throw writer.error ?? RecordingControllerError.exportFailed
            }
            presentationTime = CMTimeAdd(presentationTime, frameDuration)
            progress(offset + 1, request.frameRange.count)
        }

        input.markAsFinished()
        try awaitFinish(writer)
        return request.selection.url
    }

    nonisolated private static func awaitFinish(_ writer: AVAssetWriter) throws {
        let semaphore = DispatchSemaphore(value: 0)

        writer.finishWriting {
            semaphore.signal()
        }

        semaphore.wait()

        guard writer.status == .completed else {
            throw writer.error ?? RecordingControllerError.exportFailed
        }
    }

    nonisolated private static func scaled(frame: CGImage, scale: Double) -> CGImage {
        guard scale > 0, scale != 1 else {
            return frame
        }

        let width = max(1, Int(Double(frame.width) * scale))
        let height = max(1, Int(Double(frame.height) * scale))

        guard
            let colorSpace = frame.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB),
            let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
            )
        else {
            return frame
        }

        context.interpolationQuality = .high
        context.draw(frame, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage() ?? frame
    }

    nonisolated private static func makePixelBuffer(from image: CGImage, canvasSize: CGSize) -> CVPixelBuffer? {
        var pixelBuffer: CVPixelBuffer?
        let attributes: [String: Any] = [
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
            kCVPixelBufferWidthKey as String: Int(canvasSize.width),
            kCVPixelBufferHeightKey as String: Int(canvasSize.height),
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32ARGB),
        ]

        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            Int(canvasSize.width),
            Int(canvasSize.height),
            kCVPixelFormatType_32ARGB,
            attributes as CFDictionary,
            &pixelBuffer
        )

        guard status == kCVReturnSuccess, let pixelBuffer else {
            return nil
        }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

        guard
            let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer),
            let colorSpace = image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB),
            let context = CGContext(
                data: baseAddress,
                width: Int(canvasSize.width),
                height: Int(canvasSize.height),
                bitsPerComponent: 8,
                bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
            )
        else {
            return nil
        }

        context.clear(CGRect(origin: .zero, size: canvasSize))
        context.draw(image, in: CGRect(origin: .zero, size: canvasSize))
        return pixelBuffer
    }

    private func makeSuggestedDestinationURL() throws -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let fileName = "ZoomItRecording-\(formatter.string(from: Date())).mp4"
        let directory = URL(fileURLWithPath: settingsStore.load().recordingSaveLocation, isDirectory: true)

        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw RecordingControllerError.invalidDestination(directory.path)
        }

        return directory.appendingPathComponent(fileName)
    }

    private func promptForDestination(
        completion: @escaping (RecordingSaveSelection?) -> Void
    ) throws {
        let suggestedURL = try makeSuggestedDestinationURL()
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = suggestedURL.lastPathComponent
        panel.directoryURL = suggestedURL.deletingLastPathComponent()
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.isExtensionHidden = false
        panel.title = "Save Recording"
        panel.message = "Choose a file format and where to save the recording."

        let accessory = RecordingFormatAccessory(panel: panel, initialFormat: .mp4)
        panel.accessoryView = accessory.view
        destinationPanel = panel
        destinationAccessory = accessory

        NSApp.activate(ignoringOtherApps: true)
        panel.begin { [weak self, weak panel] response in
            Task { @MainActor in
                guard let self else { return }
                defer {
                    self.destinationPanel = nil
                    self.destinationAccessory = nil
                }
                guard
                    response == .OK,
                    let panel,
                    let url = panel.url,
                    let accessory = self.destinationAccessory
                else {
                    completion(nil)
                    return
                }
                completion(RecordingSaveSelection(url: url, format: accessory.selectedFormat))
            }
        }
    }

    private func runCountdown(on screenFrame: CGRect, highlighting highlightedRegion: CGRect?) throws {
        guard let screen = NSScreen.screens.first(where: { $0.frame == screenFrame }) ?? NSScreen.main ?? NSScreen.screens.first else {
            throw RecordingControllerError.captureUnavailable
        }

        let highlightWindow = makeHighlightWindow(
            on: screen,
            screenFrame: screenFrame,
            highlightedRegion: highlightedRegion,
            dimBackground: true
        )
        highlightWindow?.orderFrontRegardless()

        let countdownCenter = highlightedRegion?.center ?? screenFrame.center
        let frame = CGRect(
            x: countdownCenter.x - 90,
            y: countdownCenter.y - 70,
            width: 180,
            height: 140
        )
        let window = OverlayWindow(
            contentRect: frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false,
            screen: screen
        )
        window.level = .statusBar
        window.isOpaque = false
        window.backgroundColor = .clear
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.ignoresMouseEvents = true

        let panel = NSVisualEffectView(frame: CGRect(origin: .zero, size: frame.size))
        panel.material = .hudWindow
        panel.state = .active
        panel.wantsLayer = true
        panel.layer?.cornerRadius = 24
        panel.layer?.masksToBounds = true

        let label = NSTextField(labelWithString: "")
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .monospacedDigitSystemFont(ofSize: 72, weight: .bold)
        label.textColor = .white
        label.alignment = .center

        panel.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 16),
            label.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -16),
            label.centerYAnchor.constraint(equalTo: panel.centerYAnchor),
        ])

        window.contentView = panel
        window.setFrame(frame, display: true)
        window.orderFrontRegardless()

        for remaining in stride(from: 3, through: 1, by: -1) {
            label.stringValue = "\(remaining)"
            playCountdownBeep()
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 1.0))
        }

        window.orderOut(nil)
        highlightWindow?.orderOut(nil)
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.08))
    }

    private func makeHighlightWindow(
        on screen: NSScreen,
        screenFrame: CGRect,
        highlightedRegion: CGRect?,
        dimBackground: Bool
    ) -> NSWindow? {
        guard let highlightedRegion else {
            return nil
        }

        let lineWidth: CGFloat = 3
        let windowFrame = screenFrame

        let window = OverlayPanel(
            contentRect: windowFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false,
            screen: screen
        )
        window.level = .statusBar
        window.backgroundColor = .clear
        window.isOpaque = false
        window.ignoresMouseEvents = true
        window.hasShadow = false
        window.hidesOnDeactivate = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        let localHighlightedRegion = CGRect(
            x: highlightedRegion.minX - screenFrame.minX,
            y: highlightedRegion.minY - screenFrame.minY,
            width: highlightedRegion.width,
            height: highlightedRegion.height
        ).integral

        let highlightView = RecordingRegionHighlightView(
            frame: CGRect(origin: .zero, size: windowFrame.size),
            highlightedRegion: localHighlightedRegion,
            lineWidth: lineWidth,
            dimBackground: dimBackground
        )
        highlightView.autoresizingMask = [.width, .height]
        window.contentView = highlightView
        window.setFrame(windowFrame, display: true)
        return window
    }

    private func showRecordingHighlightIfNeeded(on screenFrame: CGRect, highlightedRegion: CGRect?) {
        recordingHighlightWindow?.orderOut(nil)
        recordingHighlightWindow = nil

        guard
            let highlightedRegion,
            let screen = NSScreen.screens.first(where: { $0.frame == screenFrame }) ?? NSScreen.main ?? NSScreen.screens.first
        else {
            return
        }

        let window = makeHighlightWindow(
            on: screen,
            screenFrame: screenFrame,
            highlightedRegion: highlightedRegion,
            dimBackground: false
        )
        window?.orderFrontRegardless()
        window?.contentView?.displayIfNeeded()
        recordingHighlightWindow = window
    }

    private func resetRecordingState() {
        hideRecordingHighlight()
        capturedFrames.removeAll()
        targetScreenPoint = nil
        targetScreenFrame = nil
        targetCaptureRegion = nil
        recordingMode = .fullDisplay
        recordingStartedAt = nil
    }

    private func hideRecordingHighlight() {
        recordingHighlightWindow?.orderOut(nil)
        recordingHighlightWindow = nil
    }

    private func playCountdownBeep() {
        let names = ["Tink", "Pop", "Ping"]
        for name in names {
            if let sound = NSSound(named: NSSound.Name(name)) {
                sound.volume = 0.25
                sound.play()
                return
            }
        }
        NSSound.beep()
    }
}

private extension CGRect {
    var center: CGPoint {
        CGPoint(x: midX, y: midY)
    }
}

@MainActor
private final class RecordingRegionHighlightView: NSView {
    private let highlightedRegion: CGRect
    private let strokeLineWidth: CGFloat
    private let dimBackground: Bool

    init(frame frameRect: NSRect, highlightedRegion: CGRect, lineWidth: CGFloat, dimBackground: Bool) {
        self.highlightedRegion = highlightedRegion
        self.strokeLineWidth = lineWidth
        self.dimBackground = dimBackground
        super.init(frame: frameRect)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        if dimBackground {
            NSColor.black.withAlphaComponent(0.14).setFill()
            bounds.fill()

            NSColor.clear.setFill()
            highlightedRegion.fill(using: .clear)
        }

        let visibleHighlightedRegion = highlightedRegion.intersection(bounds).insetBy(dx: strokeLineWidth / 2, dy: strokeLineWidth / 2)
        guard !visibleHighlightedRegion.isNull, visibleHighlightedRegion.width > 0, visibleHighlightedRegion.height > 0 else {
            return
        }

        let strokePath = NSBezierPath(rect: visibleHighlightedRegion)
        NSColor.systemRed.setStroke()
        strokePath.lineWidth = strokeLineWidth
        strokePath.stroke()
    }
}

@MainActor
private final class RecordingRegionSelector {
    private let snapshot: ScreenSnapshot
    private let screen: NSScreen
    private var window: NSWindow?
    private var overlayView: RecordingSelectionView?
    private var selectedRect: CGRect?

    init(snapshot: ScreenSnapshot, screen: NSScreen) {
        self.snapshot = snapshot
        self.screen = screen
    }

    func run() -> CGRect? {
        let window = OverlayPanel(
            contentRect: screen.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false,
            screen: screen
        )
        window.level = .screenSaver
        window.backgroundColor = .clear
        window.isOpaque = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        let overlayView = RecordingSelectionView(frame: CGRect(origin: .zero, size: screen.frame.size), snapshot: snapshot)
        overlayView.autoresizingMask = [.width, .height]
        overlayView.selectionHandler = { [weak self] rect in
            self?.selectedRect = rect
            NSApp.stopModal()
        }
        overlayView.cancelHandler = {
            NSApp.stopModal()
        }

        window.contentView = overlayView
        self.window = window
        self.overlayView = overlayView

        NSApp.activate(ignoringOtherApps: true)
        window.setFrame(screen.frame, display: true)
        window.orderFrontRegardless()
        window.makeKey()
        window.makeFirstResponder(overlayView)
        NSCursor.crosshair.push()
        NSApp.runModal(for: window)
        NSCursor.pop()

        window.orderOut(nil)
        self.window = nil
        self.overlayView = nil
        return selectedRect
    }
}

@MainActor
private final class RecordingSelectionView: NSView {
    var selectionHandler: ((CGRect) -> Void)?
    var cancelHandler: (() -> Void)?

    private let snapshot: ScreenSnapshot
    private let selectionLabel = NSTextField(labelWithString: "No region selected yet")
    private var dragOrigin: CGPoint?
    private var selectionRect: CGRect?

    override var acceptsFirstResponder: Bool { true }

    init(frame frameRect: NSRect, snapshot: ScreenSnapshot) {
        self.snapshot = snapshot
        super.init(frame: frameRect)
        wantsLayer = true
        setupLabels()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let backgroundImage = NSImage(cgImage: snapshot.image, size: bounds.size)
        backgroundImage.draw(in: bounds)
        NSColor.black.withAlphaComponent(0.35).setFill()
        bounds.fill(using: .sourceAtop)

        if let selectionRect {
            backgroundImage.draw(in: selectionRect, from: selectionRect, operation: .sourceOver, fraction: 1)
            let path = NSBezierPath(rect: selectionRect)
            NSColor.systemRed.setStroke()
            path.lineWidth = 2
            path.stroke()
        }
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36, 76:
            selectionHandler?(snapshot.screenFrame)
        case 53:
            cancelHandler?()
        default:
            super.keyDown(with: event)
        }
    }

    override func cancelOperation(_ sender: Any?) {
        cancelHandler?()
    }

    override func rightMouseDown(with event: NSEvent) {
        cancelHandler?()
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        dragOrigin = point
        selectionRect = CGRect(origin: point, size: .zero)
        updateSelectionLabel()
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let dragOrigin else { return }
        let point = convert(event.locationInWindow, from: nil)
        selectionRect = CGRect(
            x: min(dragOrigin.x, point.x),
            y: min(dragOrigin.y, point.y),
            width: abs(point.x - dragOrigin.x),
            height: abs(point.y - dragOrigin.y)
        ).integral
        updateSelectionLabel()
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            dragOrigin = nil
        }

        let point = convert(event.locationInWindow, from: nil)
        let localRect: CGRect
        if let selectionRect, selectionRect.width >= 8, selectionRect.height >= 8 {
            localRect = selectionRect
        } else {
            localRect = quickSelection(around: point)
        }

        selectionHandler?(CGRect(
            x: localRect.minX + snapshot.screenFrame.minX,
            y: localRect.minY + snapshot.screenFrame.minY,
            width: localRect.width,
            height: localRect.height
        ).integral)
    }

    private func quickSelection(around point: CGPoint) -> CGRect {
        let size = CGSize(width: min(480, bounds.width), height: min(270, bounds.height))
        let origin = CGPoint(
            x: min(max(0, point.x - size.width / 2), bounds.width - size.width),
            y: min(max(0, point.y - size.height / 2), bounds.height - size.height)
        )
        return CGRect(origin: origin, size: size).integral
    }

    private func setupLabels() {
        selectionLabel.translatesAutoresizingMaskIntoConstraints = false
        selectionLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        selectionLabel.textColor = .white
        selectionLabel.stringValue = "No region selected yet"

        addSubview(selectionLabel)

        NSLayoutConstraint.activate([
            selectionLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            selectionLabel.topAnchor.constraint(equalTo: topAnchor, constant: 20),
        ])
    }

    private func updateSelectionLabel() {
        guard let selectionRect, selectionRect.width > 0, selectionRect.height > 0 else {
            selectionLabel.stringValue = "No region selected yet"
            return
        }

        selectionLabel.stringValue = "Recording: \(Int(selectionRect.width))×\(Int(selectionRect.height))"
    }
}
