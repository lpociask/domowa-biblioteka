import Foundation
import XCTest
@testable import HomeLibrary

final class BNPeriodicalMetadataServiceTests: XCTestCase {
    func testLooksUpEAN977AsHyphenatedISSNAndParsesSeriesRecord() async throws {
        let transport = StubBNPeriodicalTransport(json: Self.przekrojFixture)
        let service = BNPeriodicalMetadataService(transport: transport)

        let metadata = try await service.lookup(identifier: "9770033248007+05")

        XCTAssertEqual(metadata, PeriodicalMetadata(
            source: .nationalLibrary,
            issn: "0033-2488",
            title: "Przekrój",
            publisher: "Fundacja Przekrój",
            language: "pl"
        ))

        let receivedRequest = await transport.receivedRequest
        let request = try XCTUnwrap(receivedRequest)
        let query = URLComponents(
            url: try XCTUnwrap(request.url),
            resolvingAgainstBaseURL: false
        )?.queryItems
        XCTAssertEqual(request.url?.host, "data.bn.org.pl")
        XCTAssertEqual(request.url?.path, "/api/institutions/bibs.json")
        XCTAssertEqual(query?.first(where: { $0.name == "isbnIssn" })?.value, "0033-2488")
        XCTAssertEqual(query?.first(where: { $0.name == "kind" })?.value, "czasopismo")
        XCTAssertEqual(query?.first(where: { $0.name == "limit" })?.value, "10")
        XCTAssertEqual(request.cachePolicy, .returnCacheDataElseLoad)
        XCTAssertEqual(request.timeoutInterval, 12)
    }

    func testAcceptsCanonicalISSNWithXCheckDigit() async throws {
        let transport = StubBNPeriodicalTransport(json: """
        {
          "bibs": [{
            "deleted": false,
            "kind": "czasopismo",
            "isbnIssn": "1050-124X",
            "title": "International Journal"
          }]
        }
        """)

        let metadata = try await BNPeriodicalMetadataService(transport: transport)
            .lookup(identifier: "1050124x")

        XCTAssertEqual(metadata?.issn, "1050-124X")
        XCTAssertEqual(metadata?.title, "International Journal")
    }

    func testRejectsArticleEvenWhenItCarriesExactParentISSN() async throws {
        let transport = StubBNPeriodicalTransport(json: """
        {
          "bibs": [{
            "deleted": false,
            "kind": "artykuł",
            "isbnIssn": "0033-2488.",
            "title": "Tytuł pojedynczego artykułu / Przekrój."
          }]
        }
        """)

        let result = try await BNPeriodicalMetadataService(transport: transport)
            .lookup(identifier: "0033-2488")

        XCTAssertNil(result)
    }

    func testRequiresExactValidISSNAndIgnoresCancelledMARCValue() async throws {
        let transport = StubBNPeriodicalTransport(json: """
        {
          "bibs": [{
            "deleted": false,
            "kind": "czasopismo",
            "isbnIssn": "1234-5679",
            "title": "Inna seria",
            "marc": {"fields": [
              {"022": {"subfields": [
                {"a": "1234-5679"},
                {"z": "0033-2488"}
              ]}}
            ]}
          }]
        }
        """)

        let result = try await BNPeriodicalMetadataService(transport: transport)
            .lookup(identifier: "0033-2488")

        XCTAssertNil(result)
    }

    func testAmbiguousExactISSNWithDifferentSeriesTitlesReturnsNoMatch() async throws {
        let transport = StubBNPeriodicalTransport(json: """
        {
          "bibs": [
            {"kind":"czasopismo","isbnIssn":"0033-2488","title":"Seria A"},
            {"kind":"czasopismo","isbnIssn":"0033-2488","title":"Seria B"}
          ]
        }
        """)

        let result = try await BNPeriodicalMetadataService(transport: transport)
            .lookup(identifier: "0033-2488")

        XCTAssertNil(result)
    }

    func testInvalidIdentifierFailsBeforeNetworkCall() async {
        let transport = StubBNPeriodicalTransport(json: #"{"bibs":[]}"#)

        do {
            _ = try await BNPeriodicalMetadataService(transport: transport)
                .lookup(identifier: "0033-2487")
            XCTFail("Nieprawidłowy ISSN powinien zostać odrzucony.")
        } catch {
            XCTAssertEqual(
                error as? BNPeriodicalMetadataServiceError,
                .invalidIdentifier
            )
        }

        let request = await transport.receivedRequest
        XCTAssertNil(request)
    }

    func testObserverRecordsResolvedOutcomes() async throws {
        let foundTrace = PeriodicalLookupTraceCollector()
        let missTrace = PeriodicalLookupTraceCollector()

        _ = try await BNPeriodicalMetadataService(
            transport: StubBNPeriodicalTransport(json: Self.przekrojFixture),
            observer: foundTrace.observer
        ).lookup(identifier: "0033-2488")
        _ = try await BNPeriodicalMetadataService(
            transport: StubBNPeriodicalTransport(json: #"{"bibs":[]}"#),
            observer: missTrace.observer
        ).lookup(identifier: "0033-2488")

        let foundValues = await foundTrace.values
        let missValues = await missTrace.values
        XCTAssertEqual(foundValues, [
            PilotLookupMetric(source: .nationalLibrary, outcome: .found)
        ])
        XCTAssertEqual(missValues, [
            PilotLookupMetric(source: .nationalLibrary, outcome: .notFound)
        ])
    }
}

private actor StubBNPeriodicalTransport: BookMetadataTransport {
    private let data: Data
    private let statusCode: Int
    private(set) var receivedRequest: URLRequest?

    init(json: String, statusCode: Int = 200) {
        data = Data(json.utf8)
        self.statusCode = statusCode
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        receivedRequest = request
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        return (data, response)
    }
}

private actor PeriodicalLookupTraceCollector {
    private(set) var values: [PilotLookupMetric] = []

    nonisolated var observer: BookMetadataLookupObserver {
        BookMetadataLookupObserver { metric in
            await self.append(metric)
        }
    }

    private func append(_ metric: PilotLookupMetric) {
        values.append(metric)
    }
}

private extension BNPeriodicalMetadataServiceTests {
    static let przekrojFixture = """
    {
      "bibs": [{
        "deleted": false,
        "language": "polski",
        "isbnIssn": "0033-2488",
        "title": "Przekrój (Kraków) Przekrój. Przekrój Tygodnia",
        "publisher": "Czytelnik Fundacja Przekrój",
        "kind": "czasopismo",
        "marc": {"fields": [
          {"022": {"subfields": [{"a": "0033-2488"}]}},
          {"245": {"subfields": [{"a": "Przekrój."}]}},
          {"260": {"subfields": [
            {"a": "Kraków :"},
            {"b": "Fundacja Przekrój,"},
            {"c": "1945-."}
          ]}}
        ]}
      }]
    }
    """
}
