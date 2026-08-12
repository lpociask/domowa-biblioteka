import XCTest
@testable import HomeLibrary

@MainActor
final class ScannerStepTests: XCTestCase {
    func testLocationChangeActionIsOptInForExistingCallSites() {
        let step = ScannerStep(currentLocation: "Gabinet / Regał 2 / Półka 3") { _, _ in }

        XCTAssertNil(step.onChangeLocation)
        XCTAssertFalse(step.showsLocationChangeAction)
    }

    func testLocationChangeActionIsAvailableForANormalizedCurrentLocation() {
        var changeRequestCount = 0
        let step = ScannerStep(
            currentLocation: "  Gabinet / Regał 2 / Półka 3  ",
            onChangeLocation: { changeRequestCount += 1 }
        ) { _, _ in }

        XCTAssertEqual(step.currentLocation, "Gabinet / Regał 2 / Półka 3")
        XCTAssertTrue(step.showsLocationChangeAction)

        step.onChangeLocation?()

        XCTAssertEqual(changeRequestCount, 1)
    }

    func testLocationChangeActionStaysHiddenWithoutAUsableLocation() {
        let step = ScannerStep(
            currentLocation: "  \n ",
            onChangeLocation: {}
        ) { _, _ in }

        XCTAssertNil(step.currentLocation)
        XCTAssertFalse(step.showsLocationChangeAction)
    }
}
