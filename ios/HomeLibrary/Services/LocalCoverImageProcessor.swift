import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum LocalCoverImageProcessingError: Error, Equatable, LocalizedError {
    case inputTooLarge
    case invalidImage
    case pixelLimitExceeded
    case encodingFailed
    case outputTooLarge

    var errorDescription: String? {
        switch self {
        case .inputTooLarge:
            "Wybrane zdjęcie jest zbyt duże. Maksymalny rozmiar pliku to 12 MB."
        case .invalidImage:
            "Nie udało się odczytać wybranego zdjęcia."
        case .pixelLimitExceeded:
            "Wybrane zdjęcie ma zbyt wysoką rozdzielczość."
        case .encodingFailed:
            "Nie udało się przygotować lokalnej okładki."
        case .outputTooLarge:
            "Nie udało się zmniejszyć okładki do bezpiecznego rozmiaru."
        }
    }
}

/// Converts an untrusted image selected from Photos or captured by the camera
/// into the only representation persisted by the app: one orientation-correct
/// JPEG with bounded dimensions and no source metadata.
enum LocalCoverImageProcessor {
    static let maxInputByteCount = 12 * 1_024 * 1_024
    static let maxPixelCount = 50_000_000
    static let maxDimension = 1_600
    static let maxOutputByteCount = 1_024 * 1_024

    private static let preferredQuality: CGFloat = 0.86
    private static let minimumQuality: CGFloat = 0.34
    private static let minimumRetryDimension = 320

    static func process(_ data: Data) throws -> Data {
        guard !data.isEmpty else {
            throw LocalCoverImageProcessingError.invalidImage
        }
        guard data.count <= maxInputByteCount else {
            throw LocalCoverImageProcessingError.inputTooLarge
        }

        let sourceOptions = [
            kCGImageSourceShouldCache: false
        ] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions),
              CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(
                  source,
                  0,
                  sourceOptions
              ) as? [CFString: Any],
              let width = integerProperty(properties[kCGImagePropertyPixelWidth]),
              let height = integerProperty(properties[kCGImagePropertyPixelHeight]) else {
            throw LocalCoverImageProcessingError.invalidImage
        }

        try validatePixelDimensions(width: width, height: height)

        var targetDimension = min(max(width, height), maxDimension)
        while targetDimension > 0 {
            guard let image = thumbnail(
                from: source,
                maximumDimension: targetDimension
            ) else {
                throw LocalCoverImageProcessingError.invalidImage
            }

            if let encoded = try highestQualityJPEGFittingLimit(from: image) {
                return encoded
            }

            let decodedMaximum = max(image.width, image.height)
            guard decodedMaximum > minimumRetryDimension else {
                throw LocalCoverImageProcessingError.outputTooLarge
            }
            targetDimension = max(
                minimumRetryDimension,
                Int((Double(decodedMaximum) * 0.78).rounded(.down))
            )
        }

        throw LocalCoverImageProcessingError.outputTooLarge
    }

    static func validatePixelDimensions(width: Int, height: Int) throws {
        guard width > 0, height > 0 else {
            throw LocalCoverImageProcessingError.invalidImage
        }
        guard width <= maxPixelCount,
              height <= maxPixelCount,
              width <= maxPixelCount / height else {
            throw LocalCoverImageProcessingError.pixelLimitExceeded
        }
    }

    private static func integerProperty(_ value: Any?) -> Int? {
        if let number = value as? NSNumber {
            return number.intValue
        }
        return value as? Int
    }

    private static func thumbnail(
        from source: CGImageSource,
        maximumDimension: Int
    ) -> CGImage? {
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumDimension,
            kCGImageSourceShouldCacheImmediately: true
        ] as CFDictionary
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options)
    }

    private static func highestQualityJPEGFittingLimit(
        from image: CGImage
    ) throws -> Data? {
        let preferred = try encodeJPEG(image, quality: preferredQuality)
        if preferred.count <= maxOutputByteCount {
            return preferred
        }

        let minimum = try encodeJPEG(image, quality: minimumQuality)
        guard minimum.count <= maxOutputByteCount else {
            return nil
        }

        var best = minimum
        var lowerQuality = minimumQuality
        var upperQuality = preferredQuality
        for _ in 0..<6 {
            let candidateQuality = (lowerQuality + upperQuality) / 2
            let candidate = try encodeJPEG(image, quality: candidateQuality)
            if candidate.count <= maxOutputByteCount {
                best = candidate
                lowerQuality = candidateQuality
            } else {
                upperQuality = candidateQuality
            }
        }
        return best
    }

    private static func encodeJPEG(
        _ image: CGImage,
        quality: CGFloat
    ) throws -> Data {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            throw LocalCoverImageProcessingError.encodingFailed
        }

        // Supplying only compression quality drops all source metadata.
        // ImageIO may synthesize non-identifying JPEG properties such as the
        // output dimensions and color space.
        let properties = [
            kCGImageDestinationLossyCompressionQuality: quality
        ] as CFDictionary
        CGImageDestinationAddImage(destination, image, properties)
        guard CGImageDestinationFinalize(destination) else {
            throw LocalCoverImageProcessingError.encodingFailed
        }
        return output as Data
    }
}
