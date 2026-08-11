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
        issueDate: String = "2026-08"
    ) -> CatalogingSaveRequest {
        CatalogingSaveRequest(
            type: .periodical,
            title: "Przekrój",
            issn: "0033-248X",
            ean: "9770033248007",
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
