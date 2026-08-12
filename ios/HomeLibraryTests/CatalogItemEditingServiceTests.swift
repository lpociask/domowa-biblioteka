import SwiftData
import XCTest
@testable import HomeLibrary

@MainActor
final class CatalogItemEditingServiceTests: XCTestCase {
    func testEditPersistsBibliographyAndCopyFieldsWithoutChangingIdentity() throws {
        let context = try makeContext()
        let createdAt = Date(timeIntervalSince1970: 1_700_000_000)
        let addedAt = Date(timeIntervalSince1970: 1_710_000_000)
        let editedAt = Date(timeIntervalSince1970: 1_720_000_000)
        let publicationID = UUID(uuidString: "00000000-0000-0000-0000-000000000011")!
        let itemID = UUID(uuidString: "00000000-0000-0000-0000-000000000012")!
        let publication = Publication(
            id: publicationID,
            externalID: "publication-web-11",
            type: .book,
            title: "Solaris",
            authorsText: "Stanisław Lem",
            createdAt: createdAt,
            updatedAt: createdAt
        )
        let item = OwnedItem(
            id: itemID,
            externalID: "copy-web-12",
            publication: publication,
            locationPathText: "Gabinet",
            addedAt: addedAt,
            updatedAt: addedAt
        )
        context.insert(publication)
        context.insert(item)
        try context.save()

        let service = CatalogItemEditingService(modelContext: context)
        let prepared = try service.prepare(itemID: itemID)
        var draft = prepared.draft
        draft.publication.title = "Solaris — wydanie poprawione"
        draft.publication.subtitle = "Powieść"
        draft.publication.publisher = "Wydawnictwo Literackie"
        draft.publication.publicationYear = 2024
        draft.publication.isbn13 = "9788308084526"
        draft.item.locationPathText = " Dom//Gabinet › Regał  2 / Półka 3 "
        draft.item.status = .loaned
        draft.item.notes = "Pożyczone Annie"

        let result = try service.edit(prepared, draft: draft, editedAt: editedAt)

        XCTAssertEqual(result.before.publicationID, publicationID)
        XCTAssertEqual(result.after.publicationID, publicationID)
        XCTAssertEqual(result.before.itemID, itemID)
        XCTAssertEqual(result.after.itemID, itemID)
        XCTAssertEqual(publication.title, "Solaris — wydanie poprawione")
        XCTAssertEqual(publication.subtitle, "Powieść")
        XCTAssertEqual(publication.publisher, "Wydawnictwo Literackie")
        XCTAssertEqual(publication.publicationYear, 2024)
        XCTAssertEqual(publication.isbn13, "9788308084526")
        XCTAssertEqual(publication.updatedAt, editedAt)
        XCTAssertEqual(item.locationPathText, "Dom / Gabinet / Regał 2 / Półka 3")
        XCTAssertEqual(item.status, .loaned)
        XCTAssertEqual(item.notes, "Pożyczone Annie")
        XCTAssertEqual(item.updatedAt, editedAt)
        XCTAssertEqual(result.affectedCopyCount, 1)

        XCTAssertEqual(publication.id, publicationID)
        XCTAssertEqual(publication.externalID, "publication-web-11")
        XCTAssertEqual(publication.createdAt, createdAt)
        XCTAssertEqual(item.id, itemID)
        XCTAssertEqual(item.externalID, "copy-web-12")
        XCTAssertEqual(item.addedAt, addedAt)
    }

    func testMoveOnlyChangesCanonicalLocationAndUpdateDate() throws {
        let context = try makeContext()
        let baseline = Date(timeIntervalSince1970: 1_700_000_000)
        let movedAt = Date(timeIntervalSince1970: 1_730_000_000)
        let (publication, item) = try insertFixture(in: context, timestamp: baseline)
        let service = CatalogItemEditingService(modelContext: context)
        let prepared = try service.prepare(itemID: item.id)

        let result = try service.move(
            prepared,
            to: " Salon// Regał A › Półka 1 ",
            movedAt: movedAt
        )

        XCTAssertEqual(item.locationPathText, "Salon / Regał A / Półka 1")
        XCTAssertEqual(item.updatedAt, movedAt)
        XCTAssertEqual(item.notes, "Pierwsze wydanie")
        XCTAssertEqual(item.status, .owned)
        XCTAssertEqual(publication.title, "Solaris")
        XCTAssertEqual(publication.updatedAt, baseline)
        XCTAssertEqual(result.affectedCopyCount, 1)
        XCTAssertEqual(result.before.draft.item.locationPathText, "Gabinet / Regał 1")
        XCTAssertEqual(result.after.draft.item.locationPathText, "Salon / Regał A / Półka 1")
    }

    func testChangingEditionIdentityClearsOldCoverAndUndoRestoresIt() throws {
        let context = try makeContext()
        let baseline = Date(timeIntervalSince1970: 1_700_000_000)
        let editedAt = Date(timeIntervalSince1970: 1_710_000_000)
        let publication = Publication(
            type: .book,
            title: "Solaris",
            isbn13: "9788308068854",
            coverURLString: "https://covers.openlibrary.org/b/isbn/9788308068854-M.jpg?default=false",
            coverSource: "openlibrary",
            createdAt: baseline,
            updatedAt: baseline
        )
        let item = OwnedItem(
            publication: publication,
            locationPathText: "Gabinet",
            addedAt: baseline,
            updatedAt: baseline
        )
        context.insert(publication)
        context.insert(item)
        try context.save()

        let service = CatalogItemEditingService(modelContext: context)
        let prepared = try service.prepare(itemID: item.id)
        var draft = prepared.draft
        draft.publication.isbn13 = "9788308084526"

        let edit = try service.edit(prepared, draft: draft, editedAt: editedAt)

        XCTAssertEqual(publication.isbn13, "9788308084526")
        XCTAssertEqual(publication.coverURLString, "")
        XCTAssertEqual(publication.coverSource, "")

        _ = try service.undo(edit)

        XCTAssertEqual(publication.isbn13, "9788308068854")
        XCTAssertEqual(
            publication.coverURLString,
            "https://covers.openlibrary.org/b/isbn/9788308068854-M.jpg?default=false"
        )
        XCTAssertEqual(publication.coverSource, "openlibrary")
    }

    func testUndoRestoresExactBeforeStateAndReturnedUndoCanRedo() throws {
        let context = try makeContext()
        let baseline = Date(timeIntervalSince1970: 1_700_000_000)
        let editedAt = Date(timeIntervalSince1970: 1_740_000_000)
        let (publication, item) = try insertFixture(in: context, timestamp: baseline)
        let service = CatalogItemEditingService(modelContext: context)
        let prepared = try service.prepare(itemID: item.id)
        var draft = prepared.draft
        draft.publication.title = "Eden"
        draft.item.locationPathText = "Salon / Półka 4"
        draft.item.status = .archived

        let edit = try service.edit(prepared, draft: draft, editedAt: editedAt)
        let undo = try service.undo(edit)

        XCTAssertEqual(undo.after, edit.before)
        XCTAssertEqual(publication.title, "Solaris")
        XCTAssertEqual(publication.updatedAt, baseline)
        XCTAssertEqual(item.locationPathText, "Gabinet / Regał 1")
        XCTAssertEqual(item.status, .owned)
        XCTAssertEqual(item.updatedAt, baseline)

        let redo = try service.undo(undo)
        XCTAssertEqual(redo.after, edit.after)
        XCTAssertEqual(publication.title, "Eden")
        XCTAssertEqual(item.locationPathText, "Salon / Półka 4")
        XCTAssertEqual(item.status, .archived)
    }

    func testEditingSharedPublicationAffectsAllCopiesButMovesOnlyTargetCopy() throws {
        let context = try makeContext()
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let publication = Publication(
            type: .book,
            title: "Błędny tytuł",
            createdAt: timestamp,
            updatedAt: timestamp
        )
        let first = OwnedItem(
            publication: publication,
            locationPathText: "Gabinet / Półka 1",
            addedAt: timestamp,
            updatedAt: timestamp
        )
        let second = OwnedItem(
            publication: publication,
            locationPathText: "Salon / Półka 2",
            notes: "Drugi egzemplarz",
            addedAt: timestamp,
            updatedAt: timestamp
        )
        context.insert(publication)
        context.insert(first)
        context.insert(second)
        try context.save()
        let service = CatalogItemEditingService(modelContext: context)
        let prepared = try service.prepare(itemID: first.id)
        var draft = prepared.draft
        draft.publication.title = "Poprawny tytuł"
        draft.item.locationPathText = "Magazyn / Półka 9"

        let result = try service.edit(prepared, draft: draft, editedAt: timestamp.addingTimeInterval(60))

        XCTAssertEqual(result.affectedCopyCount, 2)
        XCTAssertEqual(first.publication?.title, "Poprawny tytuł")
        XCTAssertEqual(second.publication?.title, "Poprawny tytuł")
        XCTAssertEqual(first.locationPathText, "Magazyn / Półka 9")
        XCTAssertEqual(second.locationPathText, "Salon / Półka 2")
        XCTAssertEqual(second.notes, "Drugi egzemplarz")
    }

    func testUnknownItemDoesNotMutatePersistedCollection() throws {
        let context = try makeContext()
        let (publication, item) = try insertFixture(in: context)
        let service = CatalogItemEditingService(modelContext: context)
        let originalTitle = publication.title
        let originalLocation = item.locationPathText
        let unknownID = UUID(uuidString: "00000000-0000-0000-0000-000000000099")!

        XCTAssertThrowsError(try service.prepare(itemID: unknownID)) { error in
            XCTAssertEqual(error as? CatalogItemEditingError, .itemNotFound(unknownID))
        }

        XCTAssertEqual(publication.title, originalTitle)
        XCTAssertEqual(item.locationPathText, originalLocation)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Publication>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<OwnedItem>()), 1)
    }

    func testSaveFailureRollsBackAllEditedValues() throws {
        enum ForcedFailure: Error { case save }

        let context = try makeContext()
        let baseline = Date(timeIntervalSince1970: 1_700_000_000)
        let (_, item) = try insertFixture(in: context, timestamp: baseline)
        let service = CatalogItemEditingService(
            modelContext: context,
            saveChanges: { _ in throw ForcedFailure.save }
        )
        let prepared = try service.prepare(itemID: item.id)
        var draft = prepared.draft
        draft.publication.title = "Nie powinno zostać"
        draft.item.locationPathText = "Błędna lokalizacja"
        draft.item.notes = "Błędna notatka"

        XCTAssertThrowsError(try service.edit(
            prepared,
            draft: draft,
            editedAt: baseline.addingTimeInterval(60)
        )) { error in
            XCTAssertTrue(error is ForcedFailure)
        }

        let persistedPublication = try XCTUnwrap(try context.fetch(FetchDescriptor<Publication>()).first)
        let persistedItem = try XCTUnwrap(try context.fetch(FetchDescriptor<OwnedItem>()).first)
        XCTAssertEqual(persistedPublication.title, "Solaris")
        XCTAssertEqual(persistedPublication.updatedAt, baseline)
        XCTAssertEqual(persistedItem.locationPathText, "Gabinet / Regał 1")
        XCTAssertEqual(persistedItem.notes, "Pierwsze wydanie")
        XCTAssertEqual(persistedItem.updatedAt, baseline)
    }

    func testCopyCountFailureOccursBeforeMutationAndSave() throws {
        enum ForcedFailure: Error { case count }

        let context = try makeContext()
        let baseline = Date(timeIntervalSince1970: 1_700_000_000)
        let (publication, item) = try insertFixture(in: context, timestamp: baseline)
        let prepared = try CatalogItemEditingService(modelContext: context).prepare(itemID: item.id)
        var saveWasCalled = false
        let service = CatalogItemEditingService(
            modelContext: context,
            saveChanges: { context in
                saveWasCalled = true
                try context.save()
            },
            countCopies: { _, _ in throw ForcedFailure.count }
        )
        var draft = prepared.draft
        draft.publication.title = "Nie zapisuj"

        XCTAssertThrowsError(try service.edit(prepared, draft: draft)) { error in
            XCTAssertTrue(error is ForcedFailure)
        }
        XCTAssertFalse(saveWasCalled)
        XCTAssertEqual(publication.title, "Solaris")
        XCTAssertEqual(publication.updatedAt, baseline)
        XCTAssertEqual(item.updatedAt, baseline)
    }

    func testUndoConflictDoesNotOverwriteLaterEdit() throws {
        let context = try makeContext()
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let (publication, item) = try insertFixture(in: context, timestamp: timestamp)
        let service = CatalogItemEditingService(modelContext: context)
        let firstPrepared = try service.prepare(itemID: item.id)
        var firstDraft = firstPrepared.draft
        firstDraft.publication.title = "Eden"
        let firstEdit = try service.edit(
            firstPrepared,
            draft: firstDraft,
            editedAt: timestamp.addingTimeInterval(10)
        )
        let secondPrepared = try service.prepare(itemID: item.id)
        var secondDraft = secondPrepared.draft
        secondDraft.publication.title = "Niezwyciężony"
        secondDraft.item.notes = "Późniejsza poprawka"
        _ = try service.edit(
            secondPrepared,
            draft: secondDraft,
            editedAt: timestamp.addingTimeInterval(20)
        )

        XCTAssertThrowsError(try service.undo(firstEdit)) { error in
            XCTAssertEqual(error as? CatalogItemEditingError, .undoConflict(item.id))
        }
        XCTAssertEqual(publication.title, "Niezwyciężony")
        XCTAssertEqual(item.notes, "Późniejsza poprawka")
    }

    func testNoOpDoesNotSaveOrChangeTimestamps() throws {
        let context = try makeContext()
        let baseline = Date(timeIntervalSince1970: 1_700_000_000)
        let (publication, item) = try insertFixture(in: context, timestamp: baseline)
        var saveCount = 0
        let service = CatalogItemEditingService(
            modelContext: context,
            saveChanges: { context in
                saveCount += 1
                try context.save()
            }
        )
        let prepared = try service.prepare(itemID: item.id)

        let result = try service.edit(
            prepared,
            draft: prepared.draft,
            editedAt: baseline.addingTimeInterval(60)
        )

        XCTAssertFalse(result.didChange)
        XCTAssertEqual(result.affectedCopyCount, 0)
        XCTAssertEqual(saveCount, 0)
        XCTAssertEqual(publication.updatedAt, baseline)
        XCTAssertEqual(item.updatedAt, baseline)
    }

    func testStalePublicationEditIsRejectedWithoutOverwritingNewerData() throws {
        let context = try makeContext()
        let baseline = Date(timeIntervalSince1970: 1_700_000_000)
        let (publication, item) = try insertFixture(in: context, timestamp: baseline)
        let service = CatalogItemEditingService(modelContext: context)
        let prepared = try service.prepare(itemID: item.id)

        publication.title = "Nowsza wersja"
        publication.updatedAt = baseline.addingTimeInterval(10)
        try context.save()

        var staleDraft = prepared.draft
        staleDraft.publication.title = "Stara wersja formularza"
        XCTAssertThrowsError(try service.edit(
            prepared,
            draft: staleDraft,
            editedAt: baseline.addingTimeInterval(20)
        )) { error in
            XCTAssertEqual(error as? CatalogItemEditingError, .editConflict(item.id))
        }
        XCTAssertEqual(publication.title, "Nowsza wersja")
    }

    func testStaleMoveIsRejectedWithoutOverwritingNewerLocation() throws {
        let context = try makeContext()
        let baseline = Date(timeIntervalSince1970: 1_700_000_000)
        let (_, item) = try insertFixture(in: context, timestamp: baseline)
        let service = CatalogItemEditingService(modelContext: context)
        let prepared = try service.prepare(itemID: item.id)

        item.locationPathText = "Nowsza lokalizacja"
        item.updatedAt = baseline.addingTimeInterval(10)
        try context.save()

        XCTAssertThrowsError(try service.move(
            prepared,
            to: "Stara lokalizacja z formularza",
            movedAt: baseline.addingTimeInterval(20)
        )) { error in
            XCTAssertEqual(error as? CatalogItemEditingError, .editConflict(item.id))
        }
        XCTAssertEqual(item.locationPathText, "Nowsza lokalizacja")
    }

    func testMovePreservesIndependentNewerPublicationEdit() throws {
        let context = try makeContext()
        let baseline = Date(timeIntervalSince1970: 1_700_000_000)
        let (publication, item) = try insertFixture(in: context, timestamp: baseline)
        let service = CatalogItemEditingService(modelContext: context)
        let prepared = try service.prepare(itemID: item.id)

        publication.title = "Solaris — nowe opracowanie"
        publication.updatedAt = baseline.addingTimeInterval(10)
        try context.save()

        _ = try service.move(
            prepared,
            to: "Salon / Regał 7",
            movedAt: baseline.addingTimeInterval(20)
        )

        XCTAssertEqual(publication.title, "Solaris — nowe opracowanie")
        XCTAssertEqual(publication.updatedAt, baseline.addingTimeInterval(10))
        XCTAssertEqual(item.locationPathText, "Salon / Regał 7")
    }

    func testBibliographyEditPreservesIndependentNewerCopyEdit() throws {
        let context = try makeContext()
        let baseline = Date(timeIntervalSince1970: 1_700_000_000)
        let (publication, item) = try insertFixture(in: context, timestamp: baseline)
        let service = CatalogItemEditingService(modelContext: context)
        let prepared = try service.prepare(itemID: item.id)

        item.locationPathText = "Magazyn / Półka 8"
        item.notes = "Późniejsza notatka"
        item.updatedAt = baseline.addingTimeInterval(10)
        try context.save()

        var draft = prepared.draft
        draft.publication.title = "Eden"
        _ = try service.edit(
            prepared,
            draft: draft,
            editedAt: baseline.addingTimeInterval(20)
        )

        XCTAssertEqual(publication.title, "Eden")
        XCTAssertEqual(item.locationPathText, "Magazyn / Półka 8")
        XCTAssertEqual(item.notes, "Późniejsza notatka")
        XCTAssertEqual(item.updatedAt, baseline.addingTimeInterval(10))
    }

    func testBibliographyEditDoesNotNormalizeUntouchedLegacyCopyFields() throws {
        let context = try makeContext()
        let baseline = Date(timeIntervalSince1970: 1_700_000_000)
        let (publication, item) = try insertFixture(in: context, timestamp: baseline)
        item.locationPathText = " Gabinet//Regał 1 "
        item.notes = "  historyczna notatka  "
        try context.save()
        let service = CatalogItemEditingService(modelContext: context)
        let prepared = try service.prepare(itemID: item.id)
        var draft = prepared.draft
        draft.publication.title = "Eden"

        _ = try service.edit(
            prepared,
            draft: draft,
            editedAt: baseline.addingTimeInterval(20)
        )

        XCTAssertEqual(publication.title, "Eden")
        XCTAssertEqual(item.locationPathText, " Gabinet//Regał 1 ")
        XCTAssertEqual(item.notes, "  historyczna notatka  ")
        XCTAssertEqual(item.updatedAt, baseline)
    }

    func testTitleEditPreservesUntouchedLegacyInvalidBibliographicFields() throws {
        let context = try makeContext()
        let (publication, item) = try insertFixture(in: context)
        publication.isbn13 = "historyczny-bledny-isbn"
        publication.ean = "123"
        publication.issn = "stary-issn"
        publication.publicationYear = 0
        try context.save()
        let service = CatalogItemEditingService(modelContext: context)
        let prepared = try service.prepare(itemID: item.id)
        var draft = prepared.draft
        draft.publication.title = "Eden"

        _ = try service.edit(prepared, draft: draft)

        XCTAssertEqual(publication.title, "Eden")
        XCTAssertEqual(publication.isbn13, "historyczny-bledny-isbn")
        XCTAssertEqual(publication.ean, "123")
        XCTAssertEqual(publication.issn, "stary-issn")
        XCTAssertEqual(publication.publicationYear, 0)
    }

    func testRejectsInvalidBibliographicValuesWithoutMutation() throws {
        let context = try makeContext()
        let (publication, item) = try insertFixture(in: context)
        let service = CatalogItemEditingService(modelContext: context)
        let prepared = try service.prepare(itemID: item.id)

        var draft = prepared.draft
        draft.publication.title = "   "
        XCTAssertThrowsError(try service.edit(prepared, draft: draft)) { error in
            XCTAssertEqual(error as? CatalogItemEditingError, .invalidTitle)
        }

        draft = prepared.draft
        draft.publication.publicationYear = 10_000
        XCTAssertThrowsError(try service.edit(prepared, draft: draft)) { error in
            XCTAssertEqual(error as? CatalogItemEditingError, .invalidPublicationYear)
        }

        draft = prepared.draft
        draft.publication.isbn13 = "9780306406158"
        XCTAssertThrowsError(try service.edit(prepared, draft: draft)) { error in
            XCTAssertEqual(error as? CatalogItemEditingError, .invalidISBN)
        }

        draft = prepared.draft
        draft.publication.ean = "5901234123458"
        XCTAssertThrowsError(try service.edit(prepared, draft: draft)) { error in
            XCTAssertEqual(error as? CatalogItemEditingError, .invalidEAN)
        }

        draft = prepared.draft
        draft.publication.issn = "2049-3631"
        XCTAssertThrowsError(try service.edit(prepared, draft: draft)) { error in
            XCTAssertEqual(error as? CatalogItemEditingError, .invalidISSN)
        }

        draft = prepared.draft
        draft.publication.coverURLString = "http://covers.openlibrary.org/b/id/123-M.jpg"
        XCTAssertThrowsError(try service.edit(prepared, draft: draft)) { error in
            XCTAssertEqual(error as? CatalogItemEditingError, .invalidCoverURL)
        }

        XCTAssertEqual(publication.title, "Solaris")
        XCTAssertEqual(publication.isbn13, "")
    }

    func testRejectsSupplementEnteredOnlyInEANFieldWithoutLosingItSilently() throws {
        let context = try makeContext()
        let (publication, item) = try insertFixture(in: context)
        publication.publicationType = .periodical
        try context.save()
        let service = CatalogItemEditingService(modelContext: context)
        let prepared = try service.prepare(itemID: item.id)
        var draft = prepared.draft
        draft.publication.ean = "9770033248007+05"

        XCTAssertThrowsError(try service.edit(prepared, draft: draft)) { error in
            XCTAssertEqual(error as? CatalogItemEditingError, .invalidEAN)
        }
        XCTAssertEqual(publication.ean, "")
        XCTAssertEqual(publication.barcode, "")
    }

    func testNormalizesISBN10EANAndISSNBeforeSaving() throws {
        let context = try makeContext()
        let (publication, item) = try insertFixture(in: context)
        let service = CatalogItemEditingService(modelContext: context)
        let prepared = try service.prepare(itemID: item.id)
        var draft = prepared.draft
        draft.publication.isbn13 = "0-306-40615-2"
        draft.publication.ean = "590-1234-12345-7"
        draft.publication.issn = "20493630"

        _ = try service.edit(prepared, draft: draft)

        XCTAssertEqual(publication.isbn13, "9780306406157")
        XCTAssertEqual(publication.ean, "5901234123457")
        XCTAssertEqual(publication.issn, "2049-3630")
    }

    func testChangingOnlyEANRemovesCompositeBarcodeWithStaleMainCode() throws {
        let context = try makeContext()
        let (publication, item) = try insertFixture(in: context)
        publication.publicationType = .periodical
        publication.ean = "9770033248007"
        publication.barcode = "9770033248007+05"
        try context.save()
        let service = CatalogItemEditingService(modelContext: context)
        let prepared = try service.prepare(itemID: item.id)
        var draft = prepared.draft
        draft.publication.ean = "9771050124008"

        _ = try service.edit(prepared, draft: draft)

        XCTAssertEqual(publication.ean, "9771050124008")
        XCTAssertEqual(publication.barcode, "")
    }

    func testChangingOnlyEANRemovesBareBarcodeWithStaleMainCode() throws {
        let context = try makeContext()
        let (publication, item) = try insertFixture(in: context)
        publication.publicationType = .periodical
        publication.ean = "9770033248007"
        publication.barcode = "9770033248007"
        try context.save()
        let service = CatalogItemEditingService(modelContext: context)
        let prepared = try service.prepare(itemID: item.id)
        var draft = prepared.draft
        draft.publication.ean = "9771050124008"

        _ = try service.edit(prepared, draft: draft)

        XCTAssertEqual(publication.ean, "9771050124008")
        XCTAssertEqual(publication.barcode, "")
    }

    func testEditingCompositeBarcodeCanonicalizesItAndSynchronizesMainEAN() throws {
        let context = try makeContext()
        let (publication, item) = try insertFixture(in: context)
        publication.publicationType = .periodical
        publication.ean = "9770033248007"
        try context.save()
        let service = CatalogItemEditingService(modelContext: context)
        let prepared = try service.prepare(itemID: item.id)
        var draft = prepared.draft
        draft.publication.barcode = "9771050124008 12345"

        _ = try service.edit(prepared, draft: draft)

        XCTAssertEqual(publication.ean, "9771050124008")
        XCTAssertEqual(publication.barcode, "9771050124008+12345")
    }

    func testEditingBarePeriodicalBarcodeCanonicalizesItAndSynchronizesMainEAN() throws {
        let context = try makeContext()
        let (publication, item) = try insertFixture(in: context)
        publication.publicationType = .periodical
        publication.ean = "9770033248007"
        try context.save()
        let service = CatalogItemEditingService(modelContext: context)
        let prepared = try service.prepare(itemID: item.id)
        var draft = prepared.draft
        draft.publication.barcode = "977-1050-12400-8"

        _ = try service.edit(prepared, draft: draft)

        XCTAssertEqual(publication.ean, "9771050124008")
        XCTAssertEqual(publication.barcode, "9771050124008")
    }

    func testRejectsConflictingEditedEANAndCompositeBarcodeWithoutMutation() throws {
        let context = try makeContext()
        let baseline = Date(timeIntervalSince1970: 1_700_000_000)
        let (publication, item) = try insertFixture(in: context, timestamp: baseline)
        publication.publicationType = .periodical
        publication.ean = "9770033248007"
        publication.barcode = "9770033248007+05"
        try context.save()
        let service = CatalogItemEditingService(modelContext: context)
        let prepared = try service.prepare(itemID: item.id)
        var draft = prepared.draft
        draft.publication.ean = "9771050124008"
        draft.publication.barcode = "9770033248007+06"

        XCTAssertThrowsError(try service.edit(prepared, draft: draft)) { error in
            XCTAssertEqual(error as? CatalogItemEditingError, .periodicalEANConflict)
        }
        XCTAssertEqual(publication.ean, "9770033248007")
        XCTAssertEqual(publication.barcode, "9770033248007+05")
        XCTAssertEqual(publication.updatedAt, baseline)
    }

    func testRejectsConflictingEditedEANAndBarePeriodicalBarcodeWithoutMutation() throws {
        let context = try makeContext()
        let baseline = Date(timeIntervalSince1970: 1_700_000_000)
        let (publication, item) = try insertFixture(in: context, timestamp: baseline)
        publication.publicationType = .periodical
        publication.ean = "9770033248007"
        publication.barcode = "9770033248007"
        try context.save()
        let service = CatalogItemEditingService(modelContext: context)
        let prepared = try service.prepare(itemID: item.id)
        var draft = prepared.draft
        draft.publication.ean = "9771050124008"
        draft.publication.barcode = "977-0033-24800-7"

        XCTAssertThrowsError(try service.edit(prepared, draft: draft)) { error in
            XCTAssertEqual(error as? CatalogItemEditingError, .periodicalEANConflict)
        }
        XCTAssertEqual(publication.ean, "9770033248007")
        XCTAssertEqual(publication.barcode, "9770033248007")
        XCTAssertEqual(publication.updatedAt, baseline)
    }

    func testRejectsExplicitMalformedCompositeBarcodeWithoutMutation() throws {
        let context = try makeContext()
        let baseline = Date(timeIntervalSince1970: 1_700_000_000)
        let (publication, item) = try insertFixture(in: context, timestamp: baseline)
        publication.publicationType = .periodical
        publication.ean = "9770033248007"
        try context.save()
        let service = CatalogItemEditingService(modelContext: context)
        let prepared = try service.prepare(itemID: item.id)
        var draft = prepared.draft
        draft.publication.barcode = "9770033248007+123"

        XCTAssertThrowsError(try service.edit(prepared, draft: draft)) { error in
            XCTAssertEqual(error as? CatalogItemEditingError, .invalidPeriodicalBarcode)
        }
        XCTAssertEqual(publication.ean, "9770033248007")
        XCTAssertEqual(publication.barcode, "")
        XCTAssertEqual(publication.updatedAt, baseline)
    }

    func testTitleEditPreservesUntouchedHistoricalRawPeriodicalBarcode() throws {
        let context = try makeContext()
        let (publication, item) = try insertFixture(in: context)
        publication.publicationType = .periodical
        publication.ean = "historyczny-ean"
        publication.barcode = "kod dostawcy / zapis historyczny"
        try context.save()
        let service = CatalogItemEditingService(modelContext: context)
        let prepared = try service.prepare(itemID: item.id)
        var draft = prepared.draft
        draft.publication.title = "Nowy tytuł pisma"

        _ = try service.edit(prepared, draft: draft)

        XCTAssertEqual(publication.title, "Nowy tytuł pisma")
        XCTAssertEqual(publication.ean, "historyczny-ean")
        XCTAssertEqual(publication.barcode, "kod dostawcy / zapis historyczny")
    }

    func testRejectsIdentityCollisionWithAnotherPublication() throws {
        let context = try makeContext()
        let (publication, item) = try insertFixture(in: context)
        let conflicting = Publication(
            type: .book,
            title: "Inny rekord tej samej edycji",
            isbn13: "9780306406157"
        )
        context.insert(conflicting)
        try context.save()

        let service = CatalogItemEditingService(modelContext: context)
        let prepared = try service.prepare(itemID: item.id)
        var draft = prepared.draft
        draft.publication.isbn13 = "0-306-40615-2"

        XCTAssertThrowsError(try service.edit(prepared, draft: draft)) { error in
            XCTAssertEqual(
                error as? CatalogItemEditingError,
                .publicationIdentityConflict(conflicting.id)
            )
        }
        XCTAssertEqual(publication.isbn13, "")
    }

    func testRejectsSharedEANEvenWhenBooksHaveDifferentISBNs() throws {
        let context = try makeContext()
        let (publication, item) = try insertFixture(in: context)
        publication.isbn13 = "9788308084526"
        let conflicting = Publication(
            type: .book,
            title: "Inny rekord",
            isbn13: "9780306406157",
            ean: "5901234123457"
        )
        context.insert(conflicting)
        try context.save()
        let service = CatalogItemEditingService(modelContext: context)
        let prepared = try service.prepare(itemID: item.id)
        var draft = prepared.draft
        draft.publication.ean = "5901234123457"

        XCTAssertThrowsError(try service.edit(prepared, draft: draft)) { error in
            XCTAssertEqual(
                error as? CatalogItemEditingError,
                .publicationIdentityConflict(conflicting.id)
            )
        }
        XCTAssertEqual(publication.ean, "")
    }

    func testAllowsSharedBaseEAN977WithoutConcretePeriodicalIssueIdentity() throws {
        let context = try makeContext()
        let (publication, item) = try insertFixture(in: context)
        publication.publicationType = .periodical
        publication.title = "Miesięcznik A"
        let conflicting = Publication(
            type: .periodical,
            title: "Miesięcznik B",
            ean: "9770033248007",
            issueNumber: "2/2026"
        )
        context.insert(conflicting)
        try context.save()
        let service = CatalogItemEditingService(modelContext: context)
        let prepared = try service.prepare(itemID: item.id)
        var draft = prepared.draft
        draft.publication.ean = "9770033248007"

        _ = try service.edit(prepared, draft: draft)

        XCTAssertEqual(publication.ean, "9770033248007")
    }

    func testRejectsExactPeriodicalCompositeBarcodeCollisionWithoutIssueFields() throws {
        let context = try makeContext()
        let (publication, item) = try insertFixture(in: context)
        publication.publicationType = .periodical
        publication.title = "Miesięcznik A"
        let conflicting = Publication(
            type: .periodical,
            title: "Miesięcznik B",
            ean: "9770033248007",
            barcode: "9770033248007+05"
        )
        context.insert(conflicting)
        try context.save()
        let service = CatalogItemEditingService(modelContext: context)
        let prepared = try service.prepare(itemID: item.id)
        var draft = prepared.draft
        draft.publication.ean = "9770033248007"
        draft.publication.barcode = "9770033248007+05"

        XCTAssertThrowsError(try service.edit(prepared, draft: draft)) { error in
            XCTAssertEqual(
                error as? CatalogItemEditingError,
                .publicationIdentityConflict(conflicting.id)
            )
        }
        XCTAssertEqual(publication.ean, "")
        XCTAssertEqual(publication.barcode, "")
    }

    func testDifferentPeriodicalSupplementsOverrideMatchingISSNAndIssueFields() throws {
        let context = try makeContext()
        let (publication, item) = try insertFixture(in: context)
        publication.publicationType = .periodical
        publication.title = "Miesięcznik A"
        publication.issn = "0033-2488"
        publication.issueNumber = "8/2026"
        let conflicting = Publication(
            type: .periodical,
            title: "Miesięcznik B",
            issn: "0033-2488",
            ean: "9770033248007",
            barcode: "9770033248007+05",
            issueNumber: "8/2026"
        )
        context.insert(conflicting)
        try context.save()
        let service = CatalogItemEditingService(modelContext: context)
        let prepared = try service.prepare(itemID: item.id)
        var draft = prepared.draft
        draft.publication.ean = "9770033248007"
        draft.publication.barcode = "9770033248007+06"

        _ = try service.edit(prepared, draft: draft)

        XCTAssertEqual(publication.ean, "9770033248007")
        XCTAssertEqual(publication.barcode, "9770033248007+06")
    }

    func testDifferentExplicitMainEANsOverrideMatchingSupplementISSNAndIssueFields() throws {
        let context = try makeContext()
        let (publication, item) = try insertFixture(in: context)
        publication.publicationType = .periodical
        publication.title = "Miesięcznik A"
        publication.issn = "0033-2488"
        publication.issueNumber = "8/2026"
        let otherMainEAN = Publication(
            type: .periodical,
            title: "Miesięcznik B",
            issn: "0033-2488",
            ean: "9770033248014",
            barcode: "9770033248014+05",
            issueNumber: "8/2026"
        )
        context.insert(otherMainEAN)
        try context.save()
        let service = CatalogItemEditingService(modelContext: context)
        let prepared = try service.prepare(itemID: item.id)
        var draft = prepared.draft
        draft.publication.ean = "9770033248007"
        draft.publication.barcode = "9770033248007+05"

        _ = try service.edit(prepared, draft: draft)

        XCTAssertEqual(publication.ean, "9770033248007")
        XCTAssertEqual(publication.barcode, "9770033248007+05")
    }

    func testIdentityConflictChoosesDeterministicLowestUUID() throws {
        let context = try makeContext()
        let (_, item) = try insertFixture(in: context)
        let lowerID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let higherID = UUID(uuidString: "00000000-0000-0000-0000-000000000099")!
        context.insert(Publication(
            id: higherID,
            type: .book,
            title: "Duplikat B",
            isbn13: "9780306406157"
        ))
        context.insert(Publication(
            id: lowerID,
            type: .book,
            title: "Duplikat A",
            isbn13: "9780306406157"
        ))
        try context.save()
        let service = CatalogItemEditingService(modelContext: context)
        let prepared = try service.prepare(itemID: item.id)
        var draft = prepared.draft
        draft.publication.isbn13 = "9780306406157"

        XCTAssertThrowsError(try service.edit(prepared, draft: draft)) { error in
            XCTAssertEqual(error as? CatalogItemEditingError, .publicationIdentityConflict(lowerID))
        }
    }

    func testDuplicateItemUUIDIsRejectedDeterministically() throws {
        let context = try makeContext()
        let duplicateID = UUID(uuidString: "00000000-0000-0000-0000-000000000077")!
        let firstPublication = Publication(type: .book, title: "Pierwsza")
        let secondPublication = Publication(type: .book, title: "Druga")
        context.insert(firstPublication)
        context.insert(secondPublication)
        context.insert(OwnedItem(
            id: duplicateID,
            externalID: "copy-a",
            publication: firstPublication,
            locationPathText: "Gabinet"
        ))
        context.insert(OwnedItem(
            id: duplicateID,
            externalID: "copy-b",
            publication: secondPublication,
            locationPathText: "Salon"
        ))
        try context.save()
        let service = CatalogItemEditingService(modelContext: context)

        XCTAssertThrowsError(try service.prepare(itemID: duplicateID)) { error in
            XCTAssertEqual(error as? CatalogItemEditingError, .editConflict(duplicateID))
        }
    }

    func testDuplicatePublicationUUIDIsRejectedWhenPreparingEdit() throws {
        let context = try makeContext()
        let duplicatePublicationID = UUID(
            uuidString: "00000000-0000-0000-0000-000000000078"
        )!
        let firstPublication = Publication(
            id: duplicatePublicationID,
            externalID: "publication-a",
            type: .book,
            title: "Pierwsza publikacja"
        )
        let secondPublication = Publication(
            id: duplicatePublicationID,
            externalID: "publication-b",
            type: .book,
            title: "Druga publikacja"
        )
        let item = OwnedItem(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000079")!,
            publication: firstPublication,
            locationPathText: "Gabinet / Półka 1"
        )
        context.insert(firstPublication)
        context.insert(secondPublication)
        context.insert(item)
        try context.save()

        XCTAssertThrowsError(
            try CatalogItemEditingService(modelContext: context).prepare(itemID: item.id)
        ) { error in
            XCTAssertEqual(error as? CatalogItemEditingError, .editConflict(item.id))
        }
        XCTAssertEqual(firstPublication.title, "Pierwsza publikacja")
        XCTAssertEqual(secondPublication.title, "Druga publikacja")
    }

    func testUndoRejectsReceiptWhoseBeforeSnapshotBelongsToAnotherItem() throws {
        let context = try makeContext()
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let (firstPublication, firstItem) = try insertFixture(
            in: context,
            timestamp: timestamp
        )
        let secondPublication = Publication(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000080")!,
            externalID: "publication-80",
            type: .book,
            title: "Druga publikacja",
            createdAt: timestamp,
            updatedAt: timestamp
        )
        let secondItem = OwnedItem(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000081")!,
            externalID: "copy-81",
            publication: secondPublication,
            locationPathText: "Salon / Półka 2",
            addedAt: timestamp,
            updatedAt: timestamp
        )
        context.insert(secondPublication)
        context.insert(secondItem)
        try context.save()

        let service = CatalogItemEditingService(modelContext: context)
        let firstPrepared = try service.prepare(itemID: firstItem.id)
        var firstDraft = firstPrepared.draft
        firstDraft.publication.title = "Eden"
        let firstEdit = try service.edit(
            firstPrepared,
            draft: firstDraft,
            editedAt: timestamp.addingTimeInterval(10)
        )

        let secondPrepared = try service.prepare(itemID: secondItem.id)
        var secondDraft = secondPrepared.draft
        secondDraft.publication.title = "Druga publikacja po zmianie"
        let secondEdit = try service.edit(
            secondPrepared,
            draft: secondDraft,
            editedAt: timestamp.addingTimeInterval(20)
        )

        let malformedReceipt = CatalogItemEditResult(
            before: secondEdit.before,
            after: firstEdit.after,
            affectedCopyCount: firstEdit.affectedCopyCount
        )

        XCTAssertThrowsError(try service.undo(malformedReceipt)) { error in
            XCTAssertEqual(error as? CatalogItemEditingError, .undoConflict(firstItem.id))
        }
        XCTAssertEqual(firstPublication.title, "Eden")
        XCTAssertEqual(firstPublication.updatedAt, timestamp.addingTimeInterval(10))
        XCTAssertEqual(firstItem.locationPathText, "Gabinet / Regał 1")
        XCTAssertEqual(secondPublication.title, "Druga publikacja po zmianie")
        XCTAssertEqual(secondPublication.updatedAt, timestamp.addingTimeInterval(20))
    }

    func testMoveIgnoresUncommittedBibliographyInPreparedDraft() throws {
        let context = try makeContext()
        let (publication, item) = try insertFixture(in: context)
        let service = CatalogItemEditingService(modelContext: context)
        var prepared = try service.prepare(itemID: item.id)
        prepared.draft.publication.title = "Nie zapisuj tego"

        _ = try service.move(prepared, to: "Salon / Półka 2")

        XCTAssertEqual(publication.title, "Solaris")
        XCTAssertEqual(item.locationPathText, "Salon / Półka 2")
    }

    func testUndoPublicationEditPreservesLaterMove() throws {
        let context = try makeContext()
        let baseline = Date(timeIntervalSince1970: 1_700_000_000)
        let (publication, item) = try insertFixture(in: context, timestamp: baseline)
        let service = CatalogItemEditingService(modelContext: context)
        let prepared = try service.prepare(itemID: item.id)
        var draft = prepared.draft
        draft.publication.title = "Eden"
        let edit = try service.edit(
            prepared,
            draft: draft,
            editedAt: baseline.addingTimeInterval(10)
        )
        let movePrepared = try service.prepare(itemID: item.id)
        _ = try service.move(
            movePrepared,
            to: "Salon / Regał 4",
            movedAt: baseline.addingTimeInterval(20)
        )

        _ = try service.undo(edit)

        XCTAssertEqual(publication.title, "Solaris")
        XCTAssertEqual(item.locationPathText, "Salon / Regał 4")
        XCTAssertEqual(item.updatedAt, baseline.addingTimeInterval(20))
    }

    func testUndoAndRedoMovePreserveLaterPublicationEdit() throws {
        let context = try makeContext()
        let baseline = Date(timeIntervalSince1970: 1_700_000_000)
        let (publication, item) = try insertFixture(in: context, timestamp: baseline)
        let service = CatalogItemEditingService(modelContext: context)
        let movePrepared = try service.prepare(itemID: item.id)
        let move = try service.move(
            movePrepared,
            to: "Salon / Regał 9",
            movedAt: baseline.addingTimeInterval(10)
        )
        let editPrepared = try service.prepare(itemID: item.id)
        var draft = editPrepared.draft
        draft.publication.title = "Eden"
        _ = try service.edit(
            editPrepared,
            draft: draft,
            editedAt: baseline.addingTimeInterval(20)
        )

        let undo = try service.undo(move)
        XCTAssertEqual(item.locationPathText, "Gabinet / Regał 1")
        XCTAssertEqual(publication.title, "Eden")

        _ = try service.undo(undo)
        XCTAssertEqual(item.locationPathText, "Salon / Regał 9")
        XCTAssertEqual(publication.title, "Eden")
        XCTAssertEqual(publication.updatedAt, baseline.addingTimeInterval(20))
    }

    func testUndoRejectsRestoringIdentifierTakenByAnotherPublication() throws {
        let context = try makeContext()
        let (publication, item) = try insertFixture(in: context)
        publication.isbn13 = "9780306406157"
        try context.save()
        let service = CatalogItemEditingService(modelContext: context)
        let prepared = try service.prepare(itemID: item.id)
        var draft = prepared.draft
        draft.publication.isbn13 = "9788308084526"
        let edit = try service.edit(prepared, draft: draft)

        let conflicting = Publication(
            type: .book,
            title: "Nowy właściciel starego ISBN",
            isbn13: "9780306406157"
        )
        context.insert(conflicting)
        try context.save()

        XCTAssertThrowsError(try service.undo(edit)) { error in
            XCTAssertEqual(error as? CatalogItemEditingError, .undoConflict(item.id))
        }
        XCTAssertEqual(publication.isbn13, "9788308084526")
    }

    private func insertFixture(
        in context: ModelContext,
        timestamp: Date = Date(timeIntervalSince1970: 1_700_000_000)
    ) throws -> (Publication, OwnedItem) {
        let publication = Publication(
            type: .book,
            title: "Solaris",
            authorsText: "Stanisław Lem",
            metadataSource: "manual",
            createdAt: timestamp,
            updatedAt: timestamp
        )
        let item = OwnedItem(
            publication: publication,
            locationPathText: "Gabinet / Regał 1",
            notes: "Pierwsze wydanie",
            addedAt: timestamp,
            updatedAt: timestamp
        )
        context.insert(publication)
        context.insert(item)
        try context.save()
        return (publication, item)
    }

    private func makeContext() throws -> ModelContext {
        let schema = Schema([Publication.self, OwnedItem.self])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        return ModelContext(container)
    }
}
