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
        XCTAssertEqual(match.copyCountAtCurrentLocation, 0)
        XCTAssertEqual(match.kind, .anotherCopy)
    }

    func testClassifiesSameBookAtCurrentShelfAsPossibleRepeatAndCountsCopies() throws {
        let publication = Publication(
            type: .book,
            title: "Testowa książka",
            isbn13: "9780306406157"
        )
        let firstAtShelf = OwnedItem(
            publication: publication,
            locationPathText: "Dom / Gabinet / Regał 2 / Półka 3"
        )
        let secondAtShelf = OwnedItem(
            publication: publication,
            locationPathText: "Dom / Gabinet / Regał 2 / Półka 3"
        )
        let elsewhere = OwnedItem(
            publication: publication,
            locationPathText: "Dom / Salon / Regał 1"
        )

        let match = try XCTUnwrap(ExistingPublicationMatcher.match(
            in: [firstAtShelf, secondAtShelf, elsewhere],
            type: .book,
            isbn13: "978-0-306-40615-7",
            issn: "",
            ean: "",
            issueNumber: "",
            issueDate: "",
            locationPath: LocationPath("Dom / Gabinet / Regał 2 / Półka 3")
        ))

        XCTAssertEqual(match.kind, .possibleRepeatScan)
        XCTAssertEqual(match.copyCount, 3)
        XCTAssertEqual(match.copyCountAtCurrentLocation, 2)
    }

    func testClassifiesSameBookAtDifferentShelfAsAnotherCopy() throws {
        let publication = Publication(
            type: .book,
            title: "Testowa książka",
            isbn13: "9780306406157"
        )
        let item = OwnedItem(
            publication: publication,
            locationPathText: "Dom / Gabinet / Regał 2 / Półka 3"
        )

        let match = try XCTUnwrap(ExistingPublicationMatcher.match(
            in: [item],
            type: .book,
            isbn13: "9780306406157",
            issn: "",
            ean: "",
            issueNumber: "",
            issueDate: "",
            locationPath: LocationPath("Dom / Gabinet / Regał 2 / Półka 4")
        ))

        XCTAssertEqual(match.kind, .anotherCopy)
        XCTAssertEqual(match.copyCount, 1)
        XCTAssertEqual(match.copyCountAtCurrentLocation, 0)
    }

    func testLocationComparisonNormalizesSeparatorsCaseAndDiacritics() throws {
        let publication = Publication(
            type: .book,
            title: "Testowa książka",
            isbn13: "9780306406157"
        )
        let item = OwnedItem(
            publication: publication,
            locationPathText: "Dom / Gabinet / Regał 2 / Półka 3"
        )

        let match = try XCTUnwrap(ExistingPublicationMatcher.match(
            in: [item],
            type: .book,
            isbn13: "9780306406157",
            issn: "",
            ean: "",
            issueNumber: "",
            issueDate: "",
            locationPath: LocationPath("dom › GABINET › REGAL 2 › polka 3")
        ))

        XCTAssertEqual(match.kind, .possibleRepeatScan)
        XCTAssertEqual(match.copyCountAtCurrentLocation, 1)
    }

    func testEmptyCurrentLocationIsAlwaysClassifiedAsAnotherCopy() throws {
        let publication = Publication(
            type: .book,
            title: "Testowa książka",
            isbn13: "9780306406157"
        )
        let itemWithoutLocation = OwnedItem(publication: publication, locationPathText: "")

        let match = try XCTUnwrap(ExistingPublicationMatcher.match(
            in: [itemWithoutLocation],
            type: .book,
            isbn13: "9780306406157",
            issn: "",
            ean: "",
            issueNumber: "",
            issueDate: ""
        ))

        XCTAssertEqual(match.kind, .anotherCopy)
        XCTAssertEqual(match.copyCount, 1)
        XCTAssertEqual(match.copyCountAtCurrentLocation, 0)
    }

    func testAggregatesLegacyDuplicatePublicationRecordsAndChoosesDeterministically() throws {
        let canonical = Publication(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            type: .book,
            title: "Pierwszy rekord",
            isbn13: "9780306406157"
        )
        let duplicate = Publication(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
            type: .book,
            title: "Duplikat z importu",
            isbn13: "9780306406157"
        )
        let first = OwnedItem(
            publication: canonical,
            locationPathText: "Dom / Gabinet / Półka 1"
        )
        let second = OwnedItem(
            publication: duplicate,
            locationPathText: "Dom / Gabinet / Półka 1"
        )
        let location = LocationPath("Dom / Gabinet / Półka 1")

        let forward = try XCTUnwrap(ExistingPublicationMatcher.match(
            in: [second, first],
            type: .book,
            isbn13: "9780306406157",
            issn: "",
            ean: "",
            issueNumber: "",
            issueDate: "",
            locationPath: location
        ))
        let reverse = try XCTUnwrap(ExistingPublicationMatcher.match(
            in: [first, second],
            type: .book,
            isbn13: "9780306406157",
            issn: "",
            ean: "",
            issueNumber: "",
            issueDate: "",
            locationPath: location
        ))

        XCTAssertEqual(forward.publication.id, canonical.id)
        XCTAssertEqual(reverse.publication.id, canonical.id)
        XCTAssertEqual(forward.copyCount, 2)
        XCTAssertEqual(forward.copyCountAtCurrentLocation, 2)
        XCTAssertEqual(forward.kind, .possibleRepeatScan)
    }

    func testNonOwnedCopiesDoNotTriggerSameShelfWarning() throws {
        let publication = Publication(
            type: .book,
            title: "Testowa książka",
            isbn13: "9780306406157"
        )
        let location = "Dom / Gabinet / Półka 1"
        let loaned = OwnedItem(publication: publication, locationPathText: location, status: .loaned)
        let missing = OwnedItem(publication: publication, locationPathText: location, status: .missing)
        let archived = OwnedItem(publication: publication, locationPathText: location, status: .archived)

        let match = try XCTUnwrap(ExistingPublicationMatcher.match(
            in: [loaned, missing, archived],
            type: .book,
            isbn13: "9780306406157",
            issn: "",
            ean: "",
            issueNumber: "",
            issueDate: "",
            locationPath: LocationPath(location)
        ))

        XCTAssertEqual(match.copyCount, 3)
        XCTAssertEqual(match.copyCountAtCurrentLocation, 0)
        XCTAssertEqual(match.kind, .anotherCopy)
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

    func testMatchesPeriodicalByExactEAN977AndSupplementWithoutIssueFields() throws {
        let publication = Publication(
            type: .periodical,
            title: "Miesięcznik",
            ean: "9770033248007",
            barcode: "9770033248007+05"
        )
        let item = OwnedItem(publication: publication, locationPathText: "Salon / Stolik")

        let match = try XCTUnwrap(ExistingPublicationMatcher.match(
            in: [item],
            type: .periodical,
            isbn13: "",
            issn: "",
            ean: "9770033248007",
            barcode: "9770033248007+05",
            issueNumber: "",
            issueDate: "",
            locationPath: LocationPath("Salon / Stolik")
        ))

        XCTAssertEqual(match.publication.id, publication.id)
        XCTAssertEqual(match.kind, .possibleRepeatScan)
    }

    func testExactSupplementDoesNotOverrideConflictingIssueFields() {
        let publication = Publication(
            type: .periodical,
            title: "Miesięcznik",
            ean: "9770033248007",
            barcode: "9770033248007+05",
            issueNumber: "5/2025",
            issueDate: "2025-05"
        )

        XCTAssertNil(ExistingPublicationMatcher.match(
            in: [OwnedItem(publication: publication, locationPathText: "")],
            type: .periodical,
            isbn13: "",
            issn: "",
            ean: "9770033248007",
            barcode: "9770033248007+05",
            issueNumber: "5/2026",
            issueDate: "2026-05"
        ))
    }

    func testDoesNotMergeFallbackWhenExplicitPeriodicalMainEANsConflict() {
        let publication = Publication(
            type: .periodical,
            title: "Miesięcznik",
            issn: "0033-2488",
            ean: "9770033248007",
            barcode: "9770033248007",
            issueNumber: "8/2026"
        )

        XCTAssertNil(ExistingPublicationMatcher.match(
            in: [OwnedItem(publication: publication, locationPathText: "")],
            type: .periodical,
            isbn13: "",
            issn: "0033-2488",
            ean: "9771234567003",
            barcode: "9771234567003+05",
            issueNumber: "8/2026",
            issueDate: ""
        ))
    }

    func testDoesNotMergePeriodicalsWithDifferentNonemptySupplements() {
        let publication = Publication(
            type: .periodical,
            title: "Miesięcznik",
            issn: "0033-2488",
            ean: "9770033248007",
            barcode: "9770033248007+05",
            issueNumber: "8/2026",
            issueDate: "2026-08"
        )

        XCTAssertNil(ExistingPublicationMatcher.match(
            in: [OwnedItem(publication: publication, locationPathText: "")],
            type: .periodical,
            isbn13: "",
            issn: "0033-2488",
            ean: "9770033248007",
            barcode: "9770033248007+06",
            issueNumber: "8/2026",
            issueDate: "2026-08"
        ))
    }

    func testFallsBackToISSNAndIssueWhenOnlyOnePeriodicalHasSupplement() throws {
        let publication = Publication(
            type: .periodical,
            title: "Miesięcznik",
            issn: "0033-2488",
            ean: "9770033248007",
            barcode: "9770033248007",
            issueNumber: "8/2026"
        )

        let match = try XCTUnwrap(ExistingPublicationMatcher.match(
            in: [OwnedItem(publication: publication, locationPathText: "")],
            type: .periodical,
            isbn13: "",
            issn: "0033-2488",
            ean: "9770033248007",
            barcode: "9770033248007+12345",
            issueNumber: "8/2026",
            issueDate: ""
        ))

        XCTAssertEqual(match.publication.id, publication.id)
    }

    func testBaseEAN977AloneDoesNotIdentifyPeriodicalIssue() {
        let publication = Publication(
            type: .periodical,
            title: "Miesięcznik",
            ean: "9770033248007",
            barcode: "9770033248007"
        )

        XCTAssertNil(ExistingPublicationMatcher.match(
            in: [OwnedItem(publication: publication, locationPathText: "")],
            type: .periodical,
            isbn13: "",
            issn: "",
            ean: "9770033248007",
            barcode: "9770033248007",
            issueNumber: "",
            issueDate: ""
        ))
    }

    func testBookMatchingIgnoresBarcodeSupplement() throws {
        let publication = Publication(
            type: .book,
            title: "Książka",
            isbn13: "9780306406157",
            barcode: "9780306406157+05"
        )

        let match = try XCTUnwrap(ExistingPublicationMatcher.match(
            in: [OwnedItem(publication: publication, locationPathText: "")],
            type: .book,
            isbn13: "9780306406157",
            issn: "",
            ean: "",
            barcode: "9780306406157+06",
            issueNumber: "",
            issueDate: ""
        ))

        XCTAssertEqual(match.publication.id, publication.id)
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
