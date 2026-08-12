import XCTest
@testable import HomeLibrary

final class PeriodicalMetadataFormMergeTests: XCTestCase {
    func testFillsBlankSeriesFieldsAndReplacesDefaultLanguage() {
        let baseline = PeriodicalMetadataFormFields(
            title: "",
            publisher: "",
            language: "pl"
        )

        let result = PeriodicalMetadataFormMerge.merge(
            metadata: metadata(
                title: "Monocle",
                publisher: "Winkontent",
                language: "en"
            ),
            baseline: baseline,
            current: baseline
        )

        XCTAssertEqual(result.fields.title, "Monocle")
        XCTAssertEqual(result.fields.publisher, "Winkontent")
        XCTAssertEqual(result.fields.language, "en")
        XCTAssertTrue(result.didApplyMetadata)
    }

    func testPreservesSeriesDescriptionAlreadyFilledFromCollection() {
        let fields = PeriodicalMetadataFormFields(
            title: "Monocle Polska",
            publisher: "Wydawca lokalny",
            language: "pl"
        )

        let result = PeriodicalMetadataFormMerge.merge(
            metadata: metadata(
                title: "Monocle",
                publisher: "Winkontent",
                language: "en"
            ),
            baseline: fields,
            current: fields
        )

        XCTAssertEqual(result.fields, fields)
        XCTAssertFalse(result.didApplyMetadata)
    }

    func testPreservesManualChangesMadeDuringLookup() {
        let baseline = PeriodicalMetadataFormFields(
            title: "",
            publisher: "",
            language: "pl"
        )
        let current = PeriodicalMetadataFormFields(
            title: "Tytuł wpisany ręcznie",
            publisher: "Wydawca wpisany ręcznie",
            language: "de"
        )

        let result = PeriodicalMetadataFormMerge.merge(
            metadata: metadata(
                title: "Catalog title",
                publisher: "Catalog publisher",
                language: "en"
            ),
            baseline: baseline,
            current: current
        )

        XCTAssertEqual(result.fields, current)
        XCTAssertFalse(result.didApplyMetadata)
    }

    func testIgnoresEmptyCatalogValues() {
        let fields = PeriodicalMetadataFormFields(
            title: "",
            publisher: "",
            language: "pl"
        )

        let result = PeriodicalMetadataFormMerge.merge(
            metadata: metadata(title: "  ", publisher: nil, language: ""),
            baseline: fields,
            current: fields
        )

        XCTAssertEqual(result.fields, fields)
        XCTAssertFalse(result.didApplyMetadata)
    }

    func testLatePeriodicalLookupCannotFinishAfterChangingFormToBook() {
        XCTAssertFalse(PeriodicalMetadataLookupGate.canFinish(
            requestedISSN: "1753-2434",
            activeISSN: "1753-2434",
            currentISSN: "1753-2434",
            publicationType: .book
        ))

        XCTAssertTrue(PeriodicalMetadataLookupGate.shouldResetLookup(
            activeISBN: nil,
            activeISSN: "1753-2434",
            publicationType: .book
        ))
    }

    func testAutomaticSwitchForFreshEAN977KeepsMatchingPeriodicalLookup() {
        XCTAssertFalse(PeriodicalMetadataLookupGate.shouldResetLookup(
            activeISBN: nil,
            activeISSN: "1753-2434",
            publicationType: .periodical
        ))

        XCTAssertTrue(PeriodicalMetadataLookupGate.canFinish(
            requestedISSN: "1753-2434",
            activeISSN: "1753-2434",
            currentISSN: "1753-2434",
            publicationType: .periodical
        ))
    }

    func testChangingToPeriodicalResetsOnlyAnIncompatibleBookLookup() {
        XCTAssertTrue(PeriodicalMetadataLookupGate.shouldResetLookup(
            activeISBN: "9780306406157",
            activeISSN: nil,
            publicationType: .periodical
        ))

        XCTAssertFalse(PeriodicalMetadataLookupGate.shouldResetLookup(
            activeISBN: nil,
            activeISSN: "1753-2434",
            publicationType: .periodical
        ))
    }

    private func metadata(
        title: String?,
        publisher: String?,
        language: String?
    ) -> PeriodicalMetadata {
        PeriodicalMetadata(
            source: .nationalLibrary,
            issn: "1753-2434",
            title: title,
            publisher: publisher,
            language: language
        )
    }
}
