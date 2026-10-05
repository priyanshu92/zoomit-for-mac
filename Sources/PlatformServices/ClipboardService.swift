import AppKit
import Foundation
import ImageIO

@MainActor
public protocol ClipboardService {
    func copy(image: NSImage)
    func copy(text: String)
    /// Plain text plus an optional HTML flavor. Apps that understand HTML (Notes, Pages,
    /// Word, Mail) paste the rich version; everything else pastes `text`.
    func copy(text: String, html: String?)
    /// The image, image file, or PDF currently on the clipboard, if any.
    func textCaptureInput() -> TextCaptureInput?
}

@MainActor
public struct MacClipboardService: ClipboardService {
    public init() {}

    public func copy(image: NSImage) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([image])
    }

    public func copy(text: String) {
        copy(text: text, html: nil)
    }

    public func copy(text: String, html: String?) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        if let html {
            pasteboard.setString(html, forType: .html)
        }
    }

    public func textCaptureInput() -> TextCaptureInput? {
        let pasteboard = NSPasteboard.general

        // Copying a file in Finder puts the file URL *and* the file's icon on the
        // pasteboard. Check URLs first so the file is read rather than its icon.
        if
            let urls = pasteboard.readObjects(
                forClasses: [NSURL.self],
                options: [.urlReadingFileURLsOnly: true]
            ) as? [URL],
            let url = urls.first(where: TextExtractor.canExtract(fromFileAt:))
        {
            return .file(url)
        }

        // Prefer bitmaps over PDF: apps such as Preview and Keynote put both on the
        // pasteboard, and the bitmap is exactly what the user saw when copying.
        let bitmapTypes: [NSPasteboard.PasteboardType] = [
            .png,
            .tiff,
            NSPasteboard.PasteboardType("public.jpeg"),
            NSPasteboard.PasteboardType("public.heic"),
        ]
        for type in bitmapTypes {
            guard
                let data = pasteboard.data(forType: type),
                let source = CGImageSourceCreateWithData(data as CFData, nil),
                let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
            else {
                continue
            }
            return .image(image, orientation: TextExtractor.orientation(of: source))
        }

        if let data = pasteboard.data(forType: .pdf) {
            return .pdfData(data)
        }

        if
            let image = NSImage(pasteboard: pasteboard),
            let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        {
            return .image(cgImage, orientation: .up)
        }

        return nil
    }
}
