import SwiftUI
import XCTest
@testable import HomeLibrary

@MainActor
final class CoverPhotoCaptureViewTests: XCTestCase {
    func testStateCompletesReplacementAndRemoval() {
        var state = CoverPhotoCaptureState()

        XCTAssertFalse(state.hasImage)
        XCTAssertFalse(state.isProcessing)

        state.begin(.photoLibrary)
        XCTAssertTrue(state.isProcessing)
        XCTAssertEqual(state.activity, .processing(.photoLibrary))

        state.complete()
        XCTAssertTrue(state.hasImage)
        XCTAssertEqual(state.activity, .idle)

        state.remove()
        XCTAssertFalse(state.hasImage)
        XCTAssertEqual(state.activity, .idle)
    }

    func testFailureKeepsExistingPreviewUntilExplicitRemoval() {
        var state = CoverPhotoCaptureState(hasImage: true)

        state.begin(.camera)
        state.fail("Błąd testowy")

        XCTAssertTrue(state.hasImage)
        XCTAssertEqual(state.failureMessage, "Błąd testowy")

        state.dismissFailure()
        XCTAssertTrue(state.hasImage)
        XCTAssertEqual(state.activity, .idle)
    }

    func testTransferPolicyAcceptsBoundaryAndRejectsUnsafeInputs() throws {
        XCTAssertNoThrow(try CoverPhotoCapturePolicy.validateTransfer(byteCount: 1))
        XCTAssertNoThrow(try CoverPhotoCapturePolicy.validateTransfer(
            byteCount: CoverPhotoCapturePolicy.maximumTransferBytes,
            isRegularFile: nil
        ))

        XCTAssertThrowsError(try CoverPhotoCapturePolicy.validateTransfer(byteCount: 0)) { error in
            XCTAssertEqual(error as? CoverPhotoCaptureInputError, .empty)
        }
        XCTAssertThrowsError(try CoverPhotoCapturePolicy.validateTransfer(
            byteCount: 128,
            isRegularFile: false
        )) { error in
            XCTAssertEqual(error as? CoverPhotoCaptureInputError, .notARegularFile)
        }
        XCTAssertThrowsError(try CoverPhotoCapturePolicy.validateTransfer(
            byteCount: CoverPhotoCapturePolicy.maximumTransferBytes + 1
        )) { error in
            XCTAssertEqual(error as? CoverPhotoCaptureInputError, .inputTooLarge)
        }
    }

    func testCameraTargetSizePreservesAspectRatioAndCapsLongestSide() throws {
        XCTAssertEqual(
            try CoverPhotoCapturePolicy.cameraTargetSize(pixelWidth: 1_600, pixelHeight: 1_200),
            .init(width: 1_600, height: 1_200)
        )
        XCTAssertEqual(
            try CoverPhotoCapturePolicy.cameraTargetSize(pixelWidth: 4_032, pixelHeight: 3_024),
            .init(width: 1_600, height: 1_200)
        )
        XCTAssertEqual(
            try CoverPhotoCapturePolicy.cameraTargetSize(pixelWidth: 3_024, pixelHeight: 4_032),
            .init(width: 1_200, height: 1_600)
        )
    }

    func testCameraTargetSizeRejectsEmptyOverflowAndMoreThanFiftyMegapixels() {
        for dimensions in [(0, 100), (10_000, 6_000), (Int.max, 2)] {
            XCTAssertThrowsError(try CoverPhotoCapturePolicy.cameraTargetSize(
                pixelWidth: dimensions.0,
                pixelHeight: dimensions.1
            ))
        }
    }

    func testViewCanBeConstructedForCompactAccessibilityLayout() {
        let view = CoverPhotoCaptureView(existingImageData: nil) { _ in }
            .environment(\.horizontalSizeClass, .compact)
            .environment(\.dynamicTypeSize, .accessibility5)

        XCTAssertNotNil(view)
    }
}
