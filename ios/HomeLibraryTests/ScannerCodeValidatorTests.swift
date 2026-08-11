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
}
