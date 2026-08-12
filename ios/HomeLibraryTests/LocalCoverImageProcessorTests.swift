import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import HomeLibrary

final class LocalCoverImageProcessorTests: XCTestCase {
    func testProducesSingleBoundedJPEGAndDownsamplesLongestEdge() throws {
        let input = try makeJPEG(width: 2_400, height: 1_200)

        let output = try LocalCoverImageProcessor.process(input)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(output as CFData, nil))
        let properties = try properties(of: output)

        XCTAssertEqual(CGImageSourceGetCount(source), 1)
        XCTAssertEqual(CGImageSourceGetType(source) as String?, UTType.jpeg.identifier)
        XCTAssertEqual(intValue(properties[kCGImagePropertyPixelWidth]), 1_600)
        XCTAssertEqual(intValue(properties[kCGImagePropertyPixelHeight]), 800)
        XCTAssertLessThanOrEqual(
            output.count,
            LocalCoverImageProcessor.maxOutputByteCount
        )
    }

    func testAppliesOrientationAndStripsSensitiveMetadata() throws {
        let input = try makeJPEG(
            width: 120,
            height: 240,
            orientation: .right,
            includesSensitiveMetadata: true
        )
        let inputProperties = try properties(of: input)
        XCTAssertNotNil(inputProperties[kCGImagePropertyGPSDictionary])
        let inputExif = inputProperties[kCGImagePropertyExifDictionary]
            as? [CFString: Any]
        XCTAssertEqual(
            inputExif?[kCGImagePropertyExifUserComment] as? String,
            "private note"
        )

        let output = try LocalCoverImageProcessor.process(input)
        let outputProperties = try properties(of: output)

        XCTAssertEqual(intValue(outputProperties[kCGImagePropertyPixelWidth]), 240)
        XCTAssertEqual(intValue(outputProperties[kCGImagePropertyPixelHeight]), 120)
        if let orientation = intValue(outputProperties[kCGImagePropertyOrientation]) {
            XCTAssertEqual(orientation, 1)
        }
        XCTAssertNil(outputProperties[kCGImagePropertyGPSDictionary])
        let outputExif = outputProperties[kCGImagePropertyExifDictionary]
            as? [CFString: Any]
        XCTAssertNil(outputExif?[kCGImagePropertyExifUserComment])
        XCTAssertNil(outputProperties[kCGImagePropertyTIFFDictionary])
    }

    func testRejectsInputBeforeDecodeWhenFileExceedsTwelveMiB() {
        let input = Data(
            repeating: 0,
            count: LocalCoverImageProcessor.maxInputByteCount + 1
        )

        XCTAssertThrowsError(try LocalCoverImageProcessor.process(input)) { error in
            XCTAssertEqual(
                error as? LocalCoverImageProcessingError,
                .inputTooLarge
            )
        }
    }

    func testRejectsInvalidImageData() {
        XCTAssertThrowsError(
            try LocalCoverImageProcessor.process(Data("not an image".utf8))
        ) { error in
            XCTAssertEqual(
                error as? LocalCoverImageProcessingError,
                .invalidImage
            )
        }
    }

    func testRejectsDimensionsAboveFiftyMegapixelsWithoutMultiplicationOverflow() {
        XCTAssertNoThrow(try LocalCoverImageProcessor.validatePixelDimensions(
            width: 10_000,
            height: 5_000
        ))
        XCTAssertThrowsError(try LocalCoverImageProcessor.validatePixelDimensions(
            width: Int.max,
            height: 2
        )) { error in
            XCTAssertEqual(
                error as? LocalCoverImageProcessingError,
                .pixelLimitExceeded
            )
        }
        XCTAssertThrowsError(try LocalCoverImageProcessor.validatePixelDimensions(
            width: 10_000,
            height: 5_001
        )) { error in
            XCTAssertEqual(
                error as? LocalCoverImageProcessingError,
                .pixelLimitExceeded
            )
        }
    }

    private func makeJPEG(
        width: Int,
        height: Int,
        orientation: CGImagePropertyOrientation? = nil,
        includesSensitiveMetadata: Bool = false
    ) throws -> Data {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(
            rawValue: CGImageAlphaInfo.premultipliedLast.rawValue
        )
        let context = try XCTUnwrap(CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo.rawValue
        ))
        context.setFillColor(red: 0.12, green: 0.32, blue: 0.54, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(red: 0.9, green: 0.45, blue: 0.1, alpha: 1)
        context.fill(CGRect(
            x: width / 5,
            y: height / 4,
            width: width * 3 / 5,
            height: height / 2
        ))
        let image = try XCTUnwrap(context.makeImage())

        let output = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(
            output,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ))
        var imageProperties: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: 0.9
        ]
        if let orientation {
            imageProperties[kCGImagePropertyOrientation] = orientation.rawValue
        }
        if includesSensitiveMetadata {
            imageProperties[kCGImagePropertyGPSDictionary] = [
                kCGImagePropertyGPSLatitude: 52.2297,
                kCGImagePropertyGPSLatitudeRef: "N",
                kCGImagePropertyGPSLongitude: 21.0122,
                kCGImagePropertyGPSLongitudeRef: "E"
            ]
            imageProperties[kCGImagePropertyExifDictionary] = [
                kCGImagePropertyExifUserComment: "private note"
            ]
            imageProperties[kCGImagePropertyTIFFDictionary] = [
                kCGImagePropertyTIFFArtist: "Private owner"
            ]
        }
        CGImageDestinationAddImage(destination, image, imageProperties as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return output as Data
    }

    private func properties(of data: Data) throws -> [CFString: Any] {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        return try XCTUnwrap(
            CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        )
    }

    private func intValue(_ value: Any?) -> Int? {
        (value as? NSNumber)?.intValue ?? value as? Int
    }
}
