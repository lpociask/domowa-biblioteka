import SwiftData
import XCTest
@testable import HomeLibrary

@MainActor
final class CatalogItemLifecycleServiceTests: XCTestCase {
    func testDeletingOneOfTwoCopiesKeepsPublicationAndOtherCopy() throws {
        let context = try makeContext()
        let publication = makePublication()
        let removed = makeItem(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000101")!,
            publication: publication,
            location: "Gabinet / Półka 1"
        )
        let retained = makeItem(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000102")!,
            publication: publication,
            location: "Salon / Półka 2"
        )
        insert(publication: publication, items: [removed, retained], into: context)

        let receipt = try CatalogItemLifecycleService(modelContext: context)
            .delete(itemID: removed.id)

        XCTAssertFalse(receipt.publicationWasDeleted)
        XCTAssertEqual(receipt.item.id, removed.id)
        XCTAssertEqual(receipt.item.publicationID, publication.id)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Publication>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<OwnedItem>()), 1)
        XCTAssertEqual(try context.fetch(FetchDescriptor<OwnedItem>()).first?.id, retained.id)
    }

    func testDeletingLastCopyDeletesPublicationAndCapturesEveryField() throws {
        let context = try makeContext()
        let publication = makePublication()
        let item = makeItem(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000103")!,
            publication: publication,
            location: "Archiwum / Pudło 4"
        )
        item.status = .archived
        item.notes = "Lekko uszkodzona okładka"
        insert(publication: publication, items: [item], into: context)

        let receipt = try CatalogItemLifecycleService(modelContext: context)
            .delete(itemID: item.id)

        XCTAssertTrue(receipt.publicationWasDeleted)
        XCTAssertEqual(receipt.item.id, item.id)
        XCTAssertEqual(receipt.item.externalID, "copy-\(item.id.uuidString)")
        XCTAssertEqual(receipt.item.publicationID, publication.id)
        XCTAssertEqual(receipt.item.locationPathText, "Archiwum / Pudło 4")
        XCTAssertEqual(receipt.item.statusRawValue, OwnedItemStatus.archived.rawValue)
        XCTAssertEqual(receipt.item.notes, "Lekko uszkodzona okładka")
        XCTAssertEqual(receipt.item.addedAt, item.addedAt)
        XCTAssertEqual(receipt.item.updatedAt, item.updatedAt)
        assertFullPublicationSnapshot(try XCTUnwrap(receipt.publication), equals: publication)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<OwnedItem>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Publication>()), 0)
    }

    func testDeleteSaveFailureRollsBackItemAndPublication() throws {
        enum ForcedFailure: Error { case save }

        let context = try makeContext()
        let publication = makePublication()
        let item = makeItem(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000104")!,
            publication: publication,
            location: "Gabinet"
        )
        insert(publication: publication, items: [item], into: context)
        let service = CatalogItemLifecycleService(
            modelContext: context,
            saveChanges: { _ in throw ForcedFailure.save }
        )

        XCTAssertThrowsError(try service.delete(itemID: item.id)) { error in
            XCTAssertTrue(error is ForcedFailure)
        }
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<OwnedItem>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Publication>()), 1)
        XCTAssertEqual(try context.fetch(FetchDescriptor<OwnedItem>()).first?.id, item.id)
    }

    func testRestoreOneOfTwoCopiesLinksSurvivingPublicationWithoutRevertingItsEdits() throws {
        let context = try makeContext()
        let publication = makePublication()
        let removed = makeItem(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000105")!,
            publication: publication,
            location: "Gabinet / Półka 1"
        )
        removed.status = .loaned
        removed.notes = "Pożyczone Annie"
        let retained = makeItem(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000106")!,
            publication: publication,
            location: "Salon / Półka 2"
        )
        insert(publication: publication, items: [removed, retained], into: context)
        let service = CatalogItemLifecycleService(modelContext: context)
        let receipt = try service.delete(itemID: removed.id)

        publication.title = "Tytuł poprawiony po usunięciu"
        publication.updatedAt = publication.updatedAt.addingTimeInterval(60)
        try context.save()

        let result = try service.restore(receipt)

        XCTAssertFalse(result.recreatedPublication)
        let restoredPublication = try XCTUnwrap(result.publication)
        XCTAssertEqual(restoredPublication.persistentModelID, publication.persistentModelID)
        XCTAssertEqual(restoredPublication.title, "Tytuł poprawiony po usunięciu")
        XCTAssertEqual(result.item.id, removed.id)
        XCTAssertEqual(result.item.externalID, receipt.item.externalID)
        XCTAssertEqual(result.item.locationPathText, receipt.item.locationPathText)
        XCTAssertEqual(result.item.statusRawValue, receipt.item.statusRawValue)
        XCTAssertEqual(result.item.notes, receipt.item.notes)
        XCTAssertEqual(result.item.addedAt, receipt.item.addedAt)
        XCTAssertEqual(result.item.updatedAt, receipt.item.updatedAt)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<OwnedItem>()), 2)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Publication>()), 1)
    }

    func testRestoreLastCopyRecreatesPublicationAndItemExactly() throws {
        let context = try makeContext()
        let publication = makePublication()
        let item = makeItem(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000107")!,
            publication: publication,
            location: "Magazyn / Regał C / Półka 7"
        )
        item.status = .missing
        item.notes = "Sprawdzić po remoncie"
        insert(publication: publication, items: [item], into: context)
        let service = CatalogItemLifecycleService(modelContext: context)
        let receipt = try service.delete(itemID: item.id)

        let result = try service.restore(receipt)

        XCTAssertTrue(result.recreatedPublication)
        let restoredPublication = try XCTUnwrap(result.publication)
        let publicationSnapshot = try XCTUnwrap(receipt.publication)
        assertPublication(restoredPublication, equals: publicationSnapshot)
        assertItem(result.item, equals: receipt.item)
        XCTAssertEqual(result.item.publication?.persistentModelID, restoredPublication.persistentModelID)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<OwnedItem>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Publication>()), 1)
    }

    func testRestoreRejectsReusedItemIDWithoutChangingCollection() throws {
        let context = try makeContext()
        let publication = makePublication()
        let removed = makeItem(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000108")!,
            publication: publication,
            location: "Gabinet"
        )
        let retained = makeItem(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000109")!,
            publication: publication,
            location: "Salon"
        )
        insert(publication: publication, items: [removed, retained], into: context)
        let service = CatalogItemLifecycleService(modelContext: context)
        let receipt = try service.delete(itemID: removed.id)
        let replacement = OwnedItem(
            id: removed.id,
            externalID: "replacement-copy",
            publication: publication,
            locationPathText: "Inne miejsce"
        )
        context.insert(replacement)
        try context.save()

        XCTAssertThrowsError(try service.restore(receipt)) { error in
            XCTAssertEqual(
                error as? CatalogItemLifecycleError,
                .itemIdentityConflict(removed.id)
            )
        }
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<OwnedItem>()), 2)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Publication>()), 1)
    }

    func testRestoreRejectsReusedPublicationIDAfterLastCopyDeletion() throws {
        let context = try makeContext()
        let publication = makePublication()
        let item = makeItem(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000110")!,
            publication: publication,
            location: "Gabinet"
        )
        insert(publication: publication, items: [item], into: context)
        let service = CatalogItemLifecycleService(modelContext: context)
        let receipt = try service.delete(itemID: item.id)
        let replacement = Publication(
            id: publication.id,
            externalID: "replacement-publication",
            type: .book,
            title: "Inny rekord"
        )
        context.insert(replacement)
        try context.save()

        XCTAssertThrowsError(try service.restore(receipt)) { error in
            XCTAssertEqual(
                error as? CatalogItemLifecycleError,
                .publicationIdentityConflict(publication.id)
            )
        }
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<OwnedItem>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Publication>()), 1)
    }

    func testRestoreRequiresSurvivingPublicationWhenReceiptDidNotDeleteIt() throws {
        let context = try makeContext()
        let publication = makePublication()
        let first = makeItem(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000111")!,
            publication: publication,
            location: "Gabinet"
        )
        let second = makeItem(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000112")!,
            publication: publication,
            location: "Salon"
        )
        insert(publication: publication, items: [first, second], into: context)
        let service = CatalogItemLifecycleService(modelContext: context)
        let firstReceipt = try service.delete(itemID: first.id)
        _ = try service.delete(itemID: second.id)

        XCTAssertThrowsError(try service.restore(firstReceipt)) { error in
            XCTAssertEqual(
                error as? CatalogItemLifecycleError,
                .expectedPublicationMissing(publication.id)
            )
        }
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<OwnedItem>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Publication>()), 0)
    }

    func testDeleteAndRestoreOrphanItemWithoutPublication() throws {
        let context = try makeContext()
        let itemID = UUID(uuidString: "00000000-0000-0000-0000-000000000113")!
        let item = OwnedItem(
            id: itemID,
            externalID: "orphan-copy-113",
            publication: nil,
            locationPathText: "Do naprawy / Pudło 1",
            status: .archived,
            notes: "Brak opisu po starym imporcie",
            addedAt: Date(timeIntervalSince1970: 1_720_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_730_000_000)
        )
        context.insert(item)
        try context.save()
        let service = CatalogItemLifecycleService(modelContext: context)

        let receipt = try service.delete(itemID: itemID)
        XCTAssertNil(receipt.publication)
        XCTAssertNil(receipt.item.publicationID)
        XCTAssertFalse(receipt.publicationWasDeleted)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<OwnedItem>()), 0)

        let result = try service.restore(receipt)
        XCTAssertNil(result.publication)
        XCTAssertNil(result.item.publication)
        XCTAssertEqual(result.item.id, itemID)
        XCTAssertEqual(result.item.externalID, "orphan-copy-113")
        XCTAssertEqual(result.item.locationPathText, "Do naprawy / Pudło 1")
        XCTAssertEqual(result.item.status, .archived)
        XCTAssertEqual(result.item.notes, "Brak opisu po starym imporcie")
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<OwnedItem>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Publication>()), 0)
    }

    func testLegacyBlankExternalIDsDoNotBlockRestoreWhenUnrelatedRecordsShareThem() throws {
        let context = try makeContext()
        let publication = makePublication()
        publication.externalID = "   "
        let item = makeItem(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000114")!,
            publication: publication,
            location: "Archiwum / Regał 1"
        )
        item.externalID = ""

        let unrelatedPublication = Publication(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000115")!,
            type: .book,
            title: "Inny stary rekord"
        )
        unrelatedPublication.externalID = "   "
        let unrelatedItem = OwnedItem(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000116")!,
            publication: unrelatedPublication,
            locationPathText: "Magazyn"
        )
        unrelatedItem.externalID = ""

        context.insert(publication)
        context.insert(item)
        context.insert(unrelatedPublication)
        context.insert(unrelatedItem)
        try context.save()

        let service = CatalogItemLifecycleService(modelContext: context)
        let receipt = try service.delete(itemID: item.id)
        XCTAssertTrue(receipt.publicationWasDeleted)
        XCTAssertEqual(receipt.item.externalID, "")
        XCTAssertEqual(receipt.publication?.externalID, "   ")

        let result = try service.restore(receipt)

        XCTAssertTrue(result.recreatedPublication)
        XCTAssertEqual(result.item.externalID, "")
        XCTAssertEqual(result.publication?.externalID, "   ")
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<OwnedItem>()), 2)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Publication>()), 2)
    }

    func testRestoreOrphanSaveFailureRollsBackInsertedItemCompletely() throws {
        enum ForcedFailure: Error { case save }

        let context = try makeContext()
        let item = OwnedItem(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000117")!,
            externalID: "orphan-copy-117",
            publication: nil,
            locationPathText: "Do opisania / Pudło 2",
            status: .archived,
            notes: "Historyczny sierota"
        )
        context.insert(item)
        try context.save()
        let receipt = try CatalogItemLifecycleService(modelContext: context)
            .delete(itemID: item.id)
        let failingService = CatalogItemLifecycleService(
            modelContext: context,
            saveChanges: { _ in throw ForcedFailure.save }
        )

        XCTAssertThrowsError(try failingService.restore(receipt)) { error in
            XCTAssertTrue(error is ForcedFailure)
        }
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<OwnedItem>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Publication>()), 0)

        let restored = try CatalogItemLifecycleService(modelContext: context).restore(receipt)
        XCTAssertEqual(restored.item.id, receipt.item.id)
        XCTAssertNil(restored.item.publication)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<OwnedItem>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Publication>()), 0)
    }

    func testRestoreLastCopySaveFailureRollsBackPublicationAndItemCompletely() throws {
        enum ForcedFailure: Error { case save }

        let context = try makeContext()
        let publication = makePublication()
        let item = makeItem(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000118")!,
            publication: publication,
            location: "Gabinet / Półka 8"
        )
        insert(publication: publication, items: [item], into: context)
        let receipt = try CatalogItemLifecycleService(modelContext: context)
            .delete(itemID: item.id)
        let failingService = CatalogItemLifecycleService(
            modelContext: context,
            saveChanges: { _ in throw ForcedFailure.save }
        )

        XCTAssertThrowsError(try failingService.restore(receipt)) { error in
            XCTAssertTrue(error is ForcedFailure)
        }
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<OwnedItem>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Publication>()), 0)

        let restored = try CatalogItemLifecycleService(modelContext: context).restore(receipt)
        XCTAssertTrue(restored.recreatedPublication)
        XCTAssertEqual(restored.item.id, receipt.item.id)
        XCTAssertEqual(restored.publication?.id, receipt.publication?.id)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<OwnedItem>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Publication>()), 1)
    }

    func testRestoreRejectsReceiptWithContradictoryPublicationIdentity() throws {
        let context = try makeContext()
        let publication = makePublication()
        let item = makeItem(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000119")!,
            publication: publication,
            location: "Gabinet"
        )
        insert(publication: publication, items: [item], into: context)
        let receipt = try CatalogItemLifecycleService(modelContext: context)
            .delete(itemID: item.id)
        let malformedItem = CatalogItemLifecycleOwnedItemSnapshot(
            id: receipt.item.id,
            externalID: receipt.item.externalID,
            publicationID: UUID(uuidString: "00000000-0000-0000-0000-000000000999")!,
            locationPathText: receipt.item.locationPathText,
            statusRawValue: receipt.item.statusRawValue,
            notes: receipt.item.notes,
            addedAt: receipt.item.addedAt,
            updatedAt: receipt.item.updatedAt
        )
        let malformedReceipt = CatalogItemDeletionReceipt(
            item: malformedItem,
            publication: receipt.publication,
            publicationWasDeleted: receipt.publicationWasDeleted
        )

        XCTAssertThrowsError(
            try CatalogItemLifecycleService(modelContext: context).restore(malformedReceipt)
        ) { error in
            XCTAssertEqual(error as? CatalogItemLifecycleError, .invalidReceipt)
        }
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<OwnedItem>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Publication>()), 0)
    }

    func testRestoreRejectsDeletedPublicationFlagWithoutPublicationSnapshot() throws {
        let context = try makeContext()
        let item = OwnedItem(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000120")!,
            externalID: "orphan-copy-120",
            publication: nil,
            locationPathText: "Archiwum"
        )
        context.insert(item)
        try context.save()
        let receipt = try CatalogItemLifecycleService(modelContext: context)
            .delete(itemID: item.id)
        let malformedReceipt = CatalogItemDeletionReceipt(
            item: receipt.item,
            publication: nil,
            publicationWasDeleted: true
        )

        XCTAssertThrowsError(
            try CatalogItemLifecycleService(modelContext: context).restore(malformedReceipt)
        ) { error in
            XCTAssertEqual(error as? CatalogItemLifecycleError, .invalidReceipt)
        }
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<OwnedItem>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Publication>()), 0)
    }

    private func makeContext() throws -> ModelContext {
        let schema = Schema([Publication.self, OwnedItem.self])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        return ModelContext(container)
    }

    private func makePublication() -> Publication {
        Publication(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000100")!,
            externalID: "publication-web-100",
            type: .periodical,
            title: "Przekrój",
            subtitle: "Wydanie kolekcjonerskie",
            authorsText: "Redakcja Przekroju; Jan Kowalski",
            language: "pl",
            publisher: "Przekrój sp. z o.o.",
            publicationYear: 2026,
            isbn13: "",
            issn: "0033-248X",
            ean: "9770033248007",
            barcode: "9770033248007",
            issueNumber: "8/2026",
            issueVolume: "82",
            issueDate: "2026-08",
            metadataSource: "scan",
            coverURLString: "https://covers.openlibrary.org/b/id/123-M.jpg",
            coverSource: "openlibrary",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_710_000_000)
        )
    }

    private func makeItem(
        id: UUID,
        publication: Publication,
        location: String
    ) -> OwnedItem {
        OwnedItem(
            id: id,
            externalID: "copy-\(id.uuidString)",
            publication: publication,
            locationPathText: location,
            status: .owned,
            notes: "",
            addedAt: Date(timeIntervalSince1970: 1_720_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_730_000_000)
        )
    }

    private func insert(
        publication: Publication,
        items: [OwnedItem],
        into context: ModelContext
    ) {
        context.insert(publication)
        for item in items {
            context.insert(item)
        }
        try! context.save()
    }

    private func assertFullPublicationSnapshot(
        _ snapshot: CatalogItemLifecyclePublicationSnapshot,
        equals publication: Publication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(snapshot.id, publication.id, file: file, line: line)
        XCTAssertEqual(snapshot.externalID, publication.externalID, file: file, line: line)
        XCTAssertEqual(snapshot.typeRawValue, publication.typeRawValue, file: file, line: line)
        XCTAssertEqual(snapshot.title, publication.title, file: file, line: line)
        XCTAssertEqual(snapshot.subtitle, publication.subtitle, file: file, line: line)
        XCTAssertEqual(snapshot.authorsText, publication.authorsText, file: file, line: line)
        XCTAssertEqual(snapshot.language, publication.language, file: file, line: line)
        XCTAssertEqual(snapshot.publisher, publication.publisher, file: file, line: line)
        XCTAssertEqual(snapshot.publicationYear, publication.publicationYear, file: file, line: line)
        XCTAssertEqual(snapshot.isbn13, publication.isbn13, file: file, line: line)
        XCTAssertEqual(snapshot.issn, publication.issn, file: file, line: line)
        XCTAssertEqual(snapshot.ean, publication.ean, file: file, line: line)
        XCTAssertEqual(snapshot.barcode, publication.barcode, file: file, line: line)
        XCTAssertEqual(snapshot.issueNumber, publication.issueNumber, file: file, line: line)
        XCTAssertEqual(snapshot.issueVolume, publication.issueVolume, file: file, line: line)
        XCTAssertEqual(snapshot.issueDate, publication.issueDate, file: file, line: line)
        XCTAssertEqual(snapshot.metadataSource, publication.metadataSource, file: file, line: line)
        XCTAssertEqual(snapshot.coverURLString, publication.coverURLString, file: file, line: line)
        XCTAssertEqual(snapshot.coverSource, publication.coverSource, file: file, line: line)
        XCTAssertEqual(snapshot.createdAt, publication.createdAt, file: file, line: line)
        XCTAssertEqual(snapshot.updatedAt, publication.updatedAt, file: file, line: line)
    }

    private func assertPublication(
        _ publication: Publication,
        equals snapshot: CatalogItemLifecyclePublicationSnapshot,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(publication.id, snapshot.id, file: file, line: line)
        XCTAssertEqual(publication.externalID, snapshot.externalID, file: file, line: line)
        XCTAssertEqual(publication.typeRawValue, snapshot.typeRawValue, file: file, line: line)
        XCTAssertEqual(publication.title, snapshot.title, file: file, line: line)
        XCTAssertEqual(publication.subtitle, snapshot.subtitle, file: file, line: line)
        XCTAssertEqual(publication.authorsText, snapshot.authorsText, file: file, line: line)
        XCTAssertEqual(publication.language, snapshot.language, file: file, line: line)
        XCTAssertEqual(publication.publisher, snapshot.publisher, file: file, line: line)
        XCTAssertEqual(publication.publicationYear, snapshot.publicationYear, file: file, line: line)
        XCTAssertEqual(publication.isbn13, snapshot.isbn13, file: file, line: line)
        XCTAssertEqual(publication.issn, snapshot.issn, file: file, line: line)
        XCTAssertEqual(publication.ean, snapshot.ean, file: file, line: line)
        XCTAssertEqual(publication.barcode, snapshot.barcode, file: file, line: line)
        XCTAssertEqual(publication.issueNumber, snapshot.issueNumber, file: file, line: line)
        XCTAssertEqual(publication.issueVolume, snapshot.issueVolume, file: file, line: line)
        XCTAssertEqual(publication.issueDate, snapshot.issueDate, file: file, line: line)
        XCTAssertEqual(publication.metadataSource, snapshot.metadataSource, file: file, line: line)
        XCTAssertEqual(publication.coverURLString, snapshot.coverURLString, file: file, line: line)
        XCTAssertEqual(publication.coverSource, snapshot.coverSource, file: file, line: line)
        XCTAssertEqual(publication.createdAt, snapshot.createdAt, file: file, line: line)
        XCTAssertEqual(publication.updatedAt, snapshot.updatedAt, file: file, line: line)
    }

    private func assertItem(
        _ item: OwnedItem,
        equals snapshot: CatalogItemLifecycleOwnedItemSnapshot,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(item.id, snapshot.id, file: file, line: line)
        XCTAssertEqual(item.externalID, snapshot.externalID, file: file, line: line)
        XCTAssertEqual(item.publication?.id, snapshot.publicationID, file: file, line: line)
        XCTAssertEqual(item.locationPathText, snapshot.locationPathText, file: file, line: line)
        XCTAssertEqual(item.statusRawValue, snapshot.statusRawValue, file: file, line: line)
        XCTAssertEqual(item.notes, snapshot.notes, file: file, line: line)
        XCTAssertEqual(item.addedAt, snapshot.addedAt, file: file, line: line)
        XCTAssertEqual(item.updatedAt, snapshot.updatedAt, file: file, line: line)
    }
}
