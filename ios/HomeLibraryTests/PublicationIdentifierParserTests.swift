import XCTest
@testable import HomeLibrary

final class PublicationIdentifierParserTests: XCTestCase {
    func testNormalizesValidISBN13() {
        let parsed = PublicationIdentifierParser.parse("ISBN 978-0-306-40615-7")

        XCTAssertEqual(parsed.kind, .isbn13)
        XCTAssertTrue(parsed.isValid)
        XCTAssertEqual(parsed.normalized, "9780306406157")
        XCTAssertEqual(parsed.isbn13, "9780306406157")
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
