import Foundation
import XCTest
@testable import HomeLibrary

final class BNMetadataServiceTests: XCTestCase {
    func testLooksUpNormalizedISBNAndParsesCurrentBNShape() async throws {
        let transport = StubBNTransport(json: Self.currentBNFixture)
        let service = BNMetadataService(transport: transport)

        let metadata = try await service.lookup(isbn: "978-83-65646-15-6")

        let value = try XCTUnwrap(metadata)
        XCTAssertEqual(value.source, .nationalLibrary)
        XCTAssertEqual(value.title, "Venus in furs")
        XCTAssertEqual(value.subtitle, "Wenus w futrze : z podręcznym słownikiem angielsko-polskim")
        XCTAssertEqual(
            value.authors,
            ["Sacher-Masoch, Leopold von", "Nowak, Anna"]
        )
        XCTAssertEqual(value.publisher, "Ze Słownikiem")
        XCTAssertEqual(value.publicationYear, 2016)
        XCTAssertEqual(value.language, "en")

        let receivedRequest = await transport.receivedRequest
        let request = try XCTUnwrap(receivedRequest)
        XCTAssertEqual(request.url?.host, "data.bn.org.pl")
        XCTAssertEqual(request.url?.path, "/api/institutions/bibs.json")
        let queryItems = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems
        XCTAssertEqual(queryItems?.first(where: { $0.name == "isbnIssn" })?.value, "9788365646156")
        XCTAssertEqual(queryItems?.first(where: { $0.name == "limit" })?.value, "3")
        XCTAssertNil(queryItems?.first(where: { $0.name.lowercased().contains("key") }))
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.cachePolicy, .returnCacheDataElseLoad)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "User-Agent"),
            "HomeLibrary/0.2 (+https://github.com/lpociask/domowa-biblioteka)"
        )
        XCTAssertEqual(request.timeoutInterval, 12)
    }

    func testFallsBackToTopLevelFieldsWhenMARCIsMissing() async throws {
        let transport = StubBNTransport(json: """
        {
          "bibs": [{
            "deleted": false,
            "isbnIssn": "9780306406157",
            "title": "Tytuł bez rekordu MARC",
            "author": "Anna Przykład",
            "publisher": "Wydawnictwo Testowe",
            "publicationYear": "wydanie 2024",
            "language": "polski"
          }]
        }
        """)
        let service = BNMetadataService(transport: transport)

        let metadata = try await service.lookup(isbn: "9780306406157")

        XCTAssertEqual(metadata?.title, "Tytuł bez rekordu MARC")
        XCTAssertEqual(metadata?.authors, ["Anna Przykład"])
        XCTAssertEqual(metadata?.publisher, "Wydawnictwo Testowe")
        XCTAssertEqual(metadata?.publicationYear, 2024)
        XCTAssertEqual(metadata?.language, "pl")
    }

    func testMatchesRequestedISBNInsideAggregatedBNIdentifiers() async throws {
        let transport = StubBNTransport(json: Self.aggregatedISBNFixture)
        let service = BNMetadataService(transport: transport)

        let metadata = try await service.lookup(isbn: "9788325572280")

        XCTAssertEqual(
            metadata?.title,
            "Sprawozdania i deklaracje w instytucjach kultury"
        )
        XCTAssertEqual(metadata?.publicationYear, 2015)
        XCTAssertEqual(metadata?.source, .nationalLibrary)
    }

    func testMatchesRequestedISBNFromSeparateMARC020Subfield() async throws {
        let transport = StubBNTransport(json: """
        {
          "bibs": [{
            "deleted": false,
            "isbnIssn": "9788325572297",
            "title": "Wydanie papierowe",
            "marc": {
              "fields": [
                {"020": {"subfields": [
                  {"a": "978-83-255-7228-0 (oprawa miękka)"},
                  {"a": "978-83-255-7229-7 (e-book)"}
                ]}}
              ]
            }
          }]
        }
        """)

        let metadata = try await BNMetadataService(transport: transport)
            .lookup(isbn: "9788325572280")

        XCTAssertEqual(metadata?.title, "Wydanie papierowe")
    }

    func testDeletedOrMissingRecordsReturnNoMatch() async throws {
        let deletedTransport = StubBNTransport(json: """
        {"bibs":[{"deleted":true,"isbnIssn":"9780306406157","title":"Usunięty rekord"}]}
        """)
        let emptyTransport = StubBNTransport(json: "{}")

        let deletedResult = try await BNMetadataService(transport: deletedTransport)
            .lookup(isbn: "9780306406157")
        let emptyResult = try await BNMetadataService(transport: emptyTransport)
            .lookup(isbn: "9780306406157")

        XCTAssertNil(deletedResult)
        XCTAssertNil(emptyResult)
    }

    func testUnrelatedISBNRecordReturnsNoMatch() async throws {
        let transport = StubBNTransport(json: """
        {
          "bibs": [{
            "deleted": false,
            "isbnIssn": "9780140328721",
            "title": "Rekord innej książki"
          }]
        }
        """)

        let result = try await BNMetadataService(transport: transport)
            .lookup(isbn: "9780306406157")

        XCTAssertNil(result)
    }

    func testAggregatedIdentifiersWithoutRequestedISBNReturnNoMatch() async throws {
        let transport = StubBNTransport(json: """
        {
          "bibs": [{
            "deleted": false,
            "isbnIssn": "9788325572280 9788325572297",
            "title": "Rekord innych wydań"
          }]
        }
        """)

        let result = try await BNMetadataService(transport: transport)
            .lookup(isbn: "9780306406157")

        XCTAssertNil(result)
    }

    func testRejectsInvalidISBNBeforeCallingTransport() async {
        let transport = StubBNTransport(json: "{\"bibs\":[]}")
        let service = BNMetadataService(transport: transport)

        do {
            _ = try await service.lookup(isbn: "9780306406158")
            XCTFail("Nieprawidłowy ISBN powinien zakończyć lookup błędem.")
        } catch {
            XCTAssertEqual(error as? BNMetadataServiceError, .invalidISBN)
        }

        let request = await transport.receivedRequest
        XCTAssertNil(request)
    }

    func testMapsHTTPFailureToServiceError() async {
        let transport = StubBNTransport(json: "{}", statusCode: 503)

        do {
            _ = try await BNMetadataService(transport: transport)
                .lookup(isbn: "9780306406157")
            XCTFail("Odpowiedź HTTP 503 powinna zakończyć lookup błędem.")
        } catch {
            XCTAssertEqual(error as? BNMetadataServiceError, .httpStatus(503))
        }
    }
}

private actor StubBNTransport: BookMetadataTransport {
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

private extension BNMetadataServiceTests {
    // Fragment aktualnego formatu odpowiedzi data.bn.org.pl: pola główne oraz heterogeniczne marc.fields.
    static let currentBNFixture = """
    {
      "nextPage": "https://data.bn.org.pl/api/institutions/bibs.json?isbnIssn=9788365646156&limit=3&sinceId=5474568",
      "bibs": [{
        "id": 5474567,
        "zone": "institution",
        "createdDate": "2017-03-13T12:00:00.000Z",
        "updatedDate": "2024-11-25T22:48:49.887Z",
        "deleted": false,
        "deletedDate": null,
        "language": "angielski",
        "isbnIssn": "9788365646156",
        "author": "Sacher-Masoch, Leopold von (1836-1895) Wydawnictwo [ze słownikiem]",
        "title": "Venus in furs = Wenus w futrze : z podręcznym słownikiem angielsko-polskim / Venus im Peltz, Wenus w futrze",
        "publisher": "Wydawnictwo [ze słownikiem] Ze Słownikiem,",
        "kind": "książka",
        "publicationYear": "2016",
        "marc": {
          "leader": "03278nam a2200913 i 4500",
          "fields": [
            {"001": "b0000005474567"},
            {"008": "170313s2016    pl           |000 f eng  "},
            {"041": {"ind1": "1", "ind2": " ", "subfields": [{"a": "eng"}, {"h": "ger"}]}},
            {"100": {"ind1": "1", "ind2": " ", "subfields": [{"a": "Sacher-Masoch, Leopold von"}, {"d": "(1836-1895)"}, {"e": "Autor"}]}},
            {"245": {"ind1": "1", "ind2": "0", "subfields": [{"a": "Venus in furs ="}, {"b": "Wenus w futrze : z podręcznym słownikiem angielsko-polskim /"}, {"c": "Leopold von Sacher-Masoch."}]}},
            {"260": {"ind1": " ", "ind2": " ", "subfields": [{"a": "Ruda Śląska :"}, {"b": "Ze Słownikiem,"}, {"c": "2016."}]}},
            {"700": {"ind1": "1", "ind2": " ", "subfields": [{"a": "Nowak, Anna."}, {"e": "Autor"}]}},
            {"710": {"ind1": "2", "ind2": " ", "subfields": [{"a": "Wydawnictwo [ze słownikiem]"}, {"e": "Wydawca"}, {"4": "pbl"}]}},
            {"920": {"ind1": " ", "ind2": " ", "subfields": [{"a": "978-83-65646-15-6 : zł 29"}]}}
          ]
        }
      }]
    }
    """

    // Real response shape observed for ISBN 9788325572280. BN aggregates the
    // print and electronic identifiers in one top-level isbnIssn value.
    static let aggregatedISBNFixture = """
    {
      "nextPage": "https://data.bn.org.pl/api/institutions/bibs.json?isbnIssn=9788325572280&limit=3&sinceId=1000000",
      "bibs": [{
        "deleted": false,
        "isbnIssn": "9788325572280 9788325572297",
        "title": "Sprawozdania i deklaracje w instytucjach kultury",
        "publicationYear": "2015"
      }]
    }
    """
}
