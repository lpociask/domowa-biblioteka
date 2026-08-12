import XCTest
@testable import HomeLibrary

final class CatalogingReadinessTests: XCTestCase {
    func testShelfSessionRequiresCanonicalNonemptyPath() {
        XCTAssertFalse(CatalogingReadiness.canStartShelfSession(locationText: "  /  "))
        XCTAssertTrue(
            CatalogingReadiness.canStartShelfSession(
                locationText: " Gabinet  / Regał 2 / Półka 3 "
            )
        )
    }

    func testSerialSaveRejectsMissingShelfBeforeOtherFields() {
        XCTAssertEqual(
            failure(serial: true, location: "", title: "Tytuł"),
            .missingShelf
        )
    }

    func testManualBookMayRemainWithoutShelf() {
        XCTAssertNil(failure(serial: false, location: "", title: "Tytuł"))
    }

    func testPeriodicalRequiresConcreteIssueDiscriminator() {
        XCTAssertEqual(
            failure(
                serial: true,
                location: "Gabinet / Regał",
                type: .periodical,
                title: "Magazyn"
            ),
            .missingPeriodicalIssue
        )

        XCTAssertNil(
            failure(
                serial: true,
                location: "Gabinet / Regał",
                type: .periodical,
                title: "Magazyn",
                issueDate: "2026-08"
            )
        )
        XCTAssertNil(
            failure(
                serial: true,
                location: "Gabinet / Regał",
                type: .periodical,
                title: "Magazyn",
                supplement: "05"
            )
        )
    }

    func testExistingPublicationMatchCanAddCopyWithoutReenteringSharedFields() {
        XCTAssertNil(
            failure(
                serial: true,
                location: "Salon / Stolik",
                type: .periodical,
                title: "",
                hasMatch: true
            )
        )
    }

    func testUnknownPublicationRequiresTitle() {
        XCTAssertEqual(
            failure(serial: false, location: "", title: "   "),
            .missingTitle
        )
    }

    private func failure(
        serial: Bool,
        location: String,
        type: PublicationType = .book,
        title: String,
        hasMatch: Bool = false,
        issueNumber: String = "",
        issueDate: String = "",
        supplement: String = ""
    ) -> CatalogingReadinessFailure? {
        CatalogingReadiness.failure(
            serialMode: serial,
            locationText: location,
            publicationType: type,
            title: title,
            hasExistingPublicationMatch: hasMatch,
            issueNumber: issueNumber,
            issueDate: issueDate,
            eanSupplement: supplement
        )
    }
}
