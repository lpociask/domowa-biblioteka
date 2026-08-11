import XCTest
@testable import HomeLibrary

final class CatalogingSessionTests: XCTestCase {
    func testInitialLocationIsCanonicalized() {
        let session = CatalogingSession(locationText: " Dom › Gabinet / Półka 3 ")

        XCTAssertEqual(session.locationText, "Dom / Gabinet / Półka 3")
        XCTAssertEqual(session.canonicalLocation, LocationPath("Dom / Gabinet / Półka 3"))
        XCTAssertEqual(session.savedCount, 0)
        XCTAssertNil(session.lastSaved)
    }

    func testEditingDoesNotNormalizeOrReplaceCommittedLocationUntilCommit() {
        var session = CatalogingSession(locationText: "Dom / Gabinet")

        session.updateLocationText("  Dom / Gabinet › Regał   2 / ")

        XCTAssertEqual(session.locationText, "  Dom / Gabinet › Regał   2 / ")
        XCTAssertEqual(session.canonicalLocation.canonical, "Dom / Gabinet")

        let committed = session.commitLocation()

        XCTAssertEqual(committed.canonical, "Dom / Gabinet / Regał 2")
        XCTAssertEqual(session.locationText, "Dom / Gabinet / Regał 2")
        XCTAssertEqual(session.canonicalLocation, committed)
    }

    func testRecordSavedCommitsAndRetainsLocationForNextObject() {
        let itemID = UUID(uuidString: "00000000-0000-0000-0000-000000000123")!
        let savedAt = Date(timeIntervalSince1970: 1_800_000_000)
        var session = CatalogingSession(locationText: "Dom / Gabinet")
        session.updateLocationText("Dom › Gabinet › Regał 2 › Półka 3")

        let saved = session.recordSaved(itemID: itemID, savedAt: savedAt)

        XCTAssertEqual(session.savedCount, 1)
        XCTAssertEqual(session.locationText, "Dom / Gabinet / Regał 2 / Półka 3")
        XCTAssertEqual(session.canonicalLocation.canonical, session.locationText)
        XCTAssertEqual(saved.itemID, itemID)
        XCTAssertEqual(saved.savedAt, savedAt)
        XCTAssertEqual(saved.location, session.canonicalLocation)
        XCTAssertEqual(session.lastSaved, saved)
    }

    func testConsecutiveSavesKeepLocationAndUpdateLastSaved() {
        let firstID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let secondID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        var session = CatalogingSession(locationText: "Dom / Półka 1")

        session.recordSaved(itemID: firstID, savedAt: Date(timeIntervalSince1970: 10))
        session.recordSaved(itemID: secondID, savedAt: Date(timeIntervalSince1970: 20))

        XCTAssertEqual(session.savedCount, 2)
        XCTAssertEqual(session.locationText, "Dom / Półka 1")
        XCTAssertEqual(session.lastSaved?.itemID, secondID)
    }

    func testResetClearsEntireSession() {
        var session = CatalogingSession(locationText: "Dom / Półka 1")
        session.recordSaved(itemID: UUID(), savedAt: Date(timeIntervalSince1970: 10))

        session.reset()

        XCTAssertEqual(session, CatalogingSession())
        XCTAssertTrue(session.canonicalLocation.isEmpty)
        XCTAssertEqual(session.locationText, "")
        XCTAssertEqual(session.savedCount, 0)
        XCTAssertNil(session.lastSaved)
    }

    func testBlankLocationCanBeCommittedAndSavedSafely() {
        var session = CatalogingSession(locationText: "Dom")
        session.updateLocationText(" / › ")

        session.recordSaved(itemID: UUID(), savedAt: Date(timeIntervalSince1970: 10))

        XCTAssertTrue(session.canonicalLocation.isEmpty)
        XCTAssertEqual(session.locationText, "")
        XCTAssertEqual(session.savedCount, 1)
    }
}
