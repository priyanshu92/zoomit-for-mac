import AppCore
import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers

/// Something to read text from that is not a live screen region.
public enum TextCaptureInput: Sendable {
    case image(CGImage, orientation: CGImagePropertyOrientation)
    case file(URL)
    case pdfData(Data)
}

public enum TextExtractionError: LocalizedError {
    case unsupportedFile(String)
    case unreadableFile(String)
    case unreadablePDF

    public var errorDescription: String? {
        switch self {
        case let .unsupportedFile(name):
            return "\(name) is not an image or a PDF."
        case let .unreadableFile(name):
            return "\(name) could not be opened."
        case .unreadablePDF:
            return "The PDF could not be opened."
        }
    }
}

public struct ExtractedText: Sendable {
    public let pages: [TextCapturePage]
    /// PDF pages without a text layer that were not OCR'd because of `maximumOCRPages`.
    public let skippedPageCount: Int

    public init(pages: [TextCapturePage], skippedPageCount: Int = 0) {
        self.pages = pages
        self.skippedPageCount = skippedPageCount
    }
}

/// Reads text from images, image files, and PDFs. Runs on a background task; nothing
/// here touches AppKit.
public struct TextExtractor: Sendable {
    /// Each OCR'd page costs about a second in accurate mode, so long scanned PDFs are
    /// capped to keep the wait reasonable. Pages with a text layer are always included.
    public static let maximumOCRPages = 20

    private let ocrService: OCRService

    public init(ocrService: OCRService) {
        self.ocrService = ocrService
    }

    public static func canExtract(fromFileAt url: URL) -> Bool {
        guard url.isFileURL, let type = contentType(of: url) else {
            return false
        }
        return type.conforms(to: .image) || type.conforms(to: .pdf)
    }

    public func extract(from input: TextCaptureInput, options: TextRecognitionOptions) async throws -> ExtractedText {
        switch input {
        case let .image(image, orientation):
            let result = try await recognize(image, orientation: orientation, options: options)
            return ExtractedText(pages: [.recognized(result)])
        case let .pdfData(data):
            guard let document = PDFDocument(data: data) else {
                throw TextExtractionError.unreadablePDF
            }
            return try await extract(from: document, options: options)
        case let .file(url):
            return try await extract(fromFileAt: url, options: options)
        }
    }

    /// Text and codes first; then, for grid-shaped text, the table pass. A selection that
    /// produced a code skips tables because the code wins composition anyway.
    private func recognize(
        _ image: CGImage,
        orientation: CGImagePropertyOrientation,
        options: TextRecognitionOptions
    ) async throws -> TextRecognitionResult {
        let result = try ocrService.recognize(in: image, orientation: orientation, options: options)
        guard options.detectsTables, result.codes.isEmpty, !result.lines.isEmpty else {
            return result
        }
        let tables = await ocrService.recognizeTables(
            in: image,
            orientation: orientation,
            lines: result.lines,
            options: options
        )
        guard !tables.isEmpty else {
            return result
        }
        return TextRecognitionResult(lines: result.lines, codes: result.codes, tables: tables)
    }

    private func extract(fromFileAt url: URL, options: TextRecognitionOptions) async throws -> ExtractedText {
        let name = url.lastPathComponent
        guard let type = Self.contentType(of: url) else {
            throw TextExtractionError.unreadableFile(name)
        }

        if type.conforms(to: .pdf) {
            guard let document = PDFDocument(url: url) else {
                throw TextExtractionError.unreadableFile(name)
            }
            return try await extract(from: document, options: options)
        }

        guard type.conforms(to: .image) else {
            throw TextExtractionError.unsupportedFile(name)
        }
        guard
            let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else {
            throw TextExtractionError.unreadableFile(name)
        }

        let result = try await recognize(image, orientation: Self.orientation(of: source), options: options)
        return ExtractedText(pages: [.recognized(result)])
    }

    private func extract(from document: PDFDocument, options: TextRecognitionOptions) async throws -> ExtractedText {
        var pages: [TextCapturePage] = []
        var ocrPageCount = 0
        var skippedPageCount = 0

        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }

            // Digital PDFs already carry exact text; only scanned pages need OCR.
            let embedded = page.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !embedded.isEmpty {
                pages.append(.embedded(embedded))
                continue
            }

            guard ocrPageCount < Self.maximumOCRPages else {
                skippedPageCount += 1
                continue
            }
            ocrPageCount += 1

            guard let image = Self.render(page) else { continue }
            pages.append(.recognized(try await recognize(image, orientation: .up, options: options)))
        }

        return ExtractedText(pages: pages, skippedPageCount: skippedPageCount)
    }

    /// Renders a page at up to 2x (144 dpi), which is plenty for Vision on body text. The
    /// long edge is capped so a poster-sized page cannot allocate hundreds of megabytes.
    private static func render(_ page: PDFPage) -> CGImage? {
        guard let pageRef = page.pageRef else { return nil }

        let box = pageRef.getBoxRect(.mediaBox)
        let isQuarterTurned = abs(pageRef.rotationAngle) % 180 == 90
        let pointSize = isQuarterTurned ? CGSize(width: box.height, height: box.width) : box.size
        guard pointSize.width > 0, pointSize.height > 0 else { return nil }

        let scale = min(2, 4096 / max(pointSize.width, pointSize.height))
        let width = Int((pointSize.width * scale).rounded())
        let height = Int((pointSize.height * scale).rounded())
        guard
            width > 0,
            height > 0,
            let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
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
            return nil
        }

        // Scanned pages are often transparent where the paper is white.
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .high
        context.scaleBy(x: scale, y: scale)
        // getDrawingTransform applies the page's /Rotate entry but never scales up, so the
        // target rect stays in points and the 2x comes from the scale above.
        context.concatenate(pageRef.getDrawingTransform(
            .mediaBox,
            rect: CGRect(origin: .zero, size: pointSize),
            rotate: 0,
            preserveAspectRatio: true
        ))
        context.drawPDFPage(pageRef)
        return context.makeImage()
    }

    /// Camera photos store their rotation as EXIF orientation instead of rotating pixels;
    /// Vision needs it to read sideways text.
    public static func orientation(of source: CGImageSource) -> CGImagePropertyOrientation {
        guard
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let rawValue = properties[kCGImagePropertyOrientation] as? UInt32,
            let orientation = CGImagePropertyOrientation(rawValue: rawValue)
        else {
            return .up
        }
        return orientation
    }

    private static func contentType(of url: URL) -> UTType? {
        if let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType {
            return type
        }
        return UTType(filenameExtension: url.pathExtension)
    }
}
