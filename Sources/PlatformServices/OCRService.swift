import AppCore
import CoreGraphics
import CoreText
import Foundation
import ImageIO
import Vision

public struct TextRecognitionOptions: Equatable, Sendable {
    public var mode: TextRecognitionMode
    /// BCP 47 code, or nil to let Vision detect the language.
    public var languageCode: String?
    public var detectsCodes: Bool
    public var detectsTables: Bool

    public init(
        mode: TextRecognitionMode = .accurate,
        languageCode: String? = nil,
        detectsCodes: Bool = true,
        detectsTables: Bool = true
    ) {
        self.mode = mode
        self.languageCode = languageCode
        self.detectsCodes = detectsCodes
        self.detectsTables = detectsTables
    }
}

/// Unlike the other platform services this is deliberately not `@MainActor`. Accurate
/// recognition of a full display or a multi-page PDF takes long enough to beach-ball the
/// UI, so callers run it on a background task. Vision requests are created per call and
/// are safe to use off the main thread.
public protocol OCRService: Sendable {
    func recognize(
        in image: CGImage,
        orientation: CGImagePropertyOrientation,
        options: TextRecognitionOptions
    ) throws -> TextRecognitionResult

    /// Languages Vision can read in `mode`, as BCP 47 codes.
    func supportedLanguageCodes(for mode: TextRecognitionMode) -> [String]

    /// Tables in `image`, given the lines `recognize` already found there. Returns an
    /// empty array when the lines are not laid out as a grid.
    func recognizeTables(
        in image: CGImage,
        orientation: CGImagePropertyOrientation,
        lines: [RecognizedTextLine],
        options: TextRecognitionOptions
    ) async -> [RecognizedTable]

    /// Loads, and if needed compiles, the models `options` will use.
    func prepare(options: TextRecognitionOptions) async
}

public struct VisionOCRService: OCRService {
    public init() {}

    public func recognize(
        in image: CGImage,
        orientation: CGImagePropertyOrientation = .up,
        options: TextRecognitionOptions
    ) throws -> TextRecognitionResult {
        let first = try recognizeOnce(in: image, orientation: orientation, options: options)
        guard first.isEmpty else {
            return first
        }

        // Small UI text and low-contrast video frames often come back empty on the first
        // pass. Retry with grayscale and 2x upscaled copies before giving up. Barcodes are
        // already handled by the first pass, so the retries only look for text.
        var textOnly = options
        textOnly.detectsCodes = false
        for variant in retryVariants(for: image) {
            // Built one at a time so at most one enlarged copy is alive at once.
            guard let candidate = transformed(image, scale: variant.scale, grayscale: variant.grayscale) else {
                continue
            }
            let result = try recognizeOnce(in: candidate, orientation: orientation, options: textOnly)
            if !result.isEmpty {
                return result
            }
        }
        return first
    }

    /// macOS compiles Vision's text models for the Neural Engine the first time an app
    /// uses them and caches the result per app and per OS build in
    /// `~/Library/Caches/<bundle id>/com.apple.e5rt.e5bundlecache`. That first compile
    /// took about 25 s on macOS 27 (later process launches load the cache in about
    /// 0.1 s). Recognizing a tiny rendered sample in the background moves that cost off
    /// the user's first capture. The sample needs real text: with a blank image Vision
    /// skips the recognizer and language models, and they would stay uncompiled.
    ///
    /// The macOS 26 document API used for tables shares these models (its first call
    /// took 54 ms once they were compiled), so it needs no warm-up of its own.
    public func prepare(options: TextRecognitionOptions) async {
        guard let sample = Self.makeWarmUpSample() else { return }
        _ = try? recognizeOnce(in: sample, orientation: .up, options: options)
    }

    /// Only grid-shaped selections pay for table work; paragraphs return immediately.
    /// On macOS 26+ Vision's document API finds real table structure, including tables
    /// without grid lines and merged cells, and its answer is final: if it sees no
    /// table, the selection is not treated as one. Earlier systems rebuild the grid from
    /// line positions with `TextTableDetector`.
    public func recognizeTables(
        in image: CGImage,
        orientation: CGImagePropertyOrientation,
        lines: [RecognizedTextLine],
        options: TextRecognitionOptions
    ) async -> [RecognizedTable] {
        guard TextTableDetector.looksTabular(lines) else {
            return []
        }
        if #available(macOS 26.0, *) {
            do {
                return try await documentTables(in: image, orientation: orientation, options: options)
            } catch {
                // Fall through to the layout heuristic rather than losing the table.
            }
        }
        return TextTableDetector.detectTable(in: lines).map { [$0] } ?? []
    }

    @available(macOS 26.0, *)
    private func documentTables(
        in image: CGImage,
        orientation: CGImagePropertyOrientation,
        options: TextRecognitionOptions
    ) async throws -> [RecognizedTable] {
        var request = RecognizeDocumentsRequest()
        // Codes are already read by `recognize`; skip the duplicate pass.
        request.barcodeDetectionOptions.enabled = false
        request.textRecognitionOptions.useLanguageCorrection = true
        if let languageCode = options.languageCode {
            request.textRecognitionOptions.automaticallyDetectLanguage = false
            request.textRecognitionOptions.recognitionLanguages = [Locale.Language(identifier: languageCode)]
        } else {
            request.textRecognitionOptions.automaticallyDetectLanguage = true
        }

        let observations = try await request.perform(on: image, orientation: orientation)
        return observations.flatMap(\.document.tables).compactMap { table -> RecognizedTable? in
            let cells = table.rows.joined()
            let rowCount = (cells.map(\.rowRange.upperBound).max() ?? -1) + 1
            let columnCount = (cells.map(\.columnRange.upperBound).max() ?? -1) + 1
            // A one-row or one-column "table" is a list or a line of text; leave it as text.
            guard rowCount >= 2, columnCount >= 2 else { return nil }

            // Merged cells span several rows or columns; their text goes in the top-left
            // position of the span and the rest stay empty, as spreadsheets expect.
            var grid = Array(repeating: Array(repeating: "", count: columnCount), count: rowCount)
            for cell in cells {
                grid[cell.rowRange.lowerBound][cell.columnRange.lowerBound] = cell.content.text.transcript
            }
            let recognized = RecognizedTable(rows: grid, boundingBox: table.boundingRegion.boundingBox.cgRect)
            // On macOS 27 the document API reported a two-column article as a 4x2 table.
            return recognized.looksLikeColumnsOfProse ? nil : recognized
        }
    }

    private static func makeWarmUpSample() -> CGImage? {
        let width = 320
        let height = 64
        guard
            let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
            let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
            ),
            let font = CTFontCreateUIFontForLanguage(.system, 28, nil)
        else {
            return nil
        }

        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let text = NSAttributedString(string: "ZoomIt 1234", attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1),
        ])
        context.textPosition = CGPoint(x: 16, y: 20)
        CTLineDraw(CTLineCreateWithAttributedString(text), context)
        return context.makeImage()
    }

    public func supportedLanguageCodes(for mode: TextRecognitionMode) -> [String] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = recognitionLevel(for: mode)
        return (try? request.supportedRecognitionLanguages()) ?? []
    }

    private func recognizeOnce(
        in image: CGImage,
        orientation: CGImagePropertyOrientation,
        options: TextRecognitionOptions
    ) throws -> TextRecognitionResult {
        let textRequest = VNRecognizeTextRequest()
        textRequest.recognitionLevel = recognitionLevel(for: options.mode)
        textRequest.usesLanguageCorrection = true
        if
            let languageCode = options.languageCode,
            (try? textRequest.supportedRecognitionLanguages())?.contains(languageCode) == true
        {
            textRequest.recognitionLanguages = [languageCode]
            textRequest.automaticallyDetectsLanguage = false
        } else {
            // Covers both "Automatic" and a language the selected mode cannot read (fast
            // mode supports fewer languages). Vision rejects unsupported codes outright.
            textRequest.automaticallyDetectsLanguage = true
        }

        var requests: [VNRequest] = [textRequest]
        let barcodeRequest = options.detectsCodes ? VNDetectBarcodesRequest() : nil
        if let barcodeRequest {
            requests.append(barcodeRequest)
        }

        let handler = VNImageRequestHandler(cgImage: image, orientation: orientation, options: [:])
        try handler.perform(requests)

        let lines = (textRequest.results ?? []).compactMap { observation -> RecognizedTextLine? in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            return RecognizedTextLine(text: candidate.string, boundingBox: observation.boundingBox)
        }

        var seenPayloads = Set<String>()
        let codes = (barcodeRequest?.results ?? []).compactMap { observation -> RecognizedCode? in
            guard
                let payload = observation.payloadStringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
                !payload.isEmpty,
                seenPayloads.insert(payload).inserted
            else {
                return nil
            }
            return RecognizedCode(payload: payload, symbology: Self.displayName(for: observation.symbology))
        }

        return TextRecognitionResult(lines: lines, codes: codes)
    }

    private func recognitionLevel(for mode: TextRecognitionMode) -> VNRequestTextRecognitionLevel {
        switch mode {
        case .accurate: .accurate
        case .fast: .fast
        }
    }

    private static func displayName(for symbology: VNBarcodeSymbology) -> String {
        switch symbology {
        case .qr: "QR"
        case .microQR: "Micro QR"
        case .aztec: "Aztec"
        case .pdf417: "PDF417"
        case .microPDF417: "MicroPDF417"
        case .dataMatrix: "Data Matrix"
        case .ean8: "EAN-8"
        case .ean13: "EAN-13"
        case .upce: "UPC-E"
        case .code39, .code39Checksum, .code39FullASCII, .code39FullASCIIChecksum: "Code 39"
        case .code93, .code93i: "Code 93"
        case .code128: "Code 128"
        default:
            // Raw values look like "VNBarcodeSymbologyITF14".
            symbology.rawValue.replacingOccurrences(of: "VNBarcodeSymbology", with: "")
        }
    }

    /// Upscaling only helps small text in small images. A photo or scan with no text
    /// would otherwise be doubled: a 48 MP camera photo became a 780 MB bitmap and an
    /// accurate OCR pass over 195 MP. Images above the limit get the grayscale retry only.
    private static let maximumUpscaledSourceEdge = 2000

    private func retryVariants(for image: CGImage) -> [(scale: CGFloat, grayscale: Bool)] {
        guard max(image.width, image.height) <= Self.maximumUpscaledSourceEdge else {
            return [(1, true)]
        }
        return [(1, true), (2, false), (2, true)]
    }

    private func transformed(_ image: CGImage, scale: CGFloat, grayscale: Bool) -> CGImage? {
        let width = max(Int(CGFloat(image.width) * scale), 1)
        let height = max(Int(CGFloat(image.height) * scale), 1)
        let colorSpace = grayscale
            ? CGColorSpaceCreateDeviceGray()
            : (image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB))
        let bitmapInfo: UInt32 = grayscale
            ? CGImageAlphaInfo.none.rawValue
            : CGImageAlphaInfo.premultipliedFirst.rawValue

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
}
