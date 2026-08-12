import XCTest
@testable import HomeLibrary

final class PeriodicalSeriesPrefillTests: XCTestCase {
    func testSeparateIssueResetClearsEveryIssueDiscriminatorAndRetainsOnlyMainEAN977() {
        let reset = PeriodicalIssueDraftReset.clearedIdentity(
            retainingSeriesEAN: "9770033248007+05"
        )

        XCTAssertEqual(reset.barcode, "9770033248007")
        XCTAssertEqual(reset.eanSupplement, "")
        XCTAssertEqual(reset.issueNumber, "")
        XCTAssertEqual(reset.issueVolume, "")
        XCTAssertEqual(reset.issueDate, "")
    }

    func testSeparateIssueResetDoesNotRetainInvalidOrNonPeriodicalEAN() {
        XCTAssertEqual(
            PeriodicalIssueDraftReset.clearedIdentity(
                retainingSeriesEAN: "9788325572280"
            ).barcode,
            ""
        )
        XCTAssertEqual(
            PeriodicalIssueDraftReset.clearedIdentity(
                retainingSeriesEAN: "9770033248008"
            ).barcode,
            ""
        )
    }

    func testReturnsOnlySeriesBibliographicFieldsForNormalizedExplicitISSN() throws {
        let publication = makePublication(
            id: 1,
            title: "Miesięcznik",
            subtitle: "Nauka i kultura",
            authors: "Redakcja A; Redakcja B",
            language: "pl",
            publisher: "Wydawnictwo",
            issn: "0033-2488",
            issueNumber: "7/2026",
            issueVolume: "XLII",
            issueDate: "2026-07",
            barcode: "9770033248007+07"
        )

        let result = try XCTUnwrap(PeriodicalSeriesPrefillResolver.prefill(
            in: [makeItem(publication)],
            incomingISSN: " 00332488 ",
            incomingEAN: ""
        ))

        XCTAssertEqual(result.title, "Miesięcznik")
        XCTAssertEqual(result.subtitle, "Nauka i kultura")
        XCTAssertEqual(result.authors, "Redakcja A; Redakcja B")
        XCTAssertEqual(result.language, "pl")
        XCTAssertEqual(result.publisher, "Wydawnictwo")
        XCTAssertEqual(
            Set(Mirror(reflecting: result).children.compactMap(\.label)),
            Set(["title", "subtitle", "authors", "language", "publisher"])
        )
    }

    func testIgnoresBookEvenWhenItsISSNMatches() {
        let book = makePublication(id: 1, type: .book, issn: "0033-2488")

        XCTAssertNil(PeriodicalSeriesPrefillResolver.prefill(
            in: [makeItem(book)],
            incomingISSN: "0033-2488",
            incomingEAN: ""
        ))
    }

    func testMatchesIncomingEAN977ToExistingExplicitISSN() throws {
        let publication = makePublication(id: 1, title: "Seria z ISSN", issn: "0033-2488")

        let result = try XCTUnwrap(PeriodicalSeriesPrefillResolver.prefill(
            in: [makeItem(publication)],
            incomingISSN: "",
            incomingEAN: "9770033248007+05"
        ))

        XCTAssertEqual(result.title, "Seria z ISSN")
    }

    func testMatchesIncomingISSNToExistingEANOrCompositeBarcode() throws {
        let fromEAN = makePublication(
            id: 1,
            title: "EAN",
            ean: "9770033248014"
        )
        let fromBarcode = makePublication(
            id: 2,
            title: "Barcode",
            barcode: "9770033248007+08",
            updatedAt: Date(timeIntervalSince1970: 200)
        )

        let result = try XCTUnwrap(PeriodicalSeriesPrefillResolver.prefill(
            in: [makeItem(fromEAN), makeItem(fromBarcode)],
            incomingISSN: "0033-2488",
            incomingEAN: ""
        ))

        XCTAssertEqual(result.title, "Barcode")
    }

    func testExactValidISSNWinsOverNewerDerivedCandidate() throws {
        let exact = makePublication(
            id: 2,
            title: "Jawny ISSN",
            issn: "0033-2488",
            updatedAt: Date(timeIntervalSince1970: 100)
        )
        let newerDerived = makePublication(
            id: 1,
            title: "Tylko EAN",
            ean: "9770033248007",
            updatedAt: Date(timeIntervalSince1970: 300)
        )

        let result = try XCTUnwrap(PeriodicalSeriesPrefillResolver.prefill(
            in: [makeItem(newerDerived), makeItem(exact)],
            incomingISSN: "",
            incomingEAN: "9770033248007"
        ))

        XCTAssertEqual(result.title, "Jawny ISSN")
    }

    func testNewestUpdatedAtWinsWithinTheSameEvidenceLevel() throws {
        let older = makePublication(
            id: 1,
            title: "Starszy opis",
            issn: "0033-2488",
            updatedAt: Date(timeIntervalSince1970: 100)
        )
        let newer = makePublication(
            id: 2,
            title: "Nowszy opis",
            issn: "0033-2488",
            updatedAt: Date(timeIntervalSince1970: 200)
        )

        let result = try XCTUnwrap(PeriodicalSeriesPrefillResolver.prefill(
            in: [makeItem(older), makeItem(newer)],
            incomingISSN: "0033-2488",
            incomingEAN: ""
        ))

        XCTAssertEqual(result.title, "Nowszy opis")
    }

    func testStableUUIDBreaksTimestampTieRegardlessOfInputOrder() throws {
        let lowerUUID = makePublication(id: 1, title: "Niższy UUID", issn: "0033-2488")
        let higherUUID = makePublication(id: 2, title: "Wyższy UUID", issn: "0033-2488")

        let forward = try XCTUnwrap(PeriodicalSeriesPrefillResolver.prefill(
            in: [makeItem(higherUUID), makeItem(lowerUUID)],
            incomingISSN: "0033-2488",
            incomingEAN: ""
        ))
        let reverse = try XCTUnwrap(PeriodicalSeriesPrefillResolver.prefill(
            in: [makeItem(lowerUUID), makeItem(higherUUID)],
            incomingISSN: "0033-2488",
            incomingEAN: ""
        ))

        XCTAssertEqual(forward.title, "Niższy UUID")
        XCTAssertEqual(reverse, forward)
    }

    func testValidExplicitISSNIsAuthoritativeOverConflictingEAN() throws {
        let exactDespiteConflict = makePublication(
            id: 2,
            title: "Jawny identyfikator",
            issn: "0033-2488",
            ean: "9771050124008"
        )
        let eanOnly = makePublication(
            id: 1,
            title: "Kod z konfliktu",
            ean: "9771050124008",
            updatedAt: Date(timeIntervalSince1970: 500)
        )

        let result = try XCTUnwrap(PeriodicalSeriesPrefillResolver.prefill(
            in: [makeItem(eanOnly), makeItem(exactDespiteConflict)],
            incomingISSN: "0033-2488",
            incomingEAN: "9771050124008"
        ))

        XCTAssertEqual(result.title, "Jawny identyfikator")
    }

    func testRejectsCandidateWhoseValidExplicitISSNDisagreesEvenWhenEANMatches() {
        let conflicting = makePublication(
            id: 1,
            issn: "1050-124X",
            ean: "9770033248007"
        )

        XCTAssertNil(PeriodicalSeriesPrefillResolver.prefill(
            in: [makeItem(conflicting)],
            incomingISSN: "0033-2488",
            incomingEAN: ""
        ))
    }

    func testInvalidISSNRequiresUsableEAN977AndAmbiguousCandidateEANsAreRejected() {
        let ambiguous = makePublication(
            id: 1,
            issn: "0033-2487",
            ean: "9770033248007",
            barcode: "9771050124008+05"
        )

        XCTAssertNil(PeriodicalSeriesPrefillResolver.prefill(
            in: [makeItem(ambiguous)],
            incomingISSN: "0033-2487",
            incomingEAN: ""
        ))
        XCTAssertNil(PeriodicalSeriesPrefillResolver.prefill(
            in: [makeItem(ambiguous)],
            incomingISSN: "0033-2488",
            incomingEAN: ""
        ))
    }

    private func makePublication(
        id: Int,
        type: PublicationType = .periodical,
        title: String = "Tytuł",
        subtitle: String = "",
        authors: String = "",
        language: String = "",
        publisher: String = "",
        issn: String = "",
        ean: String = "",
        issueNumber: String = "",
        issueVolume: String = "",
        issueDate: String = "",
        barcode: String = "",
        updatedAt: Date = Date(timeIntervalSince1970: 100)
    ) -> Publication {
        Publication(
            id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", id))!,
            type: type,
            title: title,
            subtitle: subtitle,
            authorsText: authors,
            language: language,
            publisher: publisher,
            issn: issn,
            ean: ean,
            barcode: barcode,
            issueNumber: issueNumber,
            issueVolume: issueVolume,
            issueDate: issueDate,
            updatedAt: updatedAt
        )
    }

    private func makeItem(_ publication: Publication) -> OwnedItem {
        OwnedItem(publication: publication, locationPathText: "Dom / Półka")
    }
}
