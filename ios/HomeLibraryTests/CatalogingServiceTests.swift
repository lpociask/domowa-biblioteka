import SwiftData
import XCTest
@testable import HomeLibrary

@MainActor
final class CatalogingServiceTests: XCTestCase {
    func testSavingSameISBNUsesOnePublicationForTwoOwnedItems() throws {
        let context = try makeContext()
        let service = CatalogingService(modelContext: context)
        let request = CatalogingSaveRequest(
            type: .book,
            title: "The Design of Everyday Things",
            isbn13: "9780306406157",
            locationPathText: "Gabinet / Regał 2"
        )

        let first = try service.save(request)
        let second = try service.save(request)

        XCTAssertFalse(first.usedExisting)
        XCTAssertEqual(first.copyCount, 1)
        XCTAssertNil(first.duplicateKind)
        XCTAssertEqual(first.previousCopiesAtCurrentLocation, 0)
        XCTAssertTrue(second.usedExisting)
        XCTAssertEqual(second.copyCount, 2)
        XCTAssertEqual(second.duplicateKind, .possibleRepeatScan)
        XCTAssertEqual(second.previousCopiesAtCurrentLocation, 1)
        XCTAssertEqual(first.publication.id, second.publication.id)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Publication>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<OwnedItem>()), 2)
    }

    func testLegacyDuplicatePublicationsUseTheSameDeterministicRecordAsPreflight() throws {
        let context = try makeContext()
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
        let location = "Dom / Gabinet / Półka 1"
        context.insert(canonical)
        context.insert(duplicate)
        context.insert(OwnedItem(publication: duplicate, locationPathText: location))
        context.insert(OwnedItem(publication: canonical, locationPathText: location))
        try context.save()

        let existingItems = try context.fetch(FetchDescriptor<OwnedItem>())
        let preflight = try XCTUnwrap(ExistingPublicationMatcher.match(
            in: Array(existingItems.reversed()),
            type: .book,
            isbn13: "9780306406157",
            issn: "",
            ean: "",
            issueNumber: "",
            issueDate: "",
            locationPath: LocationPath(location)
        ))
        let result = try CatalogingService(modelContext: context).save(CatalogingSaveRequest(
            type: .book,
            title: "",
            isbn13: "9780306406157",
            locationPathText: location
        ))

        XCTAssertEqual(preflight.publication.id, canonical.id)
        XCTAssertEqual(result.publication.id, canonical.id)
        XCTAssertEqual(result.copyCount, 3)
        XCTAssertEqual(result.duplicateKind, .possibleRepeatScan)
        XCTAssertEqual(result.previousCopiesAtCurrentLocation, 2)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Publication>()), 2)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<OwnedItem>()), 3)
    }

    func testDifferentPeriodicalIssuesCreateSeparatePublications() throws {
        let context = try makeContext()
        let service = CatalogingService(modelContext: context)

        _ = try service.save(periodicalRequest(issueNumber: "7/2026"))
        let second = try service.save(periodicalRequest(issueNumber: "8/2026"))

        XCTAssertFalse(second.usedExisting)
        XCTAssertEqual(second.copyCount, 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Publication>()), 2)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<OwnedItem>()), 2)
    }

    func testExactPeriodicalCompositeBarcodeReusesPublicationWithoutIssueFields() throws {
        let context = try makeContext()
        let service = CatalogingService(modelContext: context)
        let request = periodicalRequest(
            issueNumber: "",
            issueDate: "",
            barcode: "9770033248007+05"
        )

        let first = try service.save(request)
        let second = try service.save(request)

        XCTAssertFalse(first.usedExisting)
        XCTAssertTrue(second.usedExisting)
        XCTAssertEqual(first.publication.id, second.publication.id)
        XCTAssertEqual(second.copyCount, 2)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Publication>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<OwnedItem>()), 2)
    }

    func testForceNewPeriodicalIssueDoesNotReuseExactCompositeCandidate() throws {
        let context = try makeContext()
        let service = CatalogingService(modelContext: context)
        let first = periodicalRequest(
            issueNumber: "",
            issueDate: "",
            barcode: "9770033248007+05"
        )
        _ = try service.save(first)

        let second = try service.save(CatalogingSaveRequest(
            type: .periodical,
            title: "Miesięcznik — inny numer",
            issn: "0033-248X",
            ean: "9770033248007",
            barcode: "9770033248007+05",
            issueNumber: "5/2026",
            savedAt: Date(timeIntervalSince1970: 2),
            forceNewPublication: true
        ))

        XCTAssertFalse(second.usedExisting)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Publication>()), 2)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<OwnedItem>()), 2)
    }

    func testDifferentPeriodicalSupplementsCreateSeparatePublications() throws {
        let context = try makeContext()
        let service = CatalogingService(modelContext: context)

        let first = try service.save(periodicalRequest(
            issueNumber: "8/2026",
            issueDate: "2026-08",
            barcode: "9770033248007+05"
        ))
        let second = try service.save(periodicalRequest(
            issueNumber: "8/2026",
            issueDate: "2026-08",
            barcode: "9770033248007+06"
        ))

        XCTAssertFalse(first.usedExisting)
        XCTAssertFalse(second.usedExisting)
        XCTAssertNotEqual(first.publication.id, second.publication.id)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Publication>()), 2)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<OwnedItem>()), 2)
    }

    func testBasePeriodicalEANWithoutSupplementDoesNotReusePublicationByItself() throws {
        let context = try makeContext()
        let service = CatalogingService(modelContext: context)
        let request = periodicalRequest(
            issueNumber: "",
            issueDate: "",
            barcode: "9770033248007"
        )

        let first = try service.save(request)
        let second = try service.save(request)

        XCTAssertFalse(first.usedExisting)
        XCTAssertFalse(second.usedExisting)
        XCTAssertNotEqual(first.publication.id, second.publication.id)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Publication>()), 2)
    }

    func testFallbackMatchPersistsNewlyObservedSupplement() throws {
        let context = try makeContext()
        let service = CatalogingService(modelContext: context)

        let first = try service.save(periodicalRequest(
            issueNumber: "8/2026",
            issueDate: "2026-08",
            barcode: "9770033248007"
        ))
        let second = try service.save(periodicalRequest(
            issueNumber: "8/2026",
            issueDate: "2026-08",
            barcode: "9770033248007+12345"
        ))

        XCTAssertTrue(second.usedExisting)
        XCTAssertEqual(first.publication.id, second.publication.id)
        XCTAssertEqual(second.publication.ean, "9770033248007")
        XCTAssertEqual(second.publication.barcode, "9770033248007+12345")
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Publication>()), 1)
    }

    func testPeriodicalReuseFillsOnlyMissingIssueFields() throws {
        let context = try makeContext()
        let existing = Publication(
            type: .periodical,
            title: "Miesięcznik",
            issn: "0033-248X",
            ean: "9770033248007",
            barcode: "9770033248007",
            issueNumber: "8/2026",
            issueVolume: "",
            issueDate: ""
        )
        context.insert(existing)
        context.insert(OwnedItem(publication: existing, locationPathText: "Archiwum"))
        try context.save()

        let result = try CatalogingService(modelContext: context).save(periodicalRequest(
            issueNumber: "8/2026",
            issueDate: "2026-08",
            barcode: "9770033248007+05"
        ))

        XCTAssertTrue(result.usedExisting)
        XCTAssertEqual(result.publication.issueNumber, "8/2026")
        XCTAssertEqual(result.publication.issueDate, "2026-08")
        XCTAssertEqual(result.publication.barcode, "9770033248007+05")
    }

    func testDuplicateFillsOnlyMissingCoverAndNeverOverwritesAcceptedReference() throws {
        let context = try makeContext()
        let publication = Publication(
            type: .book,
            title: "Solaris",
            isbn13: "9788308068854"
        )
        context.insert(publication)
        context.insert(OwnedItem(publication: publication, locationPathText: "Gabinet"))
        try context.save()

        let service = CatalogingService(modelContext: context)
        let firstURL = "https://covers.openlibrary.org/b/isbn/9788308068854-M.jpg?default=false"
        _ = try service.save(CatalogingSaveRequest(
            type: .book,
            title: "",
            isbn13: "9788308068854",
            coverURLString: firstURL,
            coverSource: "openlibrary",
            locationPathText: "Salon"
        ))

        XCTAssertEqual(publication.coverURLString, firstURL)
        XCTAssertEqual(publication.coverSource, "openlibrary")

        _ = try service.save(CatalogingSaveRequest(
            type: .book,
            title: "",
            isbn13: "9788308068854",
            coverURLString: "https://covers.openlibrary.org/b/id/999-M.jpg",
            coverSource: "other",
            locationPathText: "Sypialnia"
        ))

        XCTAssertEqual(publication.coverURLString, firstURL)
        XCTAssertEqual(publication.coverSource, "openlibrary")
    }

    func testSamePeriodicalIssueWithDatePresentOnOnlyOneCopyUsesExistingPublication() throws {
        let context = try makeContext()
        let service = CatalogingService(modelContext: context)

        let first = try service.save(periodicalRequest(
            issueNumber: "8/2026",
            issueDate: ""
        ))
        let second = try service.save(periodicalRequest(
            issueNumber: "8/2026",
            issueDate: "2026-08"
        ))

        XCTAssertTrue(second.usedExisting)
        XCTAssertEqual(second.copyCount, 2)
        XCTAssertEqual(first.publication.id, second.publication.id)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Publication>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<OwnedItem>()), 2)
    }

    func testPreservesPublicationAndCopyFieldsAndCanonicalizesLocation() throws {
        let context = try makeContext()
        let service = CatalogingService(modelContext: context)
        let savedAt = Date(timeIntervalSince1970: 1_786_406_400)

        let result = try service.save(CatalogingSaveRequest(
            type: .book,
            title: "Solaris",
            subtitle: "Powieść",
            authorsText: "Stanisław Lem",
            language: "pl",
            publisher: "Wydawnictwo Literackie",
            publicationYear: 1961,
            isbn13: "9780306406157",
            issn: "",
            ean: "9780306406157",
            barcode: "9780306406157",
            issueNumber: "",
            issueVolume: "",
            issueDate: "",
            metadataSource: "BN",
            coverURLString: "https://covers.openlibrary.org/b/id/123-M.jpg",
            coverSource: "openlibrary",
            locationPathText: "  Dom// Gabinet  ›  Regał  2 / Półka 3  ",
            notes: "Egzemplarz z dedykacją",
            savedAt: savedAt
        ))

        XCTAssertFalse(result.usedExisting)
        XCTAssertEqual(result.copyCount, 1)
        XCTAssertEqual(result.publication.publicationType, .book)
        XCTAssertEqual(result.publication.title, "Solaris")
        XCTAssertEqual(result.publication.subtitle, "Powieść")
        XCTAssertEqual(result.publication.authorsText, "Stanisław Lem")
        XCTAssertEqual(result.publication.language, "pl")
        XCTAssertEqual(result.publication.publisher, "Wydawnictwo Literackie")
        XCTAssertEqual(result.publication.publicationYear, 1961)
        XCTAssertEqual(result.publication.isbn13, "9780306406157")
        XCTAssertEqual(result.publication.ean, "9780306406157")
        XCTAssertEqual(result.publication.barcode, "9780306406157")
        XCTAssertEqual(result.publication.metadataSource, "BN")
        XCTAssertEqual(result.publication.coverURLString, "https://covers.openlibrary.org/b/id/123-M.jpg")
        XCTAssertEqual(result.publication.coverSource, "openlibrary")
        XCTAssertEqual(result.publication.createdAt, savedAt)
        XCTAssertEqual(result.publication.updatedAt, savedAt)
        XCTAssertEqual(result.item.publication?.id, result.publication.id)
        XCTAssertEqual(result.item.locationPathText, "Dom / Gabinet / Regał 2 / Półka 3")
        XCTAssertEqual(result.item.notes, "Egzemplarz z dedykacją")
        XCTAssertEqual(result.item.addedAt, savedAt)
        XCTAssertEqual(result.item.updatedAt, savedAt)
    }

    private func periodicalRequest(
        issueNumber: String,
        issueDate: String = "2026-08",
        barcode: String = ""
    ) -> CatalogingSaveRequest {
        CatalogingSaveRequest(
            type: .periodical,
            title: "Przekrój",
            issn: "0033-248X",
            ean: "9770033248007",
            barcode: barcode,
            issueNumber: issueNumber,
            issueDate: issueDate,
            locationPathText: "Salon / Stolik"
        )
    }

    private func makeContext() throws -> ModelContext {
        let schema = Schema([Publication.self, OwnedItem.self])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        return ModelContext(container)
    }
}
