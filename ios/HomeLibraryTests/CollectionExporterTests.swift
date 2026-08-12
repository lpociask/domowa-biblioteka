import Foundation
import XCTest
@testable import HomeLibrary

@MainActor
final class CollectionExporterTests: XCTestCase {
    func testExportMatchesVersionOneShapeAndSeparatesPublicationFromCopy() throws {
        let timestamp = Date(timeIntervalSince1970: 1_786_449_600)
        let publicationID = UUID(uuidString: "05B33F9E-7D0F-43A8-A135-4D826AFC9F9E")!
        let itemID = UUID(uuidString: "FDCB78F6-8438-4EA8-9B77-5C390FDC50A1")!
        let publication = Publication(
            id: publicationID,
            type: .periodical,
            title: "Przykładowy miesięcznik",
            authorsText: "Anna Nowak; Jan Kowalski",
            language: "pl",
            publisher: "Wydawnictwo Testowe",
            publicationYear: 2026,
            issn: "1234-5678",
            ean: "5901234123457",
            barcode: "5901234123457",
            issueNumber: "8/2026",
            issueDate: "2026-08",
            metadataSource: "scan",
            coverURLString: "https://covers.openlibrary.org/b/id/123-M.jpg",
            coverSource: "openlibrary",
            coverImageData: Data("PRIVATE-LOCAL-COVER-SENTINEL".utf8),
            createdAt: timestamp,
            updatedAt: timestamp
        )
        let item = OwnedItem(
            id: itemID,
            publication: publication,
            locationPathText: "Dom / Gabinet / Regał A / Półka 2",
            notes: "Egzemplarz testowy",
            addedAt: timestamp,
            updatedAt: timestamp
        )

        let payload = CollectionExporter.makeExport(
            items: [item],
            collectionID: "73D9AC63-E635-457A-A669-096E401DFA12",
            collectionName: "Moja biblioteka",
            exportedAt: timestamp
        )

        XCTAssertEqual(payload.schemaVersion, 1)
        XCTAssertEqual(payload.publications.count, 1)
        XCTAssertEqual(payload.ownedItems.count, 1)
        XCTAssertEqual(payload.locations.count, 4)
        XCTAssertEqual(payload.publications[0].id, publicationID.uuidString)
        XCTAssertEqual(payload.ownedItems[0].publicationId, publicationID.uuidString)
        XCTAssertEqual(payload.ownedItems[0].locationPath, ["Dom", "Gabinet", "Regał A", "Półka 2"])
        XCTAssertNotNil(payload.ownedItems[0].locationId)

        let data = try CollectionExporter.encode(payload)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("PRIVATE-LOCAL-COVER-SENTINEL"))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["schemaVersion"] as? Int, 1)
        XCTAssertNotNil(json["exportedAt"] as? String)
        XCTAssertEqual((json["publications"] as? [[String: Any]])?.first?["type"] as? String, "periodical")
        let metadata = (json["publications"] as? [[String: Any]])?.first?["metadata"] as? [String: Any]
        XCTAssertEqual(metadata?["coverUrl"] as? String, "https://covers.openlibrary.org/b/id/123-M.jpg")
        XCTAssertEqual(metadata?["coverSource"] as? String, "openlibrary")
        XCTAssertEqual((json["ownedItems"] as? [[String: Any]])?.first?["status"] as? String, "owned")
    }

    func testLocationIDsAreStableAcrossExports() {
        let publication = Publication(type: .book, title: "Test")
        let item = OwnedItem(publication: publication, locationPathText: "Dom / Salon / Regał 1")

        let first = CollectionExporter.makeExport(
            items: [item],
            collectionID: UUID().uuidString,
            collectionName: "Test"
        )
        let second = CollectionExporter.makeExport(
            items: [item],
            collectionID: UUID().uuidString,
            collectionName: "Test"
        )

        XCTAssertEqual(first.locations, second.locations)
        XCTAssertEqual(first.ownedItems.first?.locationId, second.ownedItems.first?.locationId)
    }

    func testLocationTreeUsesTheSameCaseAndDiacriticInsensitiveIdentityAsTheApp() throws {
        let publication = Publication(type: .book, title: "Test")
        let accented = OwnedItem(
            publication: publication,
            locationPathText: "Dom / Regał / Półka 1"
        )
        let plain = OwnedItem(
            publication: publication,
            locationPathText: "dom / Regal / Polka 1"
        )

        let payload = CollectionExporter.makeExport(
            items: [accented, plain],
            collectionID: UUID().uuidString,
            collectionName: "Test"
        )

        XCTAssertEqual(payload.locations.count, 3)
        XCTAssertEqual(payload.ownedItems.count, 2)
        XCTAssertEqual(
            try XCTUnwrap(payload.ownedItems.first?.locationId),
            try XCTUnwrap(payload.ownedItems.last?.locationId)
        )
    }

    func testEmptyLocationDoesNotCreateSyntheticLocation() {
        let publication = Publication(type: .book, title: "Test")
        let item = OwnedItem(publication: publication, locationPathText: "")

        let payload = CollectionExporter.makeExport(
            items: [item],
            collectionID: UUID().uuidString,
            collectionName: "Test"
        )

        XCTAssertTrue(payload.locations.isEmpty)
        XCTAssertEqual(payload.ownedItems.first?.locationPath, [])
        XCTAssertNil(payload.ownedItems.first?.locationId)
    }

    func testPreservesExternalIDsAndCatalogAuthorNames() {
        let publication = Publication(
            externalID: "pub-from-web",
            type: .book,
            title: "Test",
            authorsText: "Sacher-Masoch, Leopold von; Nowak, Anna"
        )
        let item = OwnedItem(
            externalID: "copy-from-web",
            publication: publication,
            locationPathText: ""
        )

        let payload = CollectionExporter.makeExport(
            items: [item],
            collectionID: "collection-from-web",
            collectionName: "Test"
        )

        XCTAssertEqual(payload.publications.first?.id, "pub-from-web")
        XCTAssertEqual(payload.collection.id, "collection-from-web")
        XCTAssertEqual(
            payload.publications.first?.authors,
            ["Sacher-Masoch, Leopold von", "Nowak, Anna"]
        )
        XCTAssertEqual(payload.ownedItems.first?.id, "copy-from-web")
        XCTAssertEqual(payload.ownedItems.first?.publicationId, "pub-from-web")
    }
}
