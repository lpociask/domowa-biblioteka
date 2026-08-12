import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import HomeLibrary

final class PeriodicalCoverOCRServiceTests: XCTestCase {
    func testUsesOnlySupportedPolishEnglishAndGermanLanguages() async throws {
        let recognizer = StubPeriodicalCoverOCRRecognizer(
            supportedLanguages: ["fr-FR", "de-DE", "en-GB", "pl-PL", "es-ES"],
            observations: []
        )
        let service = PeriodicalCoverOCRService(recognizer: recognizer)

        _ = try await service.recognizeText(in: Self.makeImageData(width: 2, height: 2))

        let receivedLanguages = await recognizer.receivedLanguages
        XCTAssertEqual(receivedLanguages, ["pl-PL", "en-GB", "de-DE"])
    }

    func testFailsWhenNoneOfThePreferredLanguagesIsSupported() async throws {
        let recognizer = StubPeriodicalCoverOCRRecognizer(
            supportedLanguages: ["fr-FR", "es-ES"],
            observations: []
        )
        let service = PeriodicalCoverOCRService(recognizer: recognizer)

        await assertServiceError(.recognitionUnavailable) {
            try await service.recognizeText(in: Self.makeImageData(width: 2, height: 2))
        }
        let callCount = await recognizer.recognitionCallCount
        XCTAssertEqual(callCount, 0)
    }

    func testOrdersTopToBottomAndLeftToRightWithinReadingBand() async throws {
        let recognizer = StubPeriodicalCoverOCRRecognizer(
            observations: [
                .init(text: "bottom", confidence: 0.7, boundingBox: .init(x: 0.1, y: 0.1, width: 0.3, height: 0.1)),
                .init(text: "top right", confidence: 0.8, boundingBox: .init(x: 0.55, y: 0.8, width: 0.3, height: 0.1)),
                .init(text: "top left", confidence: 0.9, boundingBox: .init(x: 0.1, y: 0.81, width: 0.3, height: 0.1)),
                .init(text: "middle", confidence: 0.85, boundingBox: .init(x: 0.2, y: 0.5, width: 0.3, height: 0.1))
            ]
        )
        let service = PeriodicalCoverOCRService(recognizer: recognizer)

        let lines = try await service.recognizeText(in: Self.makeImageData(width: 2, height: 2))

        XCTAssertEqual(lines.map(\.text), ["top left", "top right", "middle", "bottom"])
    }

    func testTrimsTextClampsConfidenceAndDropsMalformedObservations() async throws {
        let recognizer = StubPeriodicalCoverOCRRecognizer(observations: [
            .init(text: "  Issue 8  \n", confidence: 1.3, boundingBox: .init(x: 0.1, y: 0.8, width: 0.5, height: 0.1)),
            .init(text: "Volume 2", confidence: -0.4, boundingBox: .init(x: 0.1, y: 0.6, width: 0.5, height: 0.1)),
            .init(text: "ignored", confidence: .nan, boundingBox: .init(x: 0.1, y: 0.4, width: 0.5, height: 0.1)),
            .init(text: "   ", confidence: 0.9, boundingBox: .init(x: 0.1, y: 0.2, width: 0.5, height: 0.1)),
            .init(text: "no box", confidence: 0.9, boundingBox: .zero)
        ])
        let service = PeriodicalCoverOCRService(recognizer: recognizer)

        let lines = try await service.recognizeText(in: Self.makeImageData(width: 2, height: 2))

        XCTAssertEqual(lines, [
            .init(text: "Issue 8", confidence: 1),
            .init(text: "Volume 2", confidence: 0)
        ])
    }

    func testReturnsAtMostConfiguredNumberOfLinesAfterReadingOrderSort() async throws {
        let observations = (0..<8).reversed().map { index in
            PeriodicalCoverOCRObservation(
                text: "line-\(index)",
                confidence: 0.8,
                boundingBox: .init(
                    x: 0.1,
                    y: Double(index) / 10,
                    width: 0.4,
                    height: 0.04
                )
            )
        }
        let recognizer = StubPeriodicalCoverOCRRecognizer(observations: observations)
        let service = PeriodicalCoverOCRService(
            recognizer: recognizer,
            configuration: .init(maximumLines: 3)
        )

        let lines = try await service.recognizeText(in: Self.makeImageData(width: 2, height: 2))

        XCTAssertEqual(lines.map(\.text), ["line-7", "line-6", "line-5"])
    }

    func testConfigurationNeverAllowsMoreThanTwoHundredLines() async throws {
        let observations = (0..<240).map { index in
            PeriodicalCoverOCRObservation(
                text: "line-\(index)",
                confidence: 0.8,
                boundingBox: .init(x: 0.1, y: 0.5, width: 0.4, height: 0.04)
            )
        }
        let recognizer = StubPeriodicalCoverOCRRecognizer(observations: observations)
        let service = PeriodicalCoverOCRService(
            recognizer: recognizer,
            configuration: .init(maximumLines: 500)
        )

        let lines = try await service.recognizeText(in: Self.makeImageData(width: 2, height: 2))

        XCTAssertEqual(lines.count, 200)
    }

    func testRejectsEmptyOversizedAndInvalidImageDataBeforeRecognition() async {
        let recognizer = StubPeriodicalCoverOCRRecognizer(observations: [])
        let service = PeriodicalCoverOCRService(
            recognizer: recognizer,
            configuration: .init(maximumInputBytes: 32)
        )

        await assertServiceError(.emptyImage) {
            try await service.recognizeText(in: Data())
        }
        await assertServiceError(.imageTooLarge) {
            try await service.recognizeText(in: Data(repeating: 0, count: 33))
        }
        await assertServiceError(.invalidImage) {
            try await service.recognizeText(in: Data(repeating: 0, count: 12))
        }
        let callCount = await recognizer.recognitionCallCount
        XCTAssertEqual(callCount, 0)
    }

    func testRejectsImageWhosePixelCountExceedsLimit() async throws {
        let recognizer = StubPeriodicalCoverOCRRecognizer(observations: [])
        let service = PeriodicalCoverOCRService(
            recognizer: recognizer,
            configuration: .init(maximumPixelCount: 3)
        )

        await assertServiceError(.pixelCountExceeded) {
            try await service.recognizeText(in: Self.makeImageData(width: 2, height: 2))
        }
        let callCount = await recognizer.recognitionCallCount
        XCTAssertEqual(callCount, 0)
    }

    func testMapsRecognizerErrorsToStableServiceError() async throws {
        let recognizer = StubPeriodicalCoverOCRRecognizer(
            observations: [],
            recognitionError: StubError.expected
        )
        let service = PeriodicalCoverOCRService(recognizer: recognizer)

        await assertServiceError(.recognitionFailed) {
            try await service.recognizeText(in: Self.makeImageData(width: 2, height: 2))
        }
    }

    func testPropagatesCancellationBeforeReadingImage() async {
        let recognizer = StubPeriodicalCoverOCRRecognizer(observations: [])
        let service = PeriodicalCoverOCRService(recognizer: recognizer)

        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await service.recognizeText(in: Data(repeating: 0, count: 1))
        }

        do {
            _ = try await task.value
            XCTFail("Expected CancellationError")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }
        let callCount = await recognizer.recognitionCallCount
        XCTAssertEqual(callCount, 0)
    }

    func testPropagatesCancellationWhileRecognizerIsRunning() async throws {
        let recognizer = SuspendingPeriodicalCoverOCRRecognizer()
        let service = PeriodicalCoverOCRService(recognizer: recognizer)
        let data = try Self.makeImageData(width: 2, height: 2)
        let task = Task { try await service.recognizeText(in: data) }

        await recognizer.waitUntilRecognitionStarts()
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected CancellationError")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }
    }

    private func assertServiceError(
        _ expected: PeriodicalCoverOCRServiceError,
        operation: () async throws -> [PeriodicalRecognizedTextLine],
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await operation()
            XCTFail("Expected \(expected)", file: file, line: line)
        } catch let error as PeriodicalCoverOCRServiceError {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("Unexpected error: \(error)", file: file, line: line)
        }
    }

    private static func makeImageData(width: Int, height: Int) throws -> Data {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let image = context.makeImage() else {
            throw StubError.fixtureCreationFailed
        }

        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            throw StubError.fixtureCreationFailed
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw StubError.fixtureCreationFailed
        }
        return data as Data
    }
}

private actor StubPeriodicalCoverOCRRecognizer: PeriodicalCoverOCRRecognizing {
    let supportedLanguages: [String]
    let observations: [PeriodicalCoverOCRObservation]
    let recognitionError: Error?
    private(set) var receivedLanguages: [String] = []
    private(set) var recognitionCallCount = 0

    init(
        supportedLanguages: [String] = ["pl-PL", "en-US", "de-DE"],
        observations: [PeriodicalCoverOCRObservation],
        recognitionError: Error? = nil
    ) {
        self.supportedLanguages = supportedLanguages
        self.observations = observations
        self.recognitionError = recognitionError
    }

    func supportedRecognitionLanguages() async throws -> [String] {
        supportedLanguages
    }

    func recognize(
        imageData: Data,
        recognitionLanguages: [String]
    ) async throws -> [PeriodicalCoverOCRObservation] {
        recognitionCallCount += 1
        receivedLanguages = recognitionLanguages
        if let recognitionError {
            throw recognitionError
        }
        return observations
    }
}

private actor SuspendingPeriodicalCoverOCRRecognizer: PeriodicalCoverOCRRecognizing {
    private var didStart = false

    func supportedRecognitionLanguages() async throws -> [String] {
        ["pl-PL"]
    }

    func recognize(
        imageData: Data,
        recognitionLanguages: [String]
    ) async throws -> [PeriodicalCoverOCRObservation] {
        didStart = true
        try await Task.sleep(nanoseconds: 30_000_000_000)
        return []
    }

    func waitUntilRecognitionStarts() async {
        while !didStart {
            await Task.yield()
        }
    }
}

private enum StubError: Error {
    case expected
    case fixtureCreationFailed
}
