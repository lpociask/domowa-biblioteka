import XCTest
@testable import HomeLibrary

final class PeriodicalIssueAnalyzerTests: XCTestCase {
    func testGroupsByValidExplicitISSNBeforeMetadata() throws {
        let first = makePublication(
            id: 1,
            title: "Pierwszy tytuł",
            issn: "0033-2488",
            issueNumber: "1/2026"
        )
        let second = makePublication(
            id: 2,
            title: "Zupełnie inny tytuł",
            issn: "00332488",
            issueNumber: "2/2026"
        )

        let analysis = PeriodicalIssueAnalyzer.analyze(items: [makeItem(1, first), makeItem(2, second)])

        let series = try XCTUnwrap(analysis.series.first)
        XCTAssertEqual(analysis.series.count, 1)
        XCTAssertEqual(series.identification, .issn("0033-2488"))
        XCTAssertEqual(series.issn, "0033-2488")
        XCTAssertEqual(series.issues.count, 2)
    }

    func testExplicitAndEANDerivedISSNJoinTheSameSeries() throws {
        let explicit = makePublication(
            id: 1,
            issn: "0033-2488",
            issueNumber: "1/2026"
        )
        let derived = makePublication(
            id: 2,
            ean: "9770033248007",
            issueNumber: "2/2026"
        )

        let analysis = PeriodicalIssueAnalyzer.analyze(items: [makeItem(1, explicit), makeItem(2, derived)])

        XCTAssertEqual(analysis.series.count, 1)
        XCTAssertEqual(analysis.series.first?.identification, .issn("0033-2488"))
    }

    func testDerivesISSNFromCanonicalCompositeBarcode() throws {
        let publication = makePublication(
            id: 1,
            barcode: "9771050124008+05",
            issueNumber: "5/2026"
        )

        let series = try XCTUnwrap(
            PeriodicalIssueAnalyzer.analyze(items: [makeItem(1, publication)]).series.first
        )

        XCTAssertEqual(series.identification, .issn("1050-124X"))
        XCTAssertEqual(series.issn, "1050-124X")
    }

    func testMetadataFallbackNormalizesCaseWhitespaceDiacriticsAndPunctuation() {
        let first = makePublication(
            id: 1,
            title: " Życie   Nauki! ",
            publisher: "Prószyński & S-ka",
            language: "PL",
            issueNumber: "1"
        )
        let second = makePublication(
            id: 2,
            title: "zycie nauki",
            publisher: "proszynski s ka",
            language: "pl",
            issueNumber: "2"
        )

        let analysis = PeriodicalIssueAnalyzer.analyze(items: [makeItem(1, first), makeItem(2, second)])

        XCTAssertEqual(analysis.series.count, 1)
        XCTAssertEqual(
            analysis.series.first?.identification,
            .metadata(title: "zycie nauki", publisher: "proszynski s ka", language: "pl")
        )
    }

    func testInvalidExplicitISSNFallsBackToDerivedISSNAndAddsWarning() throws {
        let publication = makePublication(
            id: 1,
            issn: "0033-2487",
            ean: "9770033248007",
            issueNumber: "1"
        )

        let series = try XCTUnwrap(
            PeriodicalIssueAnalyzer.analyze(items: [makeItem(1, publication)]).series.first
        )

        XCTAssertEqual(series.identification, .issn("0033-2488"))
        XCTAssertEqual(series.warnings.map(\.kind), [.invalidExplicitISSN])
    }

    func testExplicitISSNConflictWithEANIsIsolatedAndWarned() throws {
        let conflict = makePublication(
            id: 1,
            title: "Tygodnik",
            issn: "1050-124X",
            ean: "9770033248007",
            issueNumber: "1"
        )
        let ordinary = makePublication(
            id: 2,
            title: "Tygodnik",
            issn: "1050-124X",
            issueNumber: "2"
        )

        let analysis = PeriodicalIssueAnalyzer.analyze(items: [makeItem(1, conflict), makeItem(2, ordinary)])

        XCTAssertEqual(analysis.series.count, 2)
        let isolated = try XCTUnwrap(analysis.series.first { series in
            if case .isolatedIdentifierConflict = series.identification { return true }
            return false
        })
        XCTAssertEqual(isolated.issues.map(\.publicationID), [conflict.id])
        XCTAssertEqual(isolated.warnings.map(\.kind), [.identifierConflict])
    }

    func testParsesSupportedIssueNumberFormsAndCanonicalizesYearFirst() {
        let simple = makePublication(
            id: 1,
            publicationYear: 2023,
            issueNumber: "8",
            issueDate: "2024-08",
            issueVolume: "11"
        )
        let numberYear = makePublication(id: 2, issueNumber: "8/2025")
        let yearNumber = makePublication(id: 3, issueNumber: "2026/8")
        let combined = makePublication(id: 4, issueNumber: "1–2/2027")

        let analysis = PeriodicalIssueAnalyzer.analyze(items: [
            makeItem(1, simple), makeItem(2, numberYear),
            makeItem(3, yearNumber), makeItem(4, combined)
        ])
        let issues: [UUID: PeriodicalAnalyzedIssue] = Dictionary(
            uniqueKeysWithValues: analysis.series.flatMap { $0.issues }.map { ($0.publicationID, $0) }
        )

        XCTAssertEqual(issues[simple.id]?.canonicalIssueNumber, "8")
        XCTAssertEqual(issues[simple.id]?.cycle, .year(2024))
        XCTAssertEqual(issues[numberYear.id]?.canonicalIssueNumber, "8/2025")
        XCTAssertEqual(issues[numberYear.id]?.cycle, .year(2025))
        XCTAssertEqual(issues[yearNumber.id]?.canonicalIssueNumber, "8/2026")
        XCTAssertEqual(issues[yearNumber.id]?.cycle, .year(2026))
        XCTAssertEqual(issues[combined.id]?.canonicalIssueNumber, "1-2/2027")
        XCTAssertEqual(issues[combined.id]?.issueRange, .init(first: 1, last: 2))
    }

    func testCycleFallbackOrderIsDateThenPublicationYearThenVolumeThenContinuous() {
        let fromDate = makePublication(
            id: 1,
            publicationYear: 2025,
            issueNumber: "1",
            issueDate: "maj 2026",
            issueVolume: "9"
        )
        let fromYear = makePublication(
            id: 2,
            publicationYear: 2025,
            issueNumber: "2",
            issueVolume: "9"
        )
        let fromVolume = makePublication(id: 3, issueNumber: "3", issueVolume: "Tom 09")
        let continuous = makePublication(id: 4, issueNumber: "4")

        let analysis = PeriodicalIssueAnalyzer.analyze(items: [
            makeItem(1, fromDate), makeItem(2, fromYear),
            makeItem(3, fromVolume), makeItem(4, continuous)
        ])
        let issues: [UUID: PeriodicalAnalyzedIssue] = Dictionary(
            uniqueKeysWithValues: analysis.series.flatMap { $0.issues }.map { ($0.publicationID, $0) }
        )

        XCTAssertEqual(issues[fromDate.id]?.cycle, .year(2026))
        XCTAssertEqual(issues[fromYear.id]?.cycle, .year(2025))
        XCTAssertEqual(issues[fromVolume.id]?.cycle, .volume("tom 09"))
        XCTAssertEqual(issues[continuous.id]?.cycle, .continuous)
    }

    func testMissingIssuesUseCombinedIssueCoverageAndOnlyInteriorGaps() throws {
        let combined = makePublication(id: 1, issueNumber: "1-2/2026")
        let fourth = makePublication(id: 2, issueNumber: "4/2026")

        let series = try XCTUnwrap(
            PeriodicalIssueAnalyzer.analyze(items: [makeItem(1, combined), makeItem(2, fourth)])
                .series.first
        )

        XCTAssertEqual(series.missingIssues.map(\.number), [3])
        XCTAssertEqual(series.missingIssues.map(\.cycle), [.year(2026)])
    }

    func testMissingIssuesDoNotAssumeNumbersBeforeMinimumOrAfterMaximum() throws {
        let third = makePublication(id: 1, issueNumber: "3")
        let fifth = makePublication(id: 2, issueNumber: "5")

        let series = try XCTUnwrap(
            PeriodicalIssueAnalyzer.analyze(items: [makeItem(1, third), makeItem(2, fifth)])
                .series.first
        )

        XCTAssertEqual(series.missingIssues.map(\.number), [4])
    }

    func testMissingRangeOverTwoHundredIsNotEnumerated() throws {
        let first = makePublication(id: 1, issueNumber: "1")
        let far = makePublication(id: 2, issueNumber: "201")

        let series = try XCTUnwrap(
            PeriodicalIssueAnalyzer.analyze(items: [makeItem(1, first), makeItem(2, far)])
                .series.first
        )

        XCTAssertTrue(series.missingIssues.isEmpty)
        XCTAssertEqual(series.warnings.map(\.kind), [.missingRangeLimitExceeded])
    }

    func testMissingListIsCappedAtFiftyWithWarning() throws {
        let first = makePublication(id: 1, issueNumber: "1")
        let last = makePublication(id: 2, issueNumber: "60")

        let series = try XCTUnwrap(
            PeriodicalIssueAnalyzer.analyze(items: [makeItem(1, first), makeItem(2, last)])
                .series.first
        )

        XCTAssertEqual(series.missingIssues.count, 50)
        XCTAssertEqual(series.missingIssues.first?.number, 2)
        XCTAssertEqual(series.missingIssues.last?.number, 51)
        XCTAssertEqual(series.warnings.map(\.kind), [.missingListTruncated])
    }

    func testMultipleCopiesAndDuplicatePublicationRecordsAreSeparateFindings() throws {
        let canonical = makePublication(id: 1, issueNumber: "8/2026", issueDate: "2026-08")
        let duplicateRecord = makePublication(id: 2, issueNumber: "2026/8", issueDate: "2026-08-15")
        let firstCopy = makeItem(1, canonical)
        let secondCopy = makeItem(2, canonical, status: .loaned)
        let duplicateCopy = makeItem(3, duplicateRecord, status: .missing)

        let series = try XCTUnwrap(
            PeriodicalIssueAnalyzer.analyze(items: [firstCopy, secondCopy, duplicateCopy]).series.first
        )

        XCTAssertEqual(series.multipleCopyGroups.count, 1)
        XCTAssertEqual(series.multipleCopyGroups.first?.publicationID, canonical.id)
        XCTAssertEqual(Set(series.multipleCopyGroups.first?.itemIDs ?? []), Set([firstCopy.id, secondCopy.id]))
        XCTAssertEqual(series.duplicatePublicationGroups.count, 1)
        XCTAssertEqual(
            Set(series.duplicatePublicationGroups.first?.publicationIDs ?? []),
            Set([canonical.id, duplicateRecord.id])
        )
        XCTAssertEqual(series.duplicatePublicationGroups.first?.itemIDs.count, 3)
    }

    func testArchivedCopiesAreExcludedWhileLoanedAndMissingStayInAnalysis() throws {
        let archivedPublication = makePublication(id: 1, issueNumber: "1/2026")
        let loanedPublication = makePublication(id: 2, issueNumber: "2/2026")
        let missingPublication = makePublication(id: 3, issueNumber: "4/2026")
        let book = makePublication(id: 4, type: .book, issueNumber: "3/2026")

        let analysis = PeriodicalIssueAnalyzer.analyze(items: [
            makeItem(1, archivedPublication, status: .archived),
            makeItem(2, loanedPublication, status: .loaned),
            makeItem(3, missingPublication, status: .missing),
            makeItem(4, book)
        ])
        let series = try XCTUnwrap(analysis.series.first)

        XCTAssertEqual(analysis.excludedArchivedCopyCount, 1)
        XCTAssertEqual(analysis.excludedNonPeriodicalItemCount, 1)
        XCTAssertEqual(series.issues.count, 2)
        XCTAssertEqual(series.issues.flatMap(\.copies).map(\.status), [.loaned, .missing])
        XCTAssertEqual(series.missingIssues.map(\.number), [3])
    }

    func testConflictingDatesWarnInsteadOfConfirmingDuplicateRecords() throws {
        let first = makePublication(id: 1, issueNumber: "8/2026", issueDate: "2026-08")
        let second = makePublication(id: 2, issueNumber: "8/2026", issueDate: "2026-09")

        let series = try XCTUnwrap(
            PeriodicalIssueAnalyzer.analyze(items: [makeItem(1, first), makeItem(2, second)])
                .series.first
        )

        XCTAssertTrue(series.duplicatePublicationGroups.isEmpty)
        XCTAssertEqual(series.warnings.map(\.kind), [.conflictingIssueMetadata])
    }

    func testConflictingVolumesWarnInsteadOfConfirmingDuplicateRecords() throws {
        let first = makePublication(id: 1, issueNumber: "8/2026", issueVolume: "12")
        let second = makePublication(id: 2, issueNumber: "8/2026", issueVolume: "13")

        let series = try XCTUnwrap(
            PeriodicalIssueAnalyzer.analyze(items: [makeItem(1, first), makeItem(2, second)])
                .series.first
        )

        XCTAssertTrue(series.duplicatePublicationGroups.isEmpty)
        XCTAssertEqual(series.warnings.map(\.kind), [.conflictingIssueMetadata])
    }

    func testCompatiblePartialAndFullDatesCanConfirmDuplicateRecords() throws {
        let first = makePublication(id: 1, issueNumber: "8/2026", issueDate: "2026-08")
        let second = makePublication(id: 2, issueNumber: "8/2026", issueDate: "2026-08-15")

        let series = try XCTUnwrap(
            PeriodicalIssueAnalyzer.analyze(items: [makeItem(1, first), makeItem(2, second)])
                .series.first
        )

        XCTAssertEqual(series.duplicatePublicationGroups.count, 1)
        XCTAssertTrue(series.warnings.isEmpty)
    }

    func testDifferentEANSupplementsAreNotDuplicatePublicationRecords() throws {
        let first = makePublication(
            id: 1,
            ean: "9770033248007",
            barcode: "9770033248007+05",
            issueNumber: "8/2026"
        )
        let second = makePublication(
            id: 2,
            ean: "9770033248007",
            barcode: "9770033248007+06",
            issueNumber: "8/2026"
        )

        let series = try XCTUnwrap(
            PeriodicalIssueAnalyzer.analyze(items: [makeItem(1, first), makeItem(2, second)])
                .series.first
        )

        XCTAssertTrue(series.duplicatePublicationGroups.isEmpty)
    }

    func testDifferentEANSupplementsCreateSeparateDuplicateGroups() throws {
        let publications = [
            makePublication(
                id: 1,
                ean: "9770033248007",
                barcode: "9770033248007+05",
                issueNumber: "8/2026"
            ),
            makePublication(
                id: 2,
                ean: "9770033248007",
                barcode: "9770033248007+05",
                issueNumber: "8/2026"
            ),
            makePublication(
                id: 3,
                ean: "9770033248007",
                barcode: "9770033248007+06",
                issueNumber: "8/2026"
            ),
            makePublication(
                id: 4,
                ean: "9770033248007",
                barcode: "9770033248007+06",
                issueNumber: "8/2026"
            )
        ]

        let series = try XCTUnwrap(
            PeriodicalIssueAnalyzer.analyze(items: publications.enumerated().map {
                makeItem($0.offset + 1, $0.element)
            }).series.first
        )

        XCTAssertEqual(series.duplicatePublicationGroups.count, 2)
        XCTAssertEqual(
            Set(series.duplicatePublicationGroups.map { Set($0.publicationIDs) }),
            Set([Set([publications[0].id, publications[1].id]),
                 Set([publications[2].id, publications[3].id])])
        )
    }

    func testDifferentExplicitMainEANsAreNotDuplicatesEvenWithSameSupplement() throws {
        let first = makePublication(
            id: 1,
            ean: "9770033248007",
            barcode: "9770033248007+05",
            issueNumber: "8/2026"
        )
        let second = makePublication(
            id: 2,
            ean: "9770033248014",
            barcode: "9770033248014+05",
            issueNumber: "8/2026"
        )

        let series = try XCTUnwrap(
            PeriodicalIssueAnalyzer.analyze(items: [makeItem(1, first), makeItem(2, second)])
                .series.first
        )

        XCTAssertEqual(series.issues.count, 2)
        XCTAssertTrue(series.duplicatePublicationGroups.isEmpty)
    }

    func testDifferentExplicitMainEANsCreateSeparateDuplicateGroups() throws {
        let publications = [
            makePublication(
                id: 1,
                ean: "9770033248007",
                barcode: "9770033248007+05",
                issueNumber: "8/2026"
            ),
            makePublication(
                id: 2,
                ean: "9770033248007",
                barcode: "9770033248007+05",
                issueNumber: "8/2026"
            ),
            makePublication(
                id: 3,
                ean: "9770033248014",
                barcode: "9770033248014+05",
                issueNumber: "8/2026"
            ),
            makePublication(
                id: 4,
                ean: "9770033248014",
                barcode: "9770033248014+05",
                issueNumber: "8/2026"
            )
        ]

        let series = try XCTUnwrap(
            PeriodicalIssueAnalyzer.analyze(items: publications.enumerated().map {
                makeItem($0.offset + 1, $0.element)
            }).series.first
        )

        XCTAssertEqual(series.duplicatePublicationGroups.count, 2)
        XCTAssertEqual(
            Set(series.duplicatePublicationGroups.map { Set($0.publicationIDs) }),
            Set([Set([publications[0].id, publications[1].id]),
                 Set([publications[2].id, publications[3].id])])
        )
    }

    func testMissingSupplementCanFallBackWhenExplicitMainEANDoesNotConflict() throws {
        let withSupplement = makePublication(
            id: 1,
            ean: "9770033248007",
            barcode: "9770033248007+05",
            issueNumber: "8/2026"
        )
        let withoutSupplement = makePublication(
            id: 2,
            ean: "9770033248007",
            issueNumber: "2026/8"
        )

        let series = try XCTUnwrap(
            PeriodicalIssueAnalyzer.analyze(
                items: [makeItem(1, withSupplement), makeItem(2, withoutSupplement)]
            ).series.first
        )

        XCTAssertEqual(series.duplicatePublicationGroups.count, 1)
    }

    func testMissingSupplementDoesNotBridgeConflictingAddonGroups() throws {
        let firstFive = makePublication(
            id: 1,
            ean: "9770033248007",
            barcode: "9770033248007+05",
            issueNumber: "8/2026"
        )
        let secondFive = makePublication(
            id: 2,
            ean: "9770033248007",
            barcode: "9770033248007+05",
            issueNumber: "8/2026"
        )
        let firstSix = makePublication(
            id: 3,
            ean: "9770033248007",
            barcode: "9770033248007+06",
            issueNumber: "8/2026"
        )
        let secondSix = makePublication(
            id: 4,
            ean: "9770033248007",
            barcode: "9770033248007+06",
            issueNumber: "8/2026"
        )
        let missingSupplement = makePublication(
            id: 5,
            ean: "9770033248007",
            issueNumber: "8/2026"
        )

        let series = try XCTUnwrap(
            PeriodicalIssueAnalyzer.analyze(items: [
                makeItem(1, firstFive),
                makeItem(2, secondFive),
                makeItem(3, firstSix),
                makeItem(4, secondSix),
                makeItem(5, missingSupplement)
            ]).series.first
        )

        XCTAssertEqual(series.duplicatePublicationGroups.count, 2)
        XCTAssertFalse(
            series.duplicatePublicationGroups
                .flatMap(\.publicationIDs)
                .contains(missingSupplement.id)
        )
    }

    func testOutputAndStableIDsAreDeterministicForReversedInput() {
        let first = makePublication(id: 11, title: "B", issueNumber: "3/2026")
        let second = makePublication(id: 12, title: "A", issueNumber: "1/2026")
        let third = makePublication(id: 13, title: "B", issueNumber: "1/2026")
        let items = [makeItem(21, first), makeItem(22, second), makeItem(23, third)]

        let forward = PeriodicalIssueAnalyzer.analyze(items: items)
        let reversed = PeriodicalIssueAnalyzer.analyze(items: items.reversed())

        XCTAssertEqual(forward, reversed)
        XCTAssertEqual(forward.series.map(\.id), forward.series.map(\.id).sorted())
    }

    func testMetadataFallbackRequiresNonemptyTitlePublisherAndLanguage() {
        let first = makePublication(id: 1, title: "", issueNumber: "1")
        let second = makePublication(id: 2, publisher: "   ", issueNumber: "2")
        let third = makePublication(id: 3, language: "", issueNumber: "3")

        let analysis = PeriodicalIssueAnalyzer.analyze(items: [
            makeItem(1, first),
            makeItem(2, second),
            makeItem(3, third)
        ])

        XCTAssertEqual(analysis.series.count, 3)
        XCTAssertTrue(analysis.series.allSatisfy { series in
            if case .isolatedPublication = series.identification { return true }
            return false
        })
    }

    private func makePublication(
        id: Int,
        type: PublicationType = .periodical,
        title: String = "Magazyn Testowy",
        publisher: String = "Wydawnictwo",
        language: String = "pl",
        publicationYear: Int? = nil,
        issn: String = "",
        ean: String = "",
        barcode: String = "",
        issueNumber: String = "",
        issueDate: String = "",
        issueVolume: String = ""
    ) -> Publication {
        Publication(
            id: uuid(id),
            type: type,
            title: title,
            language: language,
            publisher: publisher,
            publicationYear: publicationYear,
            issn: issn,
            ean: ean,
            barcode: barcode,
            issueNumber: issueNumber,
            issueVolume: issueVolume,
            issueDate: issueDate
        )
    }

    private func makeItem(
        _ id: Int,
        _ publication: Publication,
        status: OwnedItemStatus = .owned
    ) -> OwnedItem {
        OwnedItem(
            id: uuid(10_000 + id),
            publication: publication,
            locationPathText: "Dom / Regał / Półka",
            status: status
        )
    }

    private func uuid(_ value: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", value))!
    }
}
