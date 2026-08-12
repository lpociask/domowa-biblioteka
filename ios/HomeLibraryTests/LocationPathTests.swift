import XCTest
@testable import HomeLibrary

final class LocationPathTests: XCTestCase {
    func testNormalizesMixedSeparatorsWhitespaceAndEmptySegments() {
        let path = LocationPath("  Dom / / Gabinet › Regał   2 / Półka 3 ›  ")

        XCTAssertEqual(path.segments, ["Dom", "Gabinet", "Regał 2", "Półka 3"])
        XCTAssertEqual(path.canonical, "Dom / Gabinet / Regał 2 / Półka 3")
        XCTAssertEqual(path.display, "Dom › Gabinet › Regał 2 › Półka 3")
        XCTAssertFalse(path.isEmpty)
    }

    func testEmptyInputAndSeparatorsOnlyAreSafe() {
        let empty = LocationPath()
        let separatorsOnly = LocationPath(" / › //  › ")

        XCTAssertTrue(empty.isEmpty)
        XCTAssertEqual(empty.segments, [])
        XCTAssertEqual(empty.canonical, "")
        XCTAssertEqual(empty.display, "")
        XCTAssertEqual(empty, separatorsOnly)
    }

    func testEqualityAndHashingIgnoreCaseAndLatinDiacritics() {
        let accented = LocationPath("Dom / Gabinet / Regał 2 / Półka 3")
        let plain = LocationPath("dom › GABINET › REGAL 2 › polka 3")

        XCTAssertEqual(accented, plain)
        XCTAssertEqual(accented.deduplicationKey, plain.deduplicationKey)
        XCTAssertEqual(Set([accented, plain]).count, 1)
    }

    func testDifferentHierarchyDoesNotCompareEqual() {
        XCTAssertNotEqual(
            LocationPath("Dom / Gabinet / Półka 3"),
            LocationPath("Dom / Salon / Półka 3")
        )
    }

    func testSegmentInitializerUsesTheSameNormalizationRules() {
        let path = LocationPath(segments: [" Dom ", "", "Regał\t2", " Półka 3 "])

        XCTAssertEqual(path.canonical, "Dom / Regał 2 / Półka 3")
    }
}
