import CoreGraphics
import Foundation
import Vision

@MainActor
public protocol OCRService {
    func recognizeText(in image: CGImage) throws -> String
}

public enum OCRServiceError: Error {
    case noTextRecognized
}

@MainActor
public struct VisionOCRService: OCRService {
    public init() {}

    public func recognizeText(in image: CGImage) throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true

        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([request])

        let text = request.results?
            .compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        guard !text.isEmpty else {
            throw OCRServiceError.noTextRecognized
        }

        return text
    }
}

