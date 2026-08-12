import Foundation
import XCTest
@testable import HomeLibrary

final class PilotCollectionVerifierTests: XCTestCase {
    func testExactDocumentsVerifyAndReturnOnlyCounts() throws {
        let data = try encoded(basePayload())

        let report = PilotCollectionVerifier.verify(original: data, restored: data)

        XCTAssertTrue(report.isVerified)
        XCTAssertEqual(report.outcome, .verified)
        XCTAssertTrue(report.mismatches.isEmpty)
        XCTAssertEqual(
            report.originalCounts,
            PilotCollectionRecordCounts(locations: 2, publications: 2, ownedItems: 2)
        )
        XCTAssertEqual(report.restoredCounts, report.originalCounts)
    }

    func testArrayReorderingAndNewExportTimestampAreSemanticallyEqual() throws {
        let original = basePayload()
        var restored = original
        restored["exportedAt"] = "2026-08-12T18:30:00+02:00"
        restored["locations"] = Array(locations(in: original).reversed())
        restored["publications"] = Array(publications(in: original).reversed())
        restored["ownedItems"] = Array(ownedItems(in: original).reversed())

        let report = PilotCollectionVerifier.verify(
            original: try encoded(original),
            restored: try encoded(restored)
        )

        XCTAssertTrue(report.isVerified)
        XCTAssertEqual(report.mismatches, [])
    }

    func testZuluAndExplicitMillisecondTimestampsAreSemanticallyEqual() throws {
        let original = payloadBySettingRecordTimestamps(
            in: basePayload(),
            to: "2026-08-11T10:00:00Z"
        )
        let restored = payloadBySettingRecordTimestamps(
            in: original,
            to: "2026-08-11T10:00:00.000Z"
        )

        let report = PilotCollectionVerifier.verify(
            original: try encoded(original),
            restored: try encoded(restored)
        )

        XCTAssertTrue(report.isVerified)
        XCTAssertEqual(report.mismatches, [])
    }

    func testEquivalentOffsetTimestampsAreSemanticallyEqual() throws {
        let original = payloadBySettingRecordTimestamps(
            in: basePayload(),
            to: "2026-08-11T10:00:00.123Z"
        )
        let restored = payloadBySettingRecordTimestamps(
            in: original,
            to: "2026-08-11T12:00:00.123+02:00"
        )

        let report = PilotCollectionVerifier.verify(
            original: try encoded(original),
            restored: try encoded(restored)
        )

        XCTAssertTrue(report.isVerified)
        XCTAssertEqual(report.mismatches, [])
    }

    func testInvalidRestoredTimestampStillFailsStrictCanonicalValidation() throws {
        let original = basePayload()
        let restored = payloadBySettingRecordTimestamps(
            in: original,
            to: "2026-02-29T10:00:00Z"
        )

        let report = PilotCollectionVerifier.verify(
            original: try encoded(original),
            restored: try encoded(restored)
        )

        XCTAssertEqual(report.outcome, .invalidRestored)
        XCTAssertEqual(report.mismatches, .schema)
    }

    func testCountMismatchIsReportedWithoutLeakingTheNewCopy() throws {
        let original = basePayload()
        var restored = original
        var copies = ownedItems(in: restored)
        var thirdCopy = copies[0]
        thirdCopy["id"] = "copy-private-third"
        copies.append(thirdCopy)
        restored["ownedItems"] = copies

        let report = PilotCollectionVerifier.verify(
            original: try encoded(original),
            restored: try encoded(restored)
        )

        XCTAssertEqual(report.outcome, .mismatched)
        XCTAssertEqual(report.mismatches, [.count, .copyIdentity])
        XCTAssertEqual(report.originalCounts?.ownedItems, 2)
        XCTAssertEqual(report.restoredCounts?.ownedItems, 3)
    }

    func testPublicationIdentityMismatchIsReported() throws {
        let original = basePayload()
        var restored = original
        var publications = publications(in: restored)
        publications[0]["id"] = "publication-replaced"
        restored["publications"] = publications
        var copies = ownedItems(in: restored)
        copies[0]["publicationId"] = "publication-replaced"
        restored["ownedItems"] = copies

        let report = PilotCollectionVerifier.verify(
            original: try encoded(original),
            restored: try encoded(restored)
        )

        XCTAssertEqual(report.outcome, .mismatched)
        XCTAssertTrue(report.mismatches.contains(.publicationIdentity))
        XCTAssertTrue(report.mismatches.contains(.copyIdentity))
        XCTAssertFalse(report.mismatches.contains(.count))
        XCTAssertFalse(report.mismatches.contains(.metadata))
    }

    func testCopyIdentityMismatchIsReportedIndependently() throws {
        let original = basePayload()
        var restored = original
        var copies = ownedItems(in: restored)
        copies[0]["id"] = "copy-replaced"
        restored["ownedItems"] = copies

        let report = PilotCollectionVerifier.verify(
            original: try encoded(original),
            restored: try encoded(restored)
        )

        XCTAssertEqual(report.mismatches, .copyIdentity)
    }

    func testLocationGraphMismatchIncludesHierarchyAndCopyPath() throws {
        let original = basePayload()
        var restored = original
        var locations = locations(in: restored)
        locations[1]["name"] = "Inna półka"
        restored["locations"] = locations
        var copies = ownedItems(in: restored)
        copies[0]["locationPath"] = ["Gabinet", "Inna półka"]
        restored["ownedItems"] = copies

        let report = PilotCollectionVerifier.verify(
            original: try encoded(original),
            restored: try encoded(restored)
        )

        XCTAssertEqual(report.mismatches, .locationGraph)
    }

    func testMetadataMismatchCoversBibliographyAndCopyState() throws {
        let original = basePayload()
        var restored = original
        var publications = publications(in: restored)
        publications[0]["title"] = "Zmieniony tytuł"
        restored["publications"] = publications
        var copies = ownedItems(in: restored)
        copies[0]["status"] = "loaned"
        restored["ownedItems"] = copies

        let report = PilotCollectionVerifier.verify(
            original: try encoded(original),
            restored: try encoded(restored)
        )

        XCTAssertEqual(report.mismatches, .metadata)
    }

    func testUnsupportedSchemaAndMalformedJSONAreInvalidWithoutDetails() throws {
        let originalData = try encoded(basePayload())
        var unsupported = basePayload()
        unsupported["schemaVersion"] = 2

        let unsupportedReport = PilotCollectionVerifier.verify(
            original: originalData,
            restored: try encoded(unsupported)
        )
        XCTAssertEqual(unsupportedReport.outcome, .invalidRestored)
        XCTAssertEqual(unsupportedReport.mismatches, .schema)
        XCTAssertNotNil(unsupportedReport.originalCounts)
        XCTAssertNil(unsupportedReport.restoredCounts)

        let malformedReport = PilotCollectionVerifier.verify(
            original: originalData,
            restored: Data("{private malformed".utf8)
        )
        XCTAssertEqual(malformedReport.outcome, .invalidRestored)
        XCTAssertEqual(malformedReport.mismatches, .schema)
        XCTAssertNil(malformedReport.restoredCounts)
    }

    func testInvalidOriginalStopsBeforeRestoredComparison() throws {
        let report = PilotCollectionVerifier.verify(
            original: Data("[]".utf8),
            restored: try encoded(basePayload())
        )

        XCTAssertEqual(report.outcome, .invalidOriginal)
        XCTAssertEqual(report.mismatches, .schema)
        XCTAssertNil(report.originalCounts)
        XCTAssertNil(report.restoredCounts)
    }

    func testOversizedInputsAreRejectedBeforeDecoding() throws {
        let valid = try encoded(basePayload())
        let oversized = Data(
            repeating: 0x20,
            count: PilotCollectionVerifier.maximumFileSizeBytes + 1
        )

        let originalReport = PilotCollectionVerifier.verify(
            original: oversized,
            restored: valid
        )
        XCTAssertEqual(originalReport.outcome, .originalTooLarge)
        XCTAssertTrue(originalReport.mismatches.isEmpty)

        let restoredReport = PilotCollectionVerifier.verify(
            original: valid,
            restored: oversized
        )
        XCTAssertEqual(restoredReport.outcome, .restoredTooLarge)
        XCTAssertTrue(restoredReport.mismatches.isEmpty)
    }

    func testEncodedReportCannotContainPrivateCollectionSentinels() throws {
        let sentinels = [
            "ULTRA_PRIVATE_TITLE_8C32",
            "978_PRIVATE_ISBN_1A90",
            "SECRET_LOCATION_72B1",
            "PRIVATE_NOTE_93DE",
        ]
        var payload = basePayload()
        var publications = publications(in: payload)
        publications[0]["title"] = sentinels[0]
        var identifiers = publications[0]["identifiers"] as! [String: Any]
        identifiers["isbn13"] = sentinels[1]
        publications[0]["identifiers"] = identifiers
        payload["publications"] = publications
        var locations = locations(in: payload)
        locations[0]["name"] = sentinels[2]
        payload["locations"] = locations
        var copies = ownedItems(in: payload)
        copies[0]["locationPath"] = [sentinels[2], "Półka 4"]
        copies[0]["notes"] = sentinels[3]
        payload["ownedItems"] = copies

        let data = try encoded(payload)
        let report = PilotCollectionVerifier.verify(original: data, restored: data)
        let persistedReport = String(decoding: try JSONEncoder().encode(report), as: UTF8.self)

        XCTAssertTrue(report.isVerified)
        for sentinel in sentinels {
            XCTAssertFalse(persistedReport.contains(sentinel))
        }
        XCTAssertLessThan(persistedReport.utf8.count, 256)
    }

    private func basePayload() -> [String: Any] {
        let timestamp = "2026-08-11T10:00:00.123Z"
        return [
            "schemaVersion": 1,
            "exportedAt": timestamp,
            "collection": [
                "id": "pilot-collection",
                "name": "Kolekcja pilotażowa",
            ],
            "locations": [
                [
                    "id": "room",
                    "name": "Gabinet",
                    "type": "room",
                    "parentId": NSNull(),
                ],
                [
                    "id": "shelf",
                    "name": "Półka 4",
                    "type": "shelf",
                    "parentId": "room",
                ],
            ],
            "publications": [
                [
                    "id": "publication-book",
                    "type": "book",
                    "title": "Książka testowa",
                    "subtitle": NSNull(),
                    "authors": ["Autor Testowy"],
                    "language": "pl",
                    "publisher": "Wydawca",
                    "publicationYear": 2026,
                    "identifiers": [
                        "isbn13": "9780306406157",
                        "issn": NSNull(),
                        "ean": "9780306406157",
                        "barcode": "9780306406157",
                    ],
                    "issue": NSNull(),
                    "metadata": [
                        "source": "bn",
                        "coverUrl": "https://covers.openlibrary.org/b/isbn/9780306406157-M.jpg?default=false",
                        "coverSource": "openlibrary",
                    ],
                    "createdAt": timestamp,
                    "updatedAt": timestamp,
                ],
                [
                    "id": "publication-periodical",
                    "type": "periodical",
                    "title": "Magazyn testowy",
                    "subtitle": NSNull(),
                    "authors": [],
                    "language": "en",
                    "publisher": "Test Press",
                    "publicationYear": 2026,
                    "identifiers": [
                        "isbn13": NSNull(),
                        "issn": "1234-5679",
                        "ean": NSNull(),
                        "barcode": NSNull(),
                    ],
                    "issue": [
                        "number": "8/2026",
                        "volume": NSNull(),
                        "date": "2026-08",
                    ],
                    "metadata": [
                        "source": "ocr",
                        "coverUrl": NSNull(),
                        "coverSource": NSNull(),
                    ],
                    "createdAt": timestamp,
                    "updatedAt": timestamp,
                ],
            ],
            "ownedItems": [
                [
                    "id": "copy-book",
                    "publicationId": "publication-book",
                    "locationId": "shelf",
                    "locationPath": ["Gabinet", "Półka 4"],
                    "status": "owned",
                    "notes": NSNull(),
                    "addedAt": timestamp,
                    "updatedAt": timestamp,
                ],
                [
                    "id": "copy-periodical",
                    "publicationId": "publication-periodical",
                    "locationId": "shelf",
                    "locationPath": ["Gabinet", "Półka 4"],
                    "status": "owned",
                    "notes": "Stan dobry",
                    "addedAt": timestamp,
                    "updatedAt": timestamp,
                ],
            ],
        ]
    }

    private func locations(in payload: [String: Any]) -> [[String: Any]] {
        payload["locations"] as! [[String: Any]]
    }

    private func publications(in payload: [String: Any]) -> [[String: Any]] {
        payload["publications"] as! [[String: Any]]
    }

    private func ownedItems(in payload: [String: Any]) -> [[String: Any]] {
        payload["ownedItems"] as! [[String: Any]]
    }

    private func payloadBySettingRecordTimestamps(
        in payload: [String: Any],
        to timestamp: String
    ) -> [String: Any] {
        var result = payload
        var updatedPublications = publications(in: result)
        for index in updatedPublications.indices {
            updatedPublications[index]["createdAt"] = timestamp
            updatedPublications[index]["updatedAt"] = timestamp
        }
        result["publications"] = updatedPublications

        var updatedItems = ownedItems(in: result)
        for index in updatedItems.indices {
            updatedItems[index]["addedAt"] = timestamp
            updatedItems[index]["updatedAt"] = timestamp
        }
        result["ownedItems"] = updatedItems
        return result
    }

    private func encoded(_ payload: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
    }
}
