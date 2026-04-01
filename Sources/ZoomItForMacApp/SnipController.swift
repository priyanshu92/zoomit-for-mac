import AppKit
import AppCore
import PlatformServices

@MainActor
struct SnipCaptureResult {
    let title: String
    let message: String
}

enum SnipControllerError: LocalizedError {
    case selectionCancelled
    case captureUnavailable
    case cropFailed
    case saveFailed(String)
    case ocrFailed

    var errorDescription: String? {
        switch self {
        case .selectionCancelled:
            return "Snip cancelled."
        case .captureUnavailable:
            return "Screen capture could not be completed."
        case .cropFailed:
            return "The selected region could not be cropped."
        case let .saveFailed(path):
            return "The capture could not be saved to \(path)."
        case .ocrFailed:
            return "The selected region did not produce recognizable text."
        }
    }
}

private enum SnipCaptureDestination {
    case clipboard
    case file
}

private enum SnipShortcutAction {
    case copyFullDisplay
    case copySelection
    case saveFullDisplay
    case saveSelection

    var needsSelection: Bool {
        switch self {
        case .copySelection, .saveSelection:
            return true
        case .copyFullDisplay, .saveFullDisplay:
            return false
        }
    }
}

private struct SnipSelectionOutcome {
    let action: SnipShortcutAction
    let selection: CGRect?
}

@MainActor
final class SnipController {
    private let screenCaptureService: ScreenCaptureService
    private let clipboardService: ClipboardService
    private let ocrService: OCRService
    private let settingsStore: AppSettingsStore

    init(
        screenCaptureService: ScreenCaptureService,
        clipboardService: ClipboardService,
        ocrService: OCRService,
        settingsStore: AppSettingsStore
    ) {
        self.screenCaptureService = screenCaptureService
        self.clipboardService = clipboardService
        self.ocrService = ocrService
        self.settingsStore = settingsStore
    }

    func captureToClipboard() throws -> SnipCaptureResult {
        try interactiveCapture(defaultDestination: .clipboard)
    }

    func captureToClipboard(from snapshot: ScreenSnapshot) throws -> SnipCaptureResult {
        try interactiveCapture(snapshot: snapshot, defaultDestination: .clipboard)
    }

    func captureToFile() throws -> SnipCaptureResult {
        try interactiveCapture(defaultDestination: .file)
    }

    func captureToFile(from snapshot: ScreenSnapshot) throws -> SnipCaptureResult {
        try interactiveCapture(snapshot: snapshot, defaultDestination: .file)
    }

    func capturePanoramaToClipboard() throws -> SnipCaptureResult {
        let snapshots = screenCaptureService.captureAllScreens()
        guard !snapshots.isEmpty else {
            throw SnipControllerError.captureUnavailable
        }

        let frames = snapshots.map(\.screenFrame)
        guard let canvas = CaptureGeometry.panoramaCanvas(for: frames) else {
            throw SnipControllerError.captureUnavailable
        }

        let image = NSImage(size: canvas.size)
        image.lockFocus()
        for snapshot in snapshots.sorted(by: { $0.screenFrame.minX < $1.screenFrame.minX }) {
            let drawRect = CaptureGeometry.panoramaDrawRect(for: snapshot.screenFrame, canvas: canvas)
            NSImage(cgImage: snapshot.image, size: snapshot.screenFrame.size).draw(in: drawRect)
        }
        image.unlockFocus()

        clipboardService.copy(image: image)
        let savedURL = try save(image: image, prefix: "ZoomItPanorama", fileExtension: "png")

        return SnipCaptureResult(
            title: "Panorama copied to clipboard",
            message: "Stitched \(snapshots.count) displays using their actual arrangement and saved a PNG to \(savedURL.path)."
        )
    }

    func captureOCRText() throws -> SnipCaptureResult {
        let snapshot = try snapshotUnderMouse()
        return try captureOCRText(from: snapshot)
    }

    func captureOCRText(from snapshot: ScreenSnapshot) throws -> SnipCaptureResult {
        let selection = try selectRegion(from: snapshot)
        let croppedImage = try croppedImage(from: snapshot, selection: selection)
        let text = try recognizeTextWithFallbacks(in: croppedImage)
        clipboardService.copy(text: text)

        let lineCount = text.split(separator: "\n").count
        return SnipCaptureResult(
            title: "OCR text copied to clipboard",
            message: "Recognized \(lineCount) line\(lineCount == 1 ? "" : "s") from the selected snip."
        )
    }

    private func interactiveCapture(defaultDestination: SnipCaptureDestination) throws -> SnipCaptureResult {
        let snapshot = try snapshotUnderMouse()
        return try interactiveCapture(snapshot: snapshot, defaultDestination: defaultDestination)
    }

    private func interactiveCapture(snapshot: ScreenSnapshot, defaultDestination: SnipCaptureDestination) throws -> SnipCaptureResult {
        let outcome = try selectCaptureOutcome(from: snapshot, defaultDestination: defaultDestination)
        return try process(outcome: outcome, snapshot: snapshot)
    }

    private func process(outcome: SnipSelectionOutcome, snapshot: ScreenSnapshot) throws -> SnipCaptureResult {
        switch outcome.action {
        case .copyFullDisplay:
            let image = NSImage(cgImage: snapshot.image, size: snapshot.screenFrame.size)
            clipboardService.copy(image: image)
            return SnipCaptureResult(
                title: "Screenshot copied to clipboard",
                message: "Copied the full display (\(Int(snapshot.screenFrame.width))×\(Int(snapshot.screenFrame.height)) pixels) to the clipboard."
            )
        case .copySelection:
            guard let selection = outcome.selection else {
                throw SnipControllerError.selectionCancelled
            }
            let croppedImage = try croppedImage(from: snapshot, selection: selection)
            let image = NSImage(cgImage: croppedImage, size: selection.size)
            clipboardService.copy(image: image)
            return SnipCaptureResult(
                title: "Snip copied to clipboard",
                message: "Captured \(Int(selection.width))×\(Int(selection.height)) pixels and copied the selection to the clipboard."
            )
        case .saveFullDisplay:
            let image = NSImage(cgImage: snapshot.image, size: snapshot.screenFrame.size)
            let savedURL = try save(image: image, prefix: "ZoomItScreenshot", fileExtension: "png")
            return SnipCaptureResult(
                title: "Screenshot saved as PNG",
                message: "Saved the full display PNG to \(savedURL.path)."
            )
        case .saveSelection:
            guard let selection = outcome.selection else {
                throw SnipControllerError.selectionCancelled
            }
            let croppedImage = try croppedImage(from: snapshot, selection: selection)
            let image = NSImage(cgImage: croppedImage, size: selection.size)
            let savedURL = try save(image: image, prefix: "ZoomItSnip", fileExtension: "png")
            return SnipCaptureResult(
                title: "Snip saved as PNG",
                message: "Captured \(Int(selection.width))×\(Int(selection.height)) pixels and saved a PNG to \(savedURL.path)."
            )
        }
    }

    private func snapshotUnderMouse() throws -> ScreenSnapshot {
        let mouseLocation = NSEvent.mouseLocation
        guard let snapshot = screenCaptureService.captureScreen(containing: mouseLocation) else {
            throw SnipControllerError.captureUnavailable
        }

        return snapshot
    }

    private func selectCaptureOutcome(from snapshot: ScreenSnapshot, defaultDestination: SnipCaptureDestination) throws -> SnipSelectionOutcome {
        guard let screen = NSScreen.screens.first(where: { $0.frame == snapshot.screenFrame }) else {
            throw SnipControllerError.captureUnavailable
        }

        let selector = SnipRegionSelector(snapshot: snapshot, screen: screen)
        guard let outcome = selector.run(defaultDestination: defaultDestination) else {
            throw SnipControllerError.selectionCancelled
        }

        return outcome
    }

    private func selectRegion(from snapshot: ScreenSnapshot) throws -> CGRect {
        let outcome = try selectCaptureOutcome(from: snapshot, defaultDestination: .clipboard)
        switch outcome.action {
        case .copySelection, .saveSelection:
            guard let selection = outcome.selection else {
                throw SnipControllerError.selectionCancelled
            }
            return selection
        case .copyFullDisplay, .saveFullDisplay:
            return snapshot.screenFrame
        }
    }

    private func croppedImage(from snapshot: ScreenSnapshot, selection: CGRect) throws -> CGImage {
        guard
            let cropRect = CaptureGeometry.cropRect(
                for: selection,
                within: snapshot.screenFrame,
                scaleFactor: snapshot.scaleFactor
            ),
            let image = snapshot.image.cropping(to: cropRect)
        else {
            throw SnipControllerError.cropFailed
        }

        return image
    }

    private func recognizeTextWithFallbacks(in image: CGImage) throws -> String {
        let candidates = [image] + enhancedOCRCandidates(from: image)

        for candidate in candidates {
            if let text = try? ocrService.recognizeText(in: candidate), !text.isEmpty {
                return text
            }
        }

        throw SnipControllerError.ocrFailed
    }

    private func enhancedOCRCandidates(from image: CGImage) -> [CGImage] {
        var results: [CGImage] = []
        if let grayscale = transformed(image: image, scale: 1.0, grayscale: true) {
            results.append(grayscale)
        }
        if let upscaled = transformed(image: image, scale: 2.0, grayscale: false) {
            results.append(upscaled)
        }
        if let upscaledGrayscale = transformed(image: image, scale: 2.0, grayscale: true) {
            results.append(upscaledGrayscale)
        }
        return results
    }

    private func transformed(image: CGImage, scale: CGFloat, grayscale: Bool) -> CGImage? {
        let width = max(Int(CGFloat(image.width) * scale), 1)
        let height = max(Int(CGFloat(image.height) * scale), 1)
        let colorSpace = grayscale ? CGColorSpaceCreateDeviceGray() : (image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB))

        let bitmapInfo: UInt32 = grayscale ? CGImageAlphaInfo.none.rawValue : CGImageAlphaInfo.premultipliedFirst.rawValue
        guard
            let colorSpace,
            let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: bitmapInfo
            )
        else {
            return nil
        }

        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    private func save(image: NSImage, prefix: String, fileExtension: String) throws -> URL {
        guard
            let tiff = image.tiffRepresentation,
            let bitmap = NSBitmapImageRep(data: tiff),
            let data = bitmap.representation(using: .png, properties: [:])
        else {
            throw SnipControllerError.captureUnavailable
        }

        let settings = settingsStore.load()
        let directory = URL(fileURLWithPath: settings.screenshotSaveLocation, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw SnipControllerError.saveFailed(directory.path)
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let fileName = "\(prefix)-\(formatter.string(from: Date())).\(fileExtension)"
        let destinationURL = directory.appendingPathComponent(fileName)

        do {
            try data.write(to: destinationURL, options: .atomic)
            return destinationURL
        } catch {
            throw SnipControllerError.saveFailed(destinationURL.path)
        }
    }
}

@MainActor
private final class SnipRegionSelector {
    private let snapshot: ScreenSnapshot
    private let screen: NSScreen
    private var window: NSWindow?
    private var overlayView: SnipSelectionView?
    private var outcome: SnipSelectionOutcome?

    init(snapshot: ScreenSnapshot, screen: NSScreen) {
        self.snapshot = snapshot
        self.screen = screen
    }

    func run(defaultDestination: SnipCaptureDestination) -> SnipSelectionOutcome? {
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
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true

        let overlayView = SnipSelectionView(
            frame: CGRect(origin: .zero, size: screen.frame.size),
            snapshot: snapshot,
            defaultDestination: defaultDestination
        )
        overlayView.autoresizingMask = [.width, .height]
        overlayView.selectionHandler = { [weak self] result in
            self?.outcome = result
            NSApp.stopModal()
        }
        overlayView.cancelHandler = {
            NSApp.stopModal()
        }

        window.contentView = overlayView
        self.window = window
        self.overlayView = overlayView

        window.orderFrontRegardless()
        window.makeKey()
        window.makeFirstResponder(overlayView)
        NSCursor.crosshair.push()
        NSApp.runModal(for: window)
        NSCursor.pop()

        window.orderOut(nil)
        self.window = nil
        self.overlayView = nil
        return outcome
    }
}

@MainActor
private final class SnipSelectionView: NSView {
    var selectionHandler: ((SnipSelectionOutcome) -> Void)?
    var cancelHandler: (() -> Void)?

    private let snapshot: ScreenSnapshot
    private let defaultDestination: SnipCaptureDestination
    private let selectionLabel = NSTextField(labelWithString: "No region selected yet")
    private var dragOrigin: CGPoint?
    private var selectionRect: CGRect?

    override var acceptsFirstResponder: Bool { true }

    init(frame frameRect: NSRect, snapshot: ScreenSnapshot, defaultDestination: SnipCaptureDestination) {
        self.snapshot = snapshot
        self.defaultDestination = defaultDestination
        super.init(frame: frameRect)
        wantsLayer = true
        setupLabels()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.initialFirstResponder = self
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
            NSColor.systemBlue.setStroke()
            path.lineWidth = 2
            path.stroke()

            let fillPath = NSBezierPath(rect: selectionRect)
            NSColor.systemBlue.withAlphaComponent(0.08).setFill()
            fillPath.fill()
        }
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36, 76:
            complete(action: defaultDestination == .clipboard ? .copyFullDisplay : .saveFullDisplay)
            return
        case 53:
            cancelHandler?()
            return
        default:
            break
        }

        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard modifiers.contains(.control) else {
            super.keyDown(with: event)
            return
        }

        let extraModifiers = modifiers.subtracting([.control, .shift])
        guard extraModifiers.isEmpty, let key = event.charactersIgnoringModifiers?.lowercased() else {
            super.keyDown(with: event)
            return
        }

        switch (key, modifiers.contains(.shift)) {
        case ("c", false):
            complete(action: .copyFullDisplay)
        case ("c", true):
            complete(action: .copySelection)
        case ("s", false):
            complete(action: .saveFullDisplay)
        case ("s", true):
            complete(action: .saveSelection)
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

        let action: SnipShortcutAction = defaultDestination == .clipboard ? .copySelection : .saveSelection
        selectionHandler?(SnipSelectionOutcome(action: action, selection: makeGlobalRect(from: localRect)))
    }

    private func complete(action: SnipShortcutAction) {
        if action.needsSelection {
            guard let selectionRect, selectionRect.width >= 8, selectionRect.height >= 8 else {
                NSSound.beep()
                selectionLabel.stringValue = "Drag a region before using Ctrl+Shift+C or Ctrl+Shift+S"
                return
            }
            selectionHandler?(SnipSelectionOutcome(action: action, selection: makeGlobalRect(from: selectionRect)))
            return
        }

        selectionHandler?(SnipSelectionOutcome(action: action, selection: nil))
    }

    private func makeGlobalRect(from localRect: CGRect) -> CGRect {
        CGRect(
            x: localRect.minX + snapshot.screenFrame.minX,
            y: localRect.minY + snapshot.screenFrame.minY,
            width: localRect.width,
            height: localRect.height
        ).integral
    }

    private func quickSelection(around point: CGPoint) -> CGRect {
        let size = CGSize(width: min(320, bounds.width), height: min(180, bounds.height))
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
        selectionLabel.backgroundColor = .clear

        addSubview(selectionLabel)

        NSLayoutConstraint.activate([
            selectionLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            selectionLabel.topAnchor.constraint(equalTo: topAnchor, constant: 20),
            selectionLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -20),
        ])
    }

    private func updateSelectionLabel() {
        guard let selectionRect, selectionRect.width > 0, selectionRect.height > 0 else {
            selectionLabel.stringValue = "No region selected yet"
            return
        }

        selectionLabel.stringValue = "Selection: \(Int(selectionRect.width))×\(Int(selectionRect.height))"
    }
}
