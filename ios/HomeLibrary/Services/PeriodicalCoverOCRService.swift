import Foundation
import ImageIO
import Vision

struct PeriodicalCoverOCRObservation: Equatable, Sendable {
    let text: String
    let confidence: Float
    let boundingBox: CGRect
}

protocol PeriodicalCoverOCRRecognizing: Sendable {
    func supportedRecognitionLanguages() async throws -> [String]

    func recognize(
        imageData: Data,
        recognitionLanguages: [String]
    ) async throws -> [PeriodicalCoverOCRObservation]
}

enum PeriodicalCoverOCRServiceError: Error, Equatable, LocalizedError {
    case emptyImage
    case imageTooLarge
    case invalidImage
    case invalidDimensions
    case pixelCountExceeded
    case recognitionUnavailable
    case recognitionFailed

    var errorDescription: String? {
        switch self {
        case .emptyImage:
            return "Zdjęcie okładki jest puste."
        case .imageTooLarge:
            return "Zdjęcie okładki zajmuje zbyt dużo pamięci."
        case .invalidImage:
            return "Nie udało się odczytać zdjęcia okładki."
        case .invalidDimensions:
            return "Zdjęcie okładki ma nieprawidłowe wymiary."
        case .pixelCountExceeded:
            return "Zdjęcie okładki ma zbyt wysoką rozdzielczość."
        case .recognitionUnavailable:
            return "Rozpoznawanie tekstu po polsku, angielsku lub niemiecku nie jest dostępne."
        case .recognitionFailed:
            return "Nie udało się rozpoznać tekstu na okładce."
        }
    }
}

/// Performs bounded, on-device OCR for a single periodical cover.
///
/// The service neither stores nor uploads `imageData`. The injected recognizer
/// makes its validation and ordering rules independently testable without
/// loading the Vision recognition runtime.
struct PeriodicalCoverOCRService: Sendable {
    struct Configuration: Equatable, Sendable {
        static let maximumAllowedInputBytes = 12 * 1_024 * 1_024
        static let maximumAllowedPixelCount = 50_000_000
        static let maximumAllowedLines = 200

        let maximumInputBytes: Int
        let maximumPixelCount: Int
        let maximumLines: Int

        init(
            maximumInputBytes: Int = Configuration.maximumAllowedInputBytes,
            maximumPixelCount: Int = Configuration.maximumAllowedPixelCount,
            maximumLines: Int = Configuration.maximumAllowedLines
        ) {
            self.maximumInputBytes = min(
                max(1, maximumInputBytes),
                Configuration.maximumAllowedInputBytes
            )
            self.maximumPixelCount = min(
                max(1, maximumPixelCount),
                Configuration.maximumAllowedPixelCount
            )
            self.maximumLines = min(
                max(1, maximumLines),
                Configuration.maximumAllowedLines
            )
        }
    }

    private static let preferredLanguageCodes = ["pl-PL", "en-US", "de-DE"]
    private static let readingBandHeight = 0.025

    private let recognizer: any PeriodicalCoverOCRRecognizing
    private let configuration: Configuration

    init(configuration: Configuration = Configuration()) {
        self.init(
            recognizer: VisionPeriodicalCoverOCRRecognizer(),
            configuration: configuration
        )
    }

    init(
        recognizer: any PeriodicalCoverOCRRecognizing,
        configuration: Configuration = Configuration()
    ) {
        self.recognizer = recognizer
        self.configuration = configuration
    }

    func recognizeText(in imageData: Data) async throws -> [PeriodicalRecognizedTextLine] {
        try Task.checkCancellation()
        try validate(imageData)
        try Task.checkCancellation()

        let supportedLanguages: [String]
        do {
            supportedLanguages = try await recognizer.supportedRecognitionLanguages()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw PeriodicalCoverOCRServiceError.recognitionFailed
        }

        try Task.checkCancellation()
        let recognitionLanguages = Self.preferredLanguages(from: supportedLanguages)
        guard !recognitionLanguages.isEmpty else {
            throw PeriodicalCoverOCRServiceError.recognitionUnavailable
        }

        let observations: [PeriodicalCoverOCRObservation]
        do {
            observations = try await recognizer.recognize(
                imageData: imageData,
                recognitionLanguages: recognitionLanguages
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw PeriodicalCoverOCRServiceError.recognitionFailed
        }

        try Task.checkCancellation()
        return Self.orderedLines(
            from: observations,
            maximumCount: configuration.maximumLines
        )
    }

    private func validate(_ imageData: Data) throws {
        guard !imageData.isEmpty else {
            throw PeriodicalCoverOCRServiceError.emptyImage
        }
        guard imageData.count <= configuration.maximumInputBytes else {
            throw PeriodicalCoverOCRServiceError.imageTooLarge
        }

        guard let source = CGImageSourceCreateWithData(
            imageData as CFData,
            [kCGImageSourceShouldCache: false] as CFDictionary
        ), CGImageSourceGetCount(source) > 0 else {
            throw PeriodicalCoverOCRServiceError.invalidImage
        }
        guard let properties = CGImageSourceCopyPropertiesAtIndex(
            source,
            0,
            [kCGImageSourceShouldCache: false] as CFDictionary
        ) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.int64Value,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.int64Value,
              width > 0,
              height > 0 else {
            throw PeriodicalCoverOCRServiceError.invalidDimensions
        }

        let (pixelCount, overflow) = width.multipliedReportingOverflow(by: height)
        guard !overflow, pixelCount <= Int64(configuration.maximumPixelCount) else {
            throw PeriodicalCoverOCRServiceError.pixelCountExceeded
        }
    }

    private static func preferredLanguages(from supportedLanguages: [String]) -> [String] {
        let normalizedSupported = supportedLanguages
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

        return preferredLanguageCodes.compactMap { preferred in
            if let exact = normalizedSupported.first(where: {
                $0.caseInsensitiveCompare(preferred) == .orderedSame
            }) {
                return exact
            }

            let preferredBase = languageBase(of: preferred)
            return normalizedSupported.first(where: {
                languageBase(of: $0) == preferredBase
            })
        }
    }

    private static func languageBase(of identifier: String) -> String {
        identifier
            .replacingOccurrences(of: "_", with: "-")
            .split(separator: "-", maxSplits: 1)
            .first
            .map { String($0).lowercased() }
            ?? ""
    }

    private struct OrderedObservation {
        let line: PeriodicalRecognizedTextLine
        let boundingBox: CGRect
        let readingBand: Int
    }

    private static func orderedLines(
        from observations: [PeriodicalCoverOCRObservation],
        maximumCount: Int
    ) -> [PeriodicalRecognizedTextLine] {
        observations.compactMap { observation -> OrderedObservation? in
            let text = observation.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty,
                  observation.confidence.isFinite,
                  observation.boundingBox.minX.isFinite,
                  observation.boundingBox.minY.isFinite,
                  observation.boundingBox.width.isFinite,
                  observation.boundingBox.height.isFinite,
                  observation.boundingBox.width > 0,
                  observation.boundingBox.height > 0 else {
                return nil
            }

            let confidence = min(max(observation.confidence, 0), 1)
            let top = min(max(observation.boundingBox.maxY, 0), 1)
            let band = Int(floor((1 - top) / readingBandHeight))
            return OrderedObservation(
                line: PeriodicalRecognizedTextLine(text: text, confidence: confidence),
                boundingBox: observation.boundingBox,
                readingBand: band
            )
        }
        .sorted { lhs, rhs in
            if lhs.readingBand != rhs.readingBand {
                return lhs.readingBand < rhs.readingBand
            }
            if lhs.boundingBox.minX != rhs.boundingBox.minX {
                return lhs.boundingBox.minX < rhs.boundingBox.minX
            }
            if lhs.boundingBox.maxY != rhs.boundingBox.maxY {
                return lhs.boundingBox.maxY > rhs.boundingBox.maxY
            }
            if lhs.line.text != rhs.line.text {
                return lhs.line.text < rhs.line.text
            }
            if lhs.line.confidence != rhs.line.confidence {
                return lhs.line.confidence > rhs.line.confidence
            }
            if lhs.boundingBox.minY != rhs.boundingBox.minY {
                return lhs.boundingBox.minY > rhs.boundingBox.minY
            }
            return lhs.boundingBox.width < rhs.boundingBox.width
        }
        .prefix(maximumCount)
        .map(\.line)
    }
}

struct VisionPeriodicalCoverOCRRecognizer: PeriodicalCoverOCRRecognizing {
    func supportedRecognitionLanguages() async throws -> [String] {
        let request = Self.makeRequest()
        return try request.supportedRecognitionLanguages()
    }

    func recognize(
        imageData: Data,
        recognitionLanguages: [String]
    ) async throws -> [PeriodicalCoverOCRObservation] {
        try Task.checkCancellation()

        let request = Self.makeRequest()
        request.recognitionLanguages = recognitionLanguages
        let recognitionTask = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let handler = VNImageRequestHandler(data: imageData, options: [:])
            try handler.perform([request])
            try Task.checkCancellation()

            let results: [VNRecognizedTextObservation] = request.results ?? []
            return results.compactMap { observation -> PeriodicalCoverOCRObservation? in
                guard let candidate = observation.topCandidates(1).first else {
                    return nil
                }
                return PeriodicalCoverOCRObservation(
                    text: candidate.string,
                    confidence: candidate.confidence,
                    boundingBox: observation.boundingBox
                )
            }
        }

        return try await withTaskCancellationHandler {
            try await recognitionTask.value
        } onCancel: {
            request.cancel()
            recognitionTask.cancel()
        }
    }

    private static func makeRequest() -> VNRecognizeTextRequest {
        let request = VNRecognizeTextRequest()
        request.revision = VNRecognizeTextRequestRevision3
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        return request
    }
}
