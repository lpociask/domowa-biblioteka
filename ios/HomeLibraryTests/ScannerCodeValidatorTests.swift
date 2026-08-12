import XCTest
@testable import HomeLibrary

final class ScannerCodeValidatorTests: XCTestCase {
    func testAcceptsValid978ISBN() {
        XCTAssertEqual(
            ScannerCodeValidator.validate("9780306406157"),
            .accepted("9780306406157")
        )
    }

    func testAcceptsValid979ISBN() {
        XCTAssertEqual(
            ScannerCodeValidator.validate("9791090636071"),
            .accepted("9791090636071")
        )
    }

    func testNormalizesDecoratedISBNFromManualField() {
        XCTAssertEqual(
            ScannerCodeValidator.validate("ISBN-13: 978-0-306-40615-7"),
            .accepted("9780306406157")
        )
    }

    func testAcceptsValid977PeriodicalCode() {
        XCTAssertEqual(
            ScannerCodeValidator.validate("9770033248007"),
            .accepted("9770033248007")
        )
    }

    func testCanonicalizesManualEAN2AndEAN5() {
        XCTAssertEqual(
            ScannerCodeValidator.validate("9770033248007 + 05"),
            .accepted("9770033248007+05")
        )
        XCTAssertEqual(
            ScannerCodeValidator.validate("977003324800712345"),
            .accepted("9770033248007+12345")
        )
    }

    func testAcceptsSupplementFromVisionKitPayload() {
        XCTAssertEqual(
            ScannerCodeValidator.validate(
                "9770033248007",
                supplementalPayload: "01",
                source: .ean13
            ),
            .accepted("9770033248007+01")
        )
    }

    func testIgnoresInvalidVisionSupplementWithoutInvalidatingPrimary() {
        XCTAssertEqual(
            ScannerCodeValidator.validate(
                "9770033248007",
                supplementalPayload: "123",
                source: .ean13
            ),
            .accepted("9770033248007")
        )
    }

    func testRejectsMalformedSupplementEnteredExplicitly() {
        XCTAssertEqual(
            ScannerCodeValidator.validate("9770033248007+123"),
            .rejected(ScannerCodeValidator.supplementMessage)
        )
        XCTAssertEqual(
            ScannerCodeValidator.validate("9770033248007+12+345"),
            .rejected(ScannerCodeValidator.supplementMessage)
        )
    }

    func testIgnoresAddonForISBN() {
        XCTAssertEqual(
            ScannerCodeValidator.validate("9780306406157+05"),
            .accepted("9780306406157")
        )
    }

    func testRejectsOrdinaryEANWithPublicationSpecificMessage() {
        XCTAssertEqual(
            ScannerCodeValidator.validate("5901234123457"),
            .rejected(ScannerCodeValidator.unsupportedEANMessage)
        )
    }

    func testRejectsISBNWithWrongCheckDigit() {
        XCTAssertEqual(
            ScannerCodeValidator.validate("9780306406158"),
            .rejected(ScannerCodeValidator.checksumMessage)
        )
    }

    func testRejectsUPCAndISBN10() {
        XCTAssertEqual(
            ScannerCodeValidator.validate("04210005"),
            .rejected(ScannerCodeValidator.formatMessage)
        )
        XCTAssertEqual(
            ScannerCodeValidator.validate("0306406152"),
            .rejected(ScannerCodeValidator.formatMessage)
        )
    }

    func testRejectsQRCodeURLEvenWhenItContainsAValidISBN() {
        XCTAssertEqual(
            ScannerCodeValidator.validate(
                "https://example.org/books/9780306406157",
                source: .qr
            ),
            .rejected(ScannerCodeValidator.unsupportedQRMessage)
        )
    }

    func testAcceptsQRCodeOnlyWhenPayloadIsAValidISBN() {
        XCTAssertEqual(
            ScannerCodeValidator.validate("ISBN 978-0-306-40615-7", source: .qr),
            .accepted("9780306406157")
        )
    }

    func testRejectsPeriodicalCodeStoredInQRCode() {
        XCTAssertEqual(
            ScannerCodeValidator.validate("9770033248007", source: .qr),
            .rejected(ScannerCodeValidator.unsupportedQRMessage)
        )
    }

    func testRejectsEmptyManualValue() {
        XCTAssertEqual(
            ScannerCodeValidator.validate("   \n"),
            .rejected(ScannerCodeValidator.emptyMessage)
        )
    }

    func testRepeatGateSuppressesImmediateSameCodeUntilItLeavesFrame() {
        let start = Date(timeIntervalSince1970: 100)
        var gate = ScannerRepeatGate(
            suppressedCode: "9780306406157",
            now: start,
            graceInterval: 2
        )

        XCTAssertFalse(gate.shouldAccept("9780306406157", now: start.addingTimeInterval(0.1)))
        gate.updateVisibleCodes(["9780306406157"])
        XCTAssertFalse(gate.shouldAccept("9780306406157", now: start.addingTimeInterval(0.5)))

        gate.updateVisibleCodes([])

        XCTAssertTrue(gate.shouldAccept("9780306406157", now: start.addingTimeInterval(0.6)))
        XCTAssertNil(gate.suppressedCode)
    }

    func testRepeatGateAllowsAnotherCodeAndExpiresWhenPreviousWasNotVisible() {
        let start = Date(timeIntervalSince1970: 100)
        var gate = ScannerRepeatGate(
            suppressedCode: "9780306406157",
            now: start,
            graceInterval: 2
        )

        XCTAssertTrue(gate.shouldAccept("9791090636071", now: start.addingTimeInterval(0.1)))
        XCTAssertTrue(gate.shouldAccept("9780306406157", now: start.addingTimeInterval(2)))
        XCTAssertNil(gate.suppressedCode)
    }

    func testRepeatGateTreatsCanonicalSupplementsAsDistinctCodes() {
        let start = Date(timeIntervalSince1970: 100)
        var gate = ScannerRepeatGate(
            suppressedCode: "9770033248007+01",
            now: start,
            graceInterval: 2
        )

        XCTAssertFalse(gate.shouldAccept("9770033248007+01", now: start.addingTimeInterval(0.1)))
        XCTAssertTrue(gate.shouldAccept("9770033248007+02", now: start.addingTimeInterval(0.1)))
    }

    func testRepeatGateTreatsSamePeriodicalMainAndSupplementAsOneVisibleObject() {
        let start = Date(timeIntervalSince1970: 100)
        var fullToMain = ScannerRepeatGate(
            suppressedCode: "9770033248007+01",
            now: start,
            graceInterval: 2
        )
        var mainToFull = ScannerRepeatGate(
            suppressedCode: "9770033248007",
            now: start,
            graceInterval: 2
        )

        XCTAssertFalse(
            fullToMain.shouldAccept("9770033248007", now: start.addingTimeInterval(0.1))
        )
        XCTAssertFalse(
            mainToFull.shouldAccept("9770033248007+01", now: start.addingTimeInterval(0.1))
        )

        fullToMain.updateVisibleCodes(["9770033248007"])
        mainToFull.updateVisibleCodes(["9770033248007+01"])
        XCTAssertNotNil(fullToMain.suppressedCode)
        XCTAssertNotNil(mainToFull.suppressedCode)
    }

    func testSupplementAccumulatorEmitsEAN2FromUpdateExactlyOnce() {
        let start = Date(timeIntervalSince1970: 100)
        var accumulator = ScannerEANSupplementAccumulator(waitInterval: 0.45)

        XCTAssertEqual(
            accumulator.observe(
                canonicalCode: "9770033248007",
                supplementalPayload: nil,
                now: start
            ),
            .wait(until: start.addingTimeInterval(0.45))
        )
        XCTAssertEqual(
            accumulator.observe(
                canonicalCode: "9770033248007",
                supplementalPayload: "05",
                now: start.addingTimeInterval(0.2)
            ),
            .emit("9770033248007+05")
        )
        XCTAssertEqual(
            accumulator.resolveTimeout(now: start.addingTimeInterval(1)),
            .ignore
        )
        XCTAssertEqual(
            accumulator.observe(
                canonicalCode: "9770033248007",
                supplementalPayload: "05",
                now: start.addingTimeInterval(1)
            ),
            .ignore
        )
    }

    func testSupplementAccumulatorFallsBackToPrimaryAfterTimeoutExactlyOnce() {
        let start = Date(timeIntervalSince1970: 100)
        var accumulator = ScannerEANSupplementAccumulator(waitInterval: 0.45)

        _ = accumulator.observe(
            canonicalCode: "9770033248007",
            supplementalPayload: "invalid",
            now: start
        )
        XCTAssertEqual(
            accumulator.resolveTimeout(now: start.addingTimeInterval(0.44)),
            .wait(until: start.addingTimeInterval(0.45))
        )
        XCTAssertEqual(
            accumulator.resolveTimeout(now: start.addingTimeInterval(0.45)),
            .emit("9770033248007")
        )
        XCTAssertEqual(
            accumulator.resolveTimeout(now: start.addingTimeInterval(0.9)),
            .ignore
        )
    }

    func testSupplementAccumulatorDoesNotDelayISBN() {
        var accumulator = ScannerEANSupplementAccumulator()

        XCTAssertEqual(
            accumulator.observe(
                canonicalCode: "9780306406157",
                supplementalPayload: "05"
            ),
            .emit("9780306406157")
        )
    }

    func testSupplementAccumulatorReplacesPendingDifferentPrimary() {
        let start = Date(timeIntervalSince1970: 100)
        var accumulator = ScannerEANSupplementAccumulator(waitInterval: 0.45)

        XCTAssertEqual(
            accumulator.observe(
                canonicalCode: "9770033248007",
                supplementalPayload: nil,
                now: start
            ),
            .wait(until: start.addingTimeInterval(0.45))
        )
        guard case .wait(let replacementDeadline) = accumulator.observe(
            canonicalCode: "9771234567003",
            supplementalPayload: nil,
            now: start.addingTimeInterval(0.1)
        ) else {
            return XCTFail("Nowy kod powinien dostać własne okno na dodatek")
        }
        XCTAssertEqual(
            replacementDeadline.timeIntervalSince1970,
            100.55,
            accuracy: 0.000_001
        )
        guard case .wait(let retainedDeadline) = accumulator.resolveTimeout(
            now: start.addingTimeInterval(0.45)
        ) else {
            return XCTFail("Przed deadlinem akumulator powinien nadal czekać")
        }
        XCTAssertEqual(
            retainedDeadline.timeIntervalSince1970,
            replacementDeadline.timeIntervalSince1970,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            accumulator.resolveTimeout(now: start.addingTimeInterval(0.56)),
            .emit("9771234567003")
        )
    }

    func testSupplementAccumulatorCancelsPendingCodeAfterItLeavesFrame() {
        let start = Date(timeIntervalSince1970: 100)
        var accumulator = ScannerEANSupplementAccumulator(waitInterval: 0.45)
        _ = accumulator.observe(
            canonicalCode: "9770033248007",
            supplementalPayload: nil,
            now: start
        )

        XCTAssertFalse(
            accumulator.cancelIfPendingCodeIsNotVisible(["9770033248007+05"])
        )
        XCTAssertTrue(accumulator.cancelIfPendingCodeIsNotVisible([]))
        XCTAssertEqual(
            accumulator.resolveTimeout(now: start.addingTimeInterval(1)),
            .ignore
        )
    }
}
