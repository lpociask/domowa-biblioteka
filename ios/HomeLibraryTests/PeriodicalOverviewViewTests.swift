import XCTest
@testable import HomeLibrary

final class PeriodicalOverviewViewTests: XCTestCase {
    func testItemIndexKeepsFirstCopyWhenLegacyUUIDIsRepeated() throws {
        let repeatedID = try XCTUnwrap(
            UUID(uuidString: "00000000-0000-0000-0000-000000000123")
        )
        let publication = Publication(type: .periodical, title: "Magazyn")
        let first = OwnedItem(
            id: repeatedID,
            publication: publication,
            locationPathText: "Dom / Regał 1"
        )
        let second = OwnedItem(
            id: repeatedID,
            publication: publication,
            locationPathText: "Dom / Regał 2"
        )

        let index = PeriodicalOverviewView.makeItemIndex(items: [first, second])

        XCTAssertEqual(index.count, 1)
        XCTAssertTrue(index[repeatedID] === first)
    }
}
