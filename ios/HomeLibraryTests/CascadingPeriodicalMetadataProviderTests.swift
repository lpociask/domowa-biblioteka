import Foundation
import XCTest
@testable import HomeLibrary

final class CascadingPeriodicalMetadataProviderTests: XCTestCase {
    func testCallsISSNPortalOnlyAfterBNNoMatch() async throws {
        let order = PeriodicalLookupOrderRecorder()
        let provider = CascadingPeriodicalMetadataProvider(providers: [
            OrderedPeriodicalProvider(label: "bn", result: .success(nil), order: order),
            OrderedPeriodicalProvider(
                label: "issn",
                result: .success(Self.rouleurMetadata),
                order: order
            )
        ])

        let result = try await provider.lookup(identifier: "1752962x")

        XCTAssertEqual(result, Self.rouleurMetadata)
        let calls = await order.values
        XCTAssertEqual(calls, ["bn", "issn"])
    }

    func testStopsAfterBNMatch() async throws {
        let order = PeriodicalLookupOrderRecorder()
        let portal = OrderedPeriodicalProvider(
            label: "issn",
            result: .success(Self.rouleurMetadata),
            order: order
        )
        let provider = CascadingPeriodicalMetadataProvider(providers: [
            OrderedPeriodicalProvider(
                label: "bn",
                result: .success(Self.rouleurMetadata),
                order: order
            ),
            portal
        ])

        _ = try await provider.lookup(identifier: "1752-962X")

        let calls = await order.values
        let portalCalls = await portal.callCount
        XCTAssertEqual(calls, ["bn"])
        XCTAssertEqual(portalCalls, 0)
    }

    func testRecoversFromBNFailureAndPreservesItWhenPortalMisses() async throws {
        let recoveryOrder = PeriodicalLookupOrderRecorder()
        let recoveryProvider = CascadingPeriodicalMetadataProvider(providers: [
            OrderedPeriodicalProvider(
                label: "bn", result: .failure(.unavailable), order: recoveryOrder
            ),
            OrderedPeriodicalProvider(
                label: "issn",
                result: .success(Self.rouleurMetadata),
                order: recoveryOrder
            )
        ])

        let recovered = try await recoveryProvider.lookup(identifier: "1752-962X")
        XCTAssertEqual(recovered, Self.rouleurMetadata)

        let failureOrder = PeriodicalLookupOrderRecorder()
        let failureProvider = CascadingPeriodicalMetadataProvider(providers: [
            OrderedPeriodicalProvider(
                label: "bn", result: .failure(.unavailable), order: failureOrder
            ),
            OrderedPeriodicalProvider(
                label: "issn", result: .success(nil), order: failureOrder
            )
        ])
        do {
            _ = try await failureProvider.lookup(identifier: "1752-962X")
            XCTFail("Brak ISSN Portal nie może ukryć awarii BN.")
        } catch {
            XCTAssertEqual(error as? PeriodicalCascadeStubError, .unavailable)
        }

        let recoveryCalls = await recoveryOrder.values
        let failureCalls = await failureOrder.values
        XCTAssertEqual(recoveryCalls, ["bn", "issn"])
        XCTAssertEqual(failureCalls, ["bn", "issn"])
    }

    func testCancellationIsTerminal() async {
        let order = PeriodicalLookupOrderRecorder()
        let portal = OrderedPeriodicalProvider(
            label: "issn",
            result: .success(Self.rouleurMetadata),
            order: order
        )
        let provider = CascadingPeriodicalMetadataProvider(providers: [
            OrderedCancelledPeriodicalProvider(label: "bn", order: order),
            portal
        ])

        do {
            _ = try await provider.lookup(identifier: "1752-962X")
            XCTFail("Anulowanie BN musi być terminalne.")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }

        let calls = await order.values
        let portalCalls = await portal.callCount
        XCTAssertEqual(calls, ["bn"])
        XCTAssertEqual(portalCalls, 0)
    }

    func testWrongISSNMetadataDoesNotStopFallback() async throws {
        let order = PeriodicalLookupOrderRecorder()
        let wrong = PeriodicalMetadata(
            source: .nationalLibrary,
            issn: "0033-2488",
            title: "Przekrój",
            publisher: nil,
            language: "pl"
        )
        let provider = CascadingPeriodicalMetadataProvider(providers: [
            OrderedPeriodicalProvider(
                label: "bn", result: .success(wrong), order: order
            ),
            OrderedPeriodicalProvider(
                label: "issn",
                result: .success(Self.rouleurMetadata),
                order: order
            )
        ])

        let result = try await provider.lookup(identifier: "1752-962X")

        XCTAssertEqual(result, Self.rouleurMetadata)
        let calls = await order.values
        XCTAssertEqual(calls, ["bn", "issn"])
    }
}

private enum PeriodicalCascadeStubError: Error {
    case unavailable
}

private actor PeriodicalLookupOrderRecorder {
    private(set) var values: [String] = []

    func append(_ value: String) {
        values.append(value)
    }
}

private actor OrderedPeriodicalProvider: PeriodicalMetadataProviding {
    private let label: String
    private let result: Result<PeriodicalMetadata?, PeriodicalCascadeStubError>
    private let order: PeriodicalLookupOrderRecorder
    private(set) var callCount = 0

    init(
        label: String,
        result: Result<PeriodicalMetadata?, PeriodicalCascadeStubError>,
        order: PeriodicalLookupOrderRecorder
    ) {
        self.label = label
        self.result = result
        self.order = order
    }

    func lookup(identifier: String) async throws -> PeriodicalMetadata? {
        callCount += 1
        await order.append(label)
        return try result.get()
    }
}

private actor OrderedCancelledPeriodicalProvider: PeriodicalMetadataProviding {
    private let label: String
    private let order: PeriodicalLookupOrderRecorder

    init(label: String, order: PeriodicalLookupOrderRecorder) {
        self.label = label
        self.order = order
    }

    func lookup(identifier: String) async throws -> PeriodicalMetadata? {
        await order.append(label)
        throw URLError(.cancelled)
    }
}

private extension CascadingPeriodicalMetadataProviderTests {
    static let rouleurMetadata = PeriodicalMetadata(
        source: .issnPortal,
        issn: "1752-962X",
        title: "Rouleur",
        publisher: nil,
        language: nil
    )
}
