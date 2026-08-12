import Foundation
import XCTest
@testable import HomeLibrary

final class ISSNPortalPeriodicalMetadataServiceTests: XCTestCase {
    func testMissingOrRetiredPublicRecordIsNoMatchRatherThanConnectionFailure() async throws {
        for statusCode in [404, 410] {
            let transport = StubISSNPortalTransport(
                html: "not found",
                statusCode: statusCode
            )
            let result = try await ISSNPortalPeriodicalMetadataService(
                transport: transport
            ).lookup(identifier: "1752-962X")
            XCTAssertNil(result)
        }
    }

    func testLooksUpExactRouleurISSNAndParsesPublicBasicRecord() async throws {
        let transport = StubISSNPortalTransport(html: Self.rouleurFixture)

        let metadata = try await ISSNPortalPeriodicalMetadataService(
            transport: transport
        ).lookup(identifier: "1752962x")

        XCTAssertEqual(metadata, PeriodicalMetadata(
            source: .issnPortal,
            issn: "1752-962X",
            title: "Rouleur",
            publisher: nil,
            language: nil
        ))

        let receivedRequest = await transport.receivedRequest
        let request = try XCTUnwrap(receivedRequest)
        XCTAssertEqual(request.url?.scheme, "https")
        XCTAssertEqual(request.url?.host, "portal.issn.org")
        XCTAssertEqual(request.url?.path, "/resource/ISSN/1752-962X")
        XCTAssertNil(request.url?.query)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.cachePolicy, .returnCacheDataElseLoad)
        XCTAssertEqual(request.timeoutInterval, 12)
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "User-Agent"),
            "HomeLibrary/0.2 (+https://github.com/lpociask/domowa-biblioteka)"
        )
    }

    func testLooksUpRouleurFromPhotographedEAN977AndIssueAddon() async throws {
        let transport = StubISSNPortalTransport(html: Self.rouleurFixture)
        let trace = ISSNPortalLookupTraceCollector()

        let metadata = try await ISSNPortalPeriodicalMetadataService(
            transport: transport,
            observer: trace.observer
        ).lookup(identifier: "9771752962021+45")

        XCTAssertEqual(metadata?.issn, "1752-962X")
        XCTAssertEqual(metadata?.title, "Rouleur")
        let receivedRequest = await transport.receivedRequest
        let request = try XCTUnwrap(receivedRequest)
        XCTAssertEqual(request.url?.path, "/resource/ISSN/1752-962X")
        let metrics = await trace.values
        XCTAssertEqual(metrics, [
            PilotLookupMetric(source: .issnPortal, outcome: .found)
        ])
    }

    func testFallsBackToPublicTitleProperAndDecodesEntities() async throws {
        let transport = StubISSNPortalTransport(html: """
        <!doctype html><html><head><title>ISSN 1752-962X - Ignored</title></head>
        <body>
          <dd class="value" data-key='issn'>1752-962X</dd>
          <dd data-key="title-proper">Rouleur &amp; Cyclist.</dd>
        </body></html>
        """)

        let result = try await ISSNPortalPeriodicalMetadataService(
            transport: transport
        ).lookup(identifier: "1752-962X")

        XCTAssertEqual(result?.title, "Rouleur & Cyclist")
    }

    func testExactISSNGuardRejectsDifferentValidRecord() async throws {
        let transport = StubISSNPortalTransport(html: """
        <html><head><title>ISSN 0033-2488 - Przekrój</title></head><body>
          <dd data-key="issn">0033-2488</dd>
          <dd data-key="title-proper">Przekrój.</dd>
        </body></html>
        """)

        let result = try await ISSNPortalPeriodicalMetadataService(
            transport: transport
        ).lookup(identifier: "1752-962X")

        XCTAssertNil(result)
    }

    func testInvalidISSNFailsBeforeNetworkCall() async {
        let transport = StubISSNPortalTransport(html: Self.rouleurFixture)

        do {
            _ = try await ISSNPortalPeriodicalMetadataService(
                transport: transport
            ).lookup(identifier: "1752-9620")
            XCTFail("Nieprawidłowy ISSN powinien zostać odrzucony lokalnie.")
        } catch {
            XCTAssertEqual(
                error as? ISSNPortalPeriodicalMetadataServiceError,
                .invalidIdentifier
            )
        }

        let request = await transport.receivedRequest
        XCTAssertNil(request)
    }

    func testHTTPFailureIsReported() async {
        let transport = StubISSNPortalTransport(
            html: "Service unavailable",
            statusCode: 503
        )

        do {
            _ = try await ISSNPortalPeriodicalMetadataService(
                transport: transport
            ).lookup(identifier: "1752-962X")
            XCTFail("HTTP 503 powinno zakończyć lookup błędem.")
        } catch {
            XCTAssertEqual(
                error as? ISSNPortalPeriodicalMetadataServiceError,
                .httpStatus(503)
            )
        }
    }

    func testMissingPublicIdentityOrTitleIsMalformed() async {
        for html in [
            "<html><head><title>ISSN 1752-962X - Rouleur</title></head></html>",
            "<html><body><dd data-key=\"issn\">1752-962X</dd></body></html>"
        ] {
            do {
                _ = try await ISSNPortalPeriodicalMetadataService(
                    transport: StubISSNPortalTransport(html: html)
                ).lookup(identifier: "1752-962X")
                XCTFail("Niepełny publiczny rekord nie może zostać zaakceptowany.")
            } catch {
                XCTAssertEqual(
                    error as? ISSNPortalPeriodicalMetadataServiceError,
                    .malformedResponse
                )
            }
        }
    }

    func testCancelledTransportMapsToCancellationError() async {
        let transport = StubISSNPortalTransport(
            html: "",
            transportError: URLError(.cancelled)
        )

        do {
            _ = try await ISSNPortalPeriodicalMetadataService(
                transport: transport
            ).lookup(identifier: "1752-962X")
            XCTFail("Anulowanie transportu musi być terminalne.")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
    }

    func testCancellationImmediatelyAfterTransportIsRecorded() async {
        let transport = StubISSNPortalTransport(
            html: Self.rouleurFixture,
            cancelBeforeReturn: true
        )
        let trace = ISSNPortalLookupTraceCollector()
        let task = Task {
            try await ISSNPortalPeriodicalMetadataService(
                transport: transport,
                observer: trace.observer
            ).lookup(identifier: "1752-962X")
        }

        do {
            _ = try await task.value
            XCTFail("Anulowanie po odpowiedzi transportu musi być terminalne.")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }

        let metrics = await trace.values
        XCTAssertEqual(metrics, [
            PilotLookupMetric(source: .issnPortal, outcome: .cancelled)
        ])
    }
}

private actor ISSNPortalLookupTraceCollector {
    private(set) var values: [PilotLookupMetric] = []

    nonisolated var observer: BookMetadataLookupObserver {
        BookMetadataLookupObserver { [weak self] metric in
            await self?.append(metric)
        }
    }

    private func append(_ metric: PilotLookupMetric) {
        values.append(metric)
    }
}

private actor StubISSNPortalTransport: BookMetadataTransport {
    private let data: Data
    private let statusCode: Int
    private let transportError: Error?
    private let cancelBeforeReturn: Bool
    private(set) var receivedRequest: URLRequest?

    init(
        html: String,
        statusCode: Int = 200,
        transportError: Error? = nil,
        cancelBeforeReturn: Bool = false
    ) {
        data = Data(html.utf8)
        self.statusCode = statusCode
        self.transportError = transportError
        self.cancelBeforeReturn = cancelBeforeReturn
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        receivedRequest = request
        if let transportError { throw transportError }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "text/html; charset=utf-8"]
        )!
        if cancelBeforeReturn {
            withUnsafeCurrentTask { task in
                task?.cancel()
            }
        }
        return (data, response)
    }
}

private extension ISSNPortalPeriodicalMetadataServiceTests {
    /// Reduced fixture retaining the real public fields exposed for Rouleur.
    static let rouleurFixture = """
    <!DOCTYPE html>
    <html lang="en">
      <head><title>ISSN 1752-962X - Rouleur</title></head>
      <body>
        <div class="record">
          <h2 class="record__title">
            <span class="display">Key title:</span>
            <span class="display display--semibold"> Rouleur </span>
          </h2>
          <dl class="record__field">
            <dt>ISSN:</dt>
            <dd class="record__field-value" data-key="issn">1752-962X</dd>
          </dl>
          <dl class="record__field">
            <dt>Title proper:</dt>
            <dd class="record__field-value" data-key="title-proper">Rouleur.</dd>
          </dl>
        </div>
      </body>
    </html>
    """
}
