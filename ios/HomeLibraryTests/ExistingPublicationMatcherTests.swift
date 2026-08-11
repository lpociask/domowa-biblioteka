import XCTest
@testable import HomeLibrary

@MainActor
final class ExistingPublicationMatcherTests: XCTestCase {
    func testMatchesBookByNormalizedISBNAndCountsCopies() throws {
        let publication = Publication(
            type: .book,
            title: "Testowa książka",
            isbn13: "9780306406157"
        )
        let first = OwnedItem(publication: publication, locationPathText: "Dom / Regał")
        let second = OwnedItem(publication: publication, locationPathText: "Biuro / Półka")

        let match = try XCTUnwrap(ExistingPublicationMatcher.match(
            in: [first, second],
            type: .book,
            isbn13: "978-0-306-40615-7",
            issn: "",
            ean: "",
            issueNumber: "",
            issueDate: ""
        ))

        XCTAssertEqual(match.publication.id, publication.id)
        XCTAssertEqual(match.copyCount, 2)
    }

    func testDoesNotMergeBooksOnlyByTitle() {
        let publication = Publication(type: .book, title: "Ten sam tytuł")
        let item = OwnedItem(publication: publication, locationPathText: "")

        XCTAssertNil(ExistingPublicationMatcher.match(
            in: [item],
            type: .book,
            isbn13: "",
            issn: "",
            ean: "",
            issueNumber: "",
            issueDate: ""
        ))
    }

    func testDoesNotMergePeriodicalWhenOnlyISSNIsKnown() {
        let publication = Publication(
            type: .periodical,
            title: "Miesięcznik",
            issn: "0033-248X",
            issueNumber: "8/2026"
        )
        let item = OwnedItem(publication: publication, locationPathText: "")

        XCTAssertNil(ExistingPublicationMatcher.match(
            in: [item],
            type: .periodical,
            isbn13: "",
            issn: "0033-248X",
            ean: "9770033248007",
            issueNumber: "",
            issueDate: ""
        ))
    }

    func testMatchesConcretePeriodicalIssueByISSNAndIssueNumber() throws {
        let publication = Publication(
            type: .periodical,
            title: "Miesięcznik",
            issn: "0033-248X",
            issueNumber: "8/2026",
            issueDate: "2026-08"
        )
        let item = OwnedItem(publication: publication, locationPathText: "")

        let match = try XCTUnwrap(ExistingPublicationMatcher.match(
            in: [item],
            type: .periodical,
            isbn13: "",
            issn: "0033248X",
            ean: "9770033248007",
            issueNumber: "8/2026",
            issueDate: ""
        ))

        XCTAssertEqual(match.publication.id, publication.id)
        XCTAssertEqual(match.copyCount, 1)
    }

    func testDoesNotMergeDifferentPeriodicalIssue() {
        let publication = Publication(
            type: .periodical,
            title: "Miesięcznik",
            issn: "0033-248X",
            issueNumber: "7/2026"
        )
        let item = OwnedItem(publication: publication, locationPathText: "")

        XCTAssertNil(ExistingPublicationMatcher.match(
            in: [item],
            type: .periodical,
            isbn13: "",
            issn: "0033-248X",
            ean: "",
            issueNumber: "8/2026",
            issueDate: ""
        ))
    }

    func testMatchesPeriodicalWhenSharedIssueMatchesAndOnlyOneSideHasDate() throws {
        let withoutDate = Publication(
            type: .periodical,
            title: "Miesięcznik",
            issn: "0033-248X",
            issueNumber: "8/2026"
        )
        let withDate = Publication(
            type: .periodical,
            title: "Miesięcznik",
            issn: "0033-248X",
            issueNumber: "8/2026",
            issueDate: "2026-08"
        )

        let matchForward = try XCTUnwrap(ExistingPublicationMatcher.match(
            in: [OwnedItem(publication: withoutDate, locationPathText: "")],
            type: .periodical,
            isbn13: "",
            issn: "0033-248X",
            ean: "",
            issueNumber: "8/2026",
            issueDate: "2026-08"
        ))
        let matchReverse = try XCTUnwrap(ExistingPublicationMatcher.match(
            in: [OwnedItem(publication: withDate, locationPathText: "")],
            type: .periodical,
            isbn13: "",
            issn: "0033-248X",
            ean: "",
            issueNumber: "8/2026",
            issueDate: ""
        ))

        XCTAssertEqual(matchForward.publication.id, withoutDate.id)
        XCTAssertEqual(matchReverse.publication.id, withDate.id)
    }

    func testDoesNotMergePeriodicalWhenSharedIssueMatchesButDatesConflict() {
        let publication = Publication(
            type: .periodical,
            title: "Miesięcznik",
            issn: "0033-248X",
            issueNumber: "8/2026",
            issueDate: "2026-07"
        )

        XCTAssertNil(ExistingPublicationMatcher.match(
            in: [OwnedItem(publication: publication, locationPathText: "")],
            type: .periodical,
            isbn13: "",
            issn: "0033-248X",
            ean: "",
            issueNumber: "8/2026",
            issueDate: "2026-08"
        ))
    }
}
