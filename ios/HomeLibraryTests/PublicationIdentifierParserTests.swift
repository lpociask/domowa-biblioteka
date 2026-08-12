import XCTest
@testable import HomeLibrary

final class PublicationIdentifierParserTests: XCTestCase {
    func testNormalizesValidISBN13() {
        let parsed = PublicationIdentifierParser.parse("ISBN 978-0-306-40615-7")

        XCTAssertEqual(parsed.kind, .isbn13)
        XCTAssertTrue(parsed.isValid)
        XCTAssertEqual(parsed.normalized, "9780306406157")
        XCTAssertEqual(parsed.isbn13, "9780306406157")
        XCTAssertNil(parsed.eanSupplement)
    }

    func testConvertsValidISBN10ToISBN13() {
        let parsed = PublicationIdentifierParser.parse("0-306-40615-2")

        XCTAssertEqual(parsed.kind, .isbn10)
        XCTAssertTrue(parsed.isValid)
        XCTAssertEqual(parsed.normalized, "0306406152")
        XCTAssertEqual(parsed.isbn13, "9780306406157")
    }

    func testSupportsISBN10WithXCheckDigit() {
        let parsed = PublicationIdentifierParser.parse("0-9752298-0-X")

        XCTAssertEqual(parsed.kind, .isbn10)
        XCTAssertTrue(parsed.isValid)
        XCTAssertEqual(parsed.isbn13, "9780975229804")
    }

    func testRecognizesNonISBNEAN13() {
        let parsed = PublicationIdentifierParser.parse("5901234123457")

        XCTAssertEqual(parsed.kind, .ean13)
        XCTAssertTrue(parsed.isValid)
        XCTAssertNil(parsed.isbn13)
        XCTAssertNil(parsed.issn)
    }

    func testDerivesISSNFromValid977EAN13() {
        let parsed = PublicationIdentifierParser.parse("9770033248007")

        XCTAssertEqual(parsed.kind, .ean13)
        XCTAssertTrue(parsed.isValid)
        XCTAssertNil(parsed.isbn13)
        XCTAssertEqual(parsed.issn, "0033-2488")
        XCTAssertNil(parsed.eanSupplement)
    }

    func testParsesCanonicalEAN2WithoutPuttingAddonInMainEAN() {
        let parsed = PublicationIdentifierParser.parse("9770033248007+05")

        XCTAssertEqual(parsed.kind, .ean13)
        XCTAssertTrue(parsed.isValid)
        XCTAssertEqual(parsed.normalized, "9770033248007")
        XCTAssertEqual(parsed.issn, "0033-2488")
        XCTAssertEqual(parsed.eanSupplement, "05")
    }

    func testCanonicalizesConcatenatedEAN5IntoSeparateSupplement() {
        let parsed = PublicationIdentifierParser.parse("977003324800712345")

        XCTAssertTrue(parsed.isValid)
        XCTAssertEqual(parsed.normalized, "9770033248007")
        XCTAssertEqual(parsed.eanSupplement, "12345")
    }

    func testInvalidSupplementDoesNotInvalidatePrimaryEAN() {
        let parsed = PublicationIdentifierParser.parse("9770033248007+123")

        XCTAssertTrue(parsed.isValid)
        XCTAssertEqual(parsed.normalized, "9770033248007")
        XCTAssertNil(parsed.eanSupplement)
    }

    func testIgnoresAddonForISBN() {
        let parsed = PublicationIdentifierParser.parse("9780306406157+05")

        XCTAssertEqual(parsed.kind, .isbn13)
        XCTAssertTrue(parsed.isValid)
        XCTAssertEqual(parsed.normalized, "9780306406157")
        XCTAssertEqual(parsed.isbn13, "9780306406157")
        XCTAssertNil(parsed.eanSupplement)
    }

    func testDerivesISSNWithXCheckDigit() {
        let parsed = PublicationIdentifierParser.parse("9771050124008")

        XCTAssertEqual(parsed.kind, .ean13)
        XCTAssertTrue(parsed.isValid)
        XCTAssertEqual(parsed.issn, "1050-124X")
    }

    func testIgnoresVariantDigitsWhenDerivingISSN() {
        let parsed = PublicationIdentifierParser.parse("9770033248427")

        XCTAssertEqual(parsed.kind, .ean13)
        XCTAssertTrue(parsed.isValid)
        XCTAssertEqual(parsed.issn, "0033-2488")
    }

    func testRejects977EAN13WithWrongCheckDigit() {
        let parsed = PublicationIdentifierParser.parse("9770033248008")

        XCTAssertEqual(parsed.kind, .ean13)
        XCTAssertFalse(parsed.isValid)
        XCTAssertNil(parsed.isbn13)
        XCTAssertNil(parsed.issn)
    }

    func testRejectsWrongEANCheckDigit() {
        let parsed = PublicationIdentifierParser.parse("9780306406158")

        XCTAssertEqual(parsed.kind, .isbn13)
        XCTAssertFalse(parsed.isValid)
        XCTAssertNil(parsed.isbn13)
    }

    func testPreservesUnknownQRCodePayload() {
        let parsed = PublicationIdentifierParser.parse("https://example.org/item/123")

        XCTAssertEqual(parsed.kind, .unknown)
        XCTAssertFalse(parsed.isValid)
        XCTAssertEqual(parsed.normalized, "https://example.org/item/123")
    }
}
