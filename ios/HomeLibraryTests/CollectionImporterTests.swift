import Foundation
import SwiftData
import XCTest
@testable import HomeLibrary

@MainActor
final class CollectionImporterTests: XCTestCase {
    func testImportsWebIDsMultipleCopiesAndReconstructsLocationPathIdempotently() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let data = canonicalData(
            collectionID: "demo",
            collectionName: "Demo",
            locations: """
            [
              { "id": "room", "name": "Czytelnia", "type": "room", "parentId": null },
              { "id": "shelf", "name": "Półka A", "type": "shelf", "parentId": "room" }
            ]
            """,
            publications: """
            [
              {
                "id": "pub-solaris-demo",
                "type": "book",
                "title": " Solaris ",
                "authors": ["Stanisław Lem"],
                "language": "pl",
                "publicationYear": 1961,
                "identifiers": { "isbn13": "9780000000002" },
                "metadata": {
                  "source": "Dane demonstracyjne",
                  "coverUrl": "https://covers.openlibrary.org/b/isbn/9780000000002-M.jpg?default=false",
                  "coverSource": "openlibrary",
                  "description": "Dodatkowe pole z WWW jest dozwolone",
                  "subjects": ["science fiction"]
                },
                "createdAt": "2026-08-11T10:00:00.123Z",
                "updatedAt": "2026-08-11T11:00:00Z"
              }
            ]
            """,
            ownedItems: """
            [
              {
                "id": "copy-solaris-1",
                "publicationId": "pub-solaris-demo",
                "locationId": "shelf",
                "locationPath": [],
                "status": "owned",
                "notes": null,
                "addedAt": "2026-08-11T12:00:00.000Z",
                "updatedAt": "2026-08-11T12:00:00Z"
              },
              {
                "id": "copy-solaris-2",
                "publicationId": "pub-solaris-demo",
                "locationId": null,
                "locationPath": ["Dom", "Gabinet"],
                "status": "loaned",
                "notes": "Drugi egzemplarz",
                "addedAt": "2027-01-15T08:00:00Z",
                "updatedAt": "2027-01-15T09:00:00Z"
              }
            ]
            """
        )

        let first = try CollectionImporter.importCollection(data: data, into: context)
        XCTAssertEqual(
            first,
            CollectionImportReport(
                collectionID: "demo",
                collectionName: "Demo",
                addedPublications: 1,
                skippedPublications: 0,
                addedItems: 2,
                skippedItems: 0
            )
        )

        let publications = try context.fetch(FetchDescriptor<Publication>())
        let items = try context.fetch(FetchDescriptor<OwnedItem>())
        XCTAssertEqual(publications.count, 1)
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(publications[0].id, CollectionImporter.publicationUUID(for: "pub-solaris-demo"))
        XCTAssertEqual(publications[0].externalID, "pub-solaris-demo")
        XCTAssertEqual(publications[0].title, "Solaris")
        XCTAssertEqual(publications[0].metadataSource, "Dane demonstracyjne")
        XCTAssertEqual(
            publications[0].coverURLString,
            "https://covers.openlibrary.org/b/isbn/9780000000002-M.jpg?default=false"
        )
        XCTAssertEqual(publications[0].coverSource, "openlibrary")
        XCTAssertEqual(publications[0].createdAt.timeIntervalSince1970, 1_786_442_400.123, accuracy: 0.001)
        XCTAssertEqual(publications[0].updatedAt.timeIntervalSince1970, 1_786_446_000, accuracy: 0.001)

        let firstCopy = try XCTUnwrap(items.first { $0.id == CollectionImporter.ownedItemUUID(for: "copy-solaris-1") })
        let secondCopy = try XCTUnwrap(items.first { $0.id == CollectionImporter.ownedItemUUID(for: "copy-solaris-2") })
        XCTAssertEqual(firstCopy.externalID, "copy-solaris-1")
        XCTAssertEqual(firstCopy.locationPath, ["Czytelnia", "Półka A"])
        XCTAssertEqual(secondCopy.locationPath, ["Dom", "Gabinet"])
        XCTAssertEqual(secondCopy.status, .loaned)
        XCTAssertEqual(secondCopy.addedAt, isoDate("2027-01-15T08:00:00Z"))
        XCTAssertEqual(firstCopy.publication?.id, secondCopy.publication?.id)

        let second = try CollectionImporter.importCollection(data: data, into: context)
        XCTAssertEqual(
            second,
            CollectionImportReport(
                collectionID: "demo",
                collectionName: "Demo",
                addedPublications: 0,
                skippedPublications: 1,
                addedItems: 0,
                skippedItems: 2
            )
        )
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Publication>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<OwnedItem>()), 2)
    }

    func testPreservesNativeUUIDsAndDoesNotOverwriteExistingData() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let publicationID = UUID(uuidString: "05B33F9E-7D0F-43A8-A135-4D826AFC9F9E")!
        let itemID = UUID(uuidString: "FDCB78F6-8438-4EA8-9B77-5C390FDC50A1")!
        let localPublication = Publication(id: publicationID, type: .book, title: "Lokalny tytuł")
        let localItem = OwnedItem(
            id: itemID,
            publication: localPublication,
            locationPathText: "Dom / Regał",
            notes: "Lokalna notatka"
        )
        context.insert(localPublication)
        context.insert(localItem)
        try context.save()

        let data = canonicalData(
            publications: """
            [
              {
                "id": "05b33f9e-7d0f-43a8-a135-4d826afc9f9e",
                "type": "book",
                "title": "Tytuł z importu",
                "authors": [],
                "identifiers": {},
                "createdAt": "2026-08-11T10:00:00Z",
                "updatedAt": "2026-08-11T10:00:00Z"
              }
            ]
            """,
            ownedItems: """
            [
              {
                "id": "FDCB78F6-8438-4EA8-9B77-5C390FDC50A1",
                "publicationId": "05b33f9e-7d0f-43a8-a135-4d826afc9f9e",
                "locationPath": ["Inne miejsce"],
                "status": "archived",
                "notes": "Notatka z importu",
                "addedAt": "2026-08-11T10:00:00Z",
                "updatedAt": "2026-08-11T10:00:00Z"
              }
            ]
            """
        )

        XCTAssertEqual(CollectionImporter.publicationUUID(for: publicationID.uuidString), publicationID)
        XCTAssertEqual(CollectionImporter.ownedItemUUID(for: itemID.uuidString), itemID)

        let report = try CollectionImporter.importCollection(data: data, into: context)
        XCTAssertEqual(report.collectionID, "collection-test")
        XCTAssertEqual(report.collectionName, "Kolekcja testowa")
        XCTAssertEqual(report.addedPublications, 0)
        XCTAssertEqual(report.skippedPublications, 1)
        XCTAssertEqual(report.addedItems, 0)
        XCTAssertEqual(report.skippedItems, 1)
        XCTAssertEqual(localPublication.title, "Lokalny tytuł")
        XCTAssertEqual(localItem.locationPath, ["Dom", "Regał"])
        XCTAssertEqual(localItem.status, .owned)
        XCTAssertEqual(localItem.notes, "Lokalna notatka")
    }

    func testRejectsUnsupportedSchemaBeforeRequiringRemainingFields() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let data = jsonData(
            """
            {
              "schemaVersion": 2,
              "publications": [],
              "ownedItems": []
            }
            """
        )

        XCTAssertThrowsError(try CollectionImporter.importCollection(data: data, into: context)) { error in
            XCTAssertEqual(error as? CollectionImportError, .unsupportedSchema(2))
        }
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Publication>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<OwnedItem>()), 0)
    }

    func testRejectsBrokenPublicationReferenceBeforeChangingDatabase() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let data = canonicalData(
            publications: """
            [
              {
                "id": "pub-one",
                "type": "book",
                "title": "Poprawna publikacja",
                "authors": [],
                "identifiers": {},
                "createdAt": "2026-08-11T10:00:00Z",
                "updatedAt": "2026-08-11T10:00:00Z"
              }
            ]
            """,
            ownedItems: """
            [
              {
                "id": "copy-one",
                "publicationId": "pub-missing",
                "locationPath": [],
                "status": "owned",
                "addedAt": "2026-08-11T10:00:00Z",
                "updatedAt": "2026-08-11T10:00:00Z"
              }
            ]
            """
        )

        XCTAssertThrowsError(try CollectionImporter.importCollection(data: data, into: context)) { error in
            XCTAssertEqual(
                error as? CollectionImportError,
                .missingPublication(itemID: "copy-one", publicationID: "pub-missing")
            )
        }
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Publication>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<OwnedItem>()), 0)
    }

    func testRejectsIncompleteCanonicalPayload() {
        let data = jsonData(
            """
            {
              "schemaVersion": 1,
              "collection": { "id": "test", "name": "Test" },
              "locations": [],
              "publications": [],
              "ownedItems": []
            }
            """
        )

        XCTAssertThrowsError(try CollectionImporter.prepare(data: data)) { error in
            guard case .invalidJSON(let reason) = error as? CollectionImportError else {
                return XCTFail("Oczekiwano invalidJSON, otrzymano \(error)")
            }
            XCTAssertTrue(reason.contains("exportedAt"))
        }
    }

    func testRejectsPublicationMissingRequiredSchemaFields() {
        let data = canonicalData(
            publications: """
            [
              {
                "id": "pub-incomplete",
                "type": "book",
                "title": "Brakuje autorów",
                "identifiers": {},
                "createdAt": "2026-08-11T10:00:00Z",
                "updatedAt": "2026-08-11T10:00:00Z"
              }
            ]
            """,
            ownedItems: """
            [
              {
                "id": "copy-incomplete",
                "publicationId": "pub-incomplete",
                "locationPath": [],
                "status": "owned",
                "addedAt": "2026-08-11T10:00:00Z",
                "updatedAt": "2026-08-11T10:00:00Z"
              }
            ]
            """
        )

        XCTAssertThrowsError(try CollectionImporter.prepare(data: data)) { error in
            guard case .invalidJSON(let reason) = error as? CollectionImportError else {
                return XCTFail("Oczekiwano invalidJSON, otrzymano \(error)")
            }
            XCTAssertTrue(reason.contains("authors"))
        }
    }

    func testDropsUnsafeLegacyCoverWithoutRejectingCanonicalPayload() throws {
        let invalidURLs = [
            "http://covers.openlibrary.org/b/id/123-M.jpg",
            "file:///private/var/mobile/cover.jpg",
            "https://user:secret@covers.openlibrary.org/b/id/123-M.jpg"
        ]

        for coverURL in invalidURLs {
            let data = canonicalData(
                publications: """
                [
                  {
                    "id": "pub-cover",
                    "type": "book",
                    "title": "Okładka testowa",
                    "authors": [],
                    "identifiers": {},
                    "metadata": {
                      "source": "import",
                      "coverUrl": "\(coverURL)",
                      "coverSource": "legacy"
                    },
                    "createdAt": "2026-08-11T10:00:00Z",
                    "updatedAt": "2026-08-11T10:00:00Z"
                  }
                ]
                """,
                ownedItems: """
                [
                  {
                    "id": "copy-cover",
                    "publicationId": "pub-cover",
                    "locationPath": [],
                    "status": "owned",
                    "addedAt": "2026-08-11T10:00:00Z",
                    "updatedAt": "2026-08-11T10:00:00Z"
                  }
                ]
                """
            )

            let container = try makeContainer()
            let context = container.mainContext
            let report = try CollectionImporter.importCollection(data: data, into: context)
            let publication = try XCTUnwrap(context.fetch(FetchDescriptor<Publication>()).first)

            XCTAssertEqual(report.addedPublications, 1, coverURL)
            XCTAssertEqual(publication.title, "Okładka testowa", coverURL)
            XCTAssertEqual(publication.coverURLString, "", coverURL)
            XCTAssertEqual(publication.coverSource, "", coverURL)
        }
    }

    func testDropsLegacyCoverFieldsWithUnexpectedJSONTypes() throws {
        let data = canonicalData(
            publications: """
            [
              {
                "id": "pub-cover-types",
                "type": "book",
                "title": "Stary eksport",
                "authors": [],
                "identifiers": {},
                "metadata": {
                  "source": "import",
                  "coverUrl": { "legacy": "local-cache-key" },
                  "coverSource": ["legacy"]
                },
                "createdAt": "2026-08-11T10:00:00Z",
                "updatedAt": "2026-08-11T10:00:00Z"
              }
            ]
            """,
            ownedItems: """
            [
              {
                "id": "copy-cover-types",
                "publicationId": "pub-cover-types",
                "locationPath": [],
                "status": "owned",
                "addedAt": "2026-08-11T10:00:00Z",
                "updatedAt": "2026-08-11T10:00:00Z"
              }
            ]
            """
        )
        let container = try makeContainer()
        let context = container.mainContext

        let report = try CollectionImporter.importCollection(data: data, into: context)
        let publication = try XCTUnwrap(context.fetch(FetchDescriptor<Publication>()).first)

        XCTAssertEqual(report.addedPublications, 1)
        XCTAssertEqual(publication.title, "Stary eksport")
        XCTAssertEqual(publication.coverURLString, "")
        XCTAssertEqual(publication.coverSource, "")
    }

    func testRejectsNonexistentOverflowingAndInvalidOffsetDates() {
        let invalidDates = [
            "2026-02-29T10:00:00Z",
            "1900-02-29T10:00:00Z",
            "2026-04-31T10:00:00Z",
            "0000-01-01T00:00:00Z",
            "2026-13-01T00:00:00Z",
            "2026-01-01T24:00:00Z",
            "2026-01-01T00:60:00Z",
            "2026-01-01T00:00:60Z",
            "2026-01-01T00:00:00+24:00",
            "2026-01-01T00:00:00-24:00",
            "2026-01-01T00:00:00+01:60",
            "999999999999-01-01T00:00:00Z",
            "2026-01-01T999999999999:00:00Z",
            "2026-01-01T00:00:00.Z",
            "2026-01-01T00:00:00"
        ]

        for invalidDate in invalidDates {
            let data = canonicalData(exportedAt: invalidDate)
            XCTAssertThrowsError(try CollectionImporter.prepare(data: data), invalidDate) { error in
                guard case .invalidJSON(let reason) = error as? CollectionImportError else {
                    return XCTFail("Oczekiwano invalidJSON dla \(invalidDate), otrzymano \(error)")
                }
                XCTAssertTrue(reason.contains(invalidDate), reason)
                XCTAssertTrue(reason.contains("exportedAt"), reason)
            }
        }
    }

    func testAcceptsLeapDayZOffsetsAndFractionalSecondsMatchingWebPrecision() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let data = canonicalData(
            exportedAt: "2000-02-29T23:59:59.0+23:59",
            publications: """
            [
              {
                "id": "pub-dates",
                "type": "book",
                "title": "Daty",
                "authors": [],
                "identifiers": {},
                "createdAt": "2026-08-11T14:00:00.123456789+02:00",
                "updatedAt": "2026-08-11T06:30:00.5-05:30"
              }
            ]
            """,
            ownedItems: """
            [
              {
                "id": "copy-dates",
                "publicationId": "pub-dates",
                "locationPath": [],
                "status": "owned",
                "addedAt": "2026-08-11T12:00:00Z",
                "updatedAt": "2026-08-12T11:59:00+23:59"
              }
            ]
            """
        )

        _ = try CollectionImporter.importCollection(data: data, into: context)
        let publication = try XCTUnwrap(context.fetch(FetchDescriptor<Publication>()).first)
        let utcNoon = isoDate("2026-08-11T12:00:00Z").timeIntervalSince1970
        XCTAssertEqual(publication.createdAt.timeIntervalSince1970, utcNoon + 0.123, accuracy: 0.000001)
        XCTAssertEqual(publication.updatedAt.timeIntervalSince1970, utcNoon + 0.5, accuracy: 0.000001)
    }

    func testRejectsSemanticDateErrorInNestedPublicationField() {
        let data = canonicalData(
            publications: """
            [
              {
                "id": "pub-invalid-date",
                "type": "book",
                "title": "Błędna data",
                "authors": [],
                "identifiers": {},
                "createdAt": "2026-02-29T10:00:00Z",
                "updatedAt": "2026-03-01T10:00:00Z"
              }
            ]
            """,
            ownedItems: """
            [
              {
                "id": "copy-invalid-date",
                "publicationId": "pub-invalid-date",
                "locationPath": [],
                "status": "owned",
                "addedAt": "2026-03-01T10:00:00Z",
                "updatedAt": "2026-03-01T10:00:00Z"
              }
            ]
            """
        )

        XCTAssertThrowsError(try CollectionImporter.prepare(data: data)) { error in
            guard case .invalidJSON(let reason) = error as? CollectionImportError else {
                return XCTFail("Oczekiwano invalidJSON, otrzymano \(error)")
            }
            XCTAssertTrue(reason.contains("createdAt"), reason)
            XCTAssertTrue(reason.contains("2026-02-29T10:00:00Z"), reason)
        }
    }

    func testRejectsFileAboveTwentyFiveMegabytesBeforeDecoding() {
        let data = Data(repeating: 0x20, count: CollectionImporter.maximumFileSizeBytes + 1)

        XCTAssertThrowsError(try CollectionImporter.prepare(data: data)) { error in
            XCTAssertEqual(
                error as? CollectionImportError,
                .fileTooLarge(maximumBytes: CollectionImporter.maximumFileSizeBytes)
            )
        }
    }

    func testRejectsRecordCountAboveConfiguredLimit() {
        let location = #"{"id":"location","name":"Miejsce","type":"other"}"#
        let locations = Array(
            repeating: location,
            count: CollectionImporter.maximumLocations + 1
        ).joined(separator: ",")
        let data = canonicalData(locations: "[\(locations)]")

        XCTAssertLessThan(data.count, CollectionImporter.maximumFileSizeBytes)
        XCTAssertThrowsError(try CollectionImporter.prepare(data: data)) { error in
            XCTAssertEqual(
                error as? CollectionImportError,
                .tooManyRecords(
                    section: "locations",
                    maximum: CollectionImporter.maximumLocations
                )
            )
        }
    }

    func testRejectsDuplicateLocationsMissingParentsAndCycles() {
        let duplicate = canonicalData(
            locations: """
            [
              { "id": "same", "name": "Pokój", "type": "room" },
              { "id": "same", "name": "Półka", "type": "shelf" }
            ]
            """
        )
        XCTAssertThrowsError(try CollectionImporter.prepare(data: duplicate)) { error in
            XCTAssertEqual(error as? CollectionImportError, .duplicateLocationID("same"))
        }

        let missingParent = canonicalData(
            locations: """
            [
              { "id": "shelf", "name": "Półka", "type": "shelf", "parentId": "missing" }
            ]
            """
        )
        XCTAssertThrowsError(try CollectionImporter.prepare(data: missingParent)) { error in
            XCTAssertEqual(
                error as? CollectionImportError,
                .missingLocationParent(locationID: "shelf", parentID: "missing")
            )
        }

        let cycle = canonicalData(
            locations: """
            [
              { "id": "a", "name": "A", "type": "room", "parentId": "b" },
              { "id": "b", "name": "B", "type": "shelf", "parentId": "a" }
            ]
            """
        )
        XCTAssertThrowsError(try CollectionImporter.prepare(data: cycle)) { error in
            XCTAssertEqual(error as? CollectionImportError, .cyclicLocation("a"))
        }
    }

    func testRejectsPublicationWithoutOwnedItem() {
        let data = canonicalData(
            publications: """
            [
              {
                "id": "orphan",
                "type": "book",
                "title": "Bez egzemplarza",
                "authors": [],
                "identifiers": {},
                "createdAt": "2026-08-11T10:00:00Z",
                "updatedAt": "2026-08-11T10:00:00Z"
              }
            ]
            """
        )

        XCTAssertThrowsError(try CollectionImporter.prepare(data: data)) { error in
            guard case .invalidPublication(let reason) = error as? CollectionImportError else {
                return XCTFail("Oczekiwano invalidPublication, otrzymano \(error)")
            }
            XCTAssertTrue(reason.contains("nie ma żadnego egzemplarza"))
        }
    }

    func testOwnedItemPublicationConflictIsDetectedBeforeAnyInsert() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let existingPublication = Publication(
            id: CollectionImporter.publicationUUID(for: "pub-existing"),
            externalID: "pub-existing",
            type: .book,
            title: "Istniejąca"
        )
        let existingItem = OwnedItem(
            id: CollectionImporter.ownedItemUUID(for: "copy-shared"),
            externalID: "copy-shared",
            publication: existingPublication,
            locationPathText: "Dom"
        )
        context.insert(existingPublication)
        context.insert(existingItem)
        try context.save()

        let data = canonicalData(
            publications: """
            [
              {
                "id": "pub-imported",
                "type": "book",
                "title": "Nie może zostać dodana",
                "authors": [],
                "identifiers": {},
                "createdAt": "2026-08-11T10:00:00Z",
                "updatedAt": "2026-08-11T10:00:00Z"
              }
            ]
            """,
            ownedItems: """
            [
              {
                "id": "copy-shared",
                "publicationId": "pub-imported",
                "locationPath": [],
                "status": "owned",
                "addedAt": "2026-08-11T10:00:00Z",
                "updatedAt": "2026-08-11T10:00:00Z"
              }
            ]
            """
        )

        XCTAssertThrowsError(try CollectionImporter.importCollection(data: data, into: context)) { error in
            XCTAssertEqual(
                error as? CollectionImportError,
                .conflictingOwnedItem(
                    itemID: "copy-shared",
                    existingPublicationID: "pub-existing",
                    importedPublicationID: "pub-imported"
                )
            )
        }
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Publication>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<OwnedItem>()), 1)
    }

    func testSharedFixtureRoundTripsExternalIDsAuthorsPathAndCollectionMetadata() throws {
        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("fixtures/roundtrip-v1.json")
        let data = try Data(contentsOf: fixtureURL)
        let prepared = try CollectionImporter.prepare(data: data)
        XCTAssertEqual(prepared.collectionID, "collection-shared-fixture")
        XCTAssertEqual(prepared.collectionName, "Wspólny test round-trip")

        let container = try makeContainer()
        let context = container.mainContext
        let report = try CollectionImporter.apply(prepared, into: context)
        XCTAssertEqual(report.collectionID, "collection-shared-fixture")
        XCTAssertEqual(report.collectionName, "Wspólny test round-trip")

        let publications = try context.fetch(FetchDescriptor<Publication>())
        let items = try context.fetch(FetchDescriptor<OwnedItem>())
        XCTAssertEqual(publications.count, 1)
        XCTAssertEqual(items.count, 1)
        let publication = try XCTUnwrap(publications.first)
        let item = try XCTUnwrap(items.first)
        XCTAssertEqual(publication.externalID, "publication-with-text-id")
        XCTAssertEqual(item.externalID, "owned-item-with-text-id")
        XCTAssertEqual(publication.authors, ["Sacher-Masoch, Leopold von", "Nowak, Anna"])
        XCTAssertEqual(publication.coverURLString, "https://cdn.example.org/covers/fixture-001.jpg")
        XCTAssertEqual(publication.coverSource, "fixture")
        XCTAssertNil(publication.resolvedCoverURL)
        XCTAssertEqual(item.locationPath, ["Gabinet", "Półka bez ISBN"])

        let export = CollectionExporter.makeExport(
            items: items,
            collectionID: report.collectionID,
            collectionName: report.collectionName,
            exportedAt: isoDate("2026-08-11T14:00:00Z")
        )
        let encoded = try CollectionExporter.encode(export)
        XCTAssertFalse(encoded.isEmpty)
        XCTAssertEqual(export.collection.id, "collection-shared-fixture")
        XCTAssertEqual(export.collection.name, "Wspólny test round-trip")
        XCTAssertEqual(export.publications.map(\.id), ["publication-with-text-id"])
        XCTAssertEqual(export.publications.first?.authors, ["Sacher-Masoch, Leopold von", "Nowak, Anna"])
        XCTAssertEqual(export.publications.first?.metadata?.coverUrl, "https://cdn.example.org/covers/fixture-001.jpg")
        XCTAssertEqual(export.publications.first?.metadata?.coverSource, "fixture")
        XCTAssertEqual(export.ownedItems.map(\.id), ["owned-item-with-text-id"])
        XCTAssertEqual(export.ownedItems.first?.publicationId, "publication-with-text-id")
        XCTAssertEqual(export.ownedItems.first?.locationPath, ["Gabinet", "Półka bez ISBN"])
    }

    func testTextIdentifiersMapDeterministicallyInSeparateNamespaces() {
        let first = CollectionImporter.publicationUUID(for: " web-id ")
        XCTAssertEqual(first, CollectionImporter.publicationUUID(for: "web-id"))
        XCTAssertNotEqual(first, CollectionImporter.ownedItemUUID(for: "web-id"))
        XCTAssertEqual(first.uuidString.split(separator: "-")[2].first, "5")
    }

    private func makeContainer() throws -> ModelContainer {
        let schema = Schema([Publication.self, OwnedItem.self])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: [configuration])
    }

    private func canonicalData(
        collectionID: String = "collection-test",
        collectionName: String = "Kolekcja testowa",
        exportedAt: String = "2026-08-11T10:00:00.000Z",
        locations: String = "[]",
        publications: String = "[]",
        ownedItems: String = "[]"
    ) -> Data {
        jsonData(
            """
            {
              "schemaVersion": 1,
              "exportedAt": "\(exportedAt)",
              "collection": { "id": "\(collectionID)", "name": "\(collectionName)" },
              "locations": \(locations),
              "publications": \(publications),
              "ownedItems": \(ownedItems)
            }
            """
        )
    }

    private func jsonData(_ json: String) -> Data {
        Data(json.utf8)
    }

    private func isoDate(_ value: String) -> Date {
        ISO8601DateFormatter().date(from: value)!
    }
}
