import Foundation
import XCTest
@testable import HomeLibrary

final class OpenLibraryMetadataServiceTests: XCTestCase {
    func testReadsEditionMetadataAndBuildsIdentifiedRequest() async throws {
        let transport = StubOpenLibraryTransport(json: Self.bookFixture)
        let service = OpenLibraryMetadataService(transport: transport)

        let metadata = try await service.lookup(isbn: " 978-0-14-032872-1 ")

        let value = try XCTUnwrap(metadata)
        XCTAssertEqual(value.source, .openLibrary)
        XCTAssertEqual(value.title, "Fantastic Mr. Fox")
        XCTAssertEqual(value.subtitle, "A tale of three farmers")
        XCTAssertEqual(value.authors, ["Roald Dahl", "Jill Bennett"])
        XCTAssertEqual(value.publisher, "Puffin")
        XCTAssertEqual(value.publicationYear, 1988)
        XCTAssertEqual(value.language, "en")

        let receivedRequest = await transport.receivedRequest
        let request = try XCTUnwrap(receivedRequest)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.cachePolicy, .returnCacheDataElseLoad)
        XCTAssertEqual(request.url?.scheme, "https")
        XCTAssertEqual(request.url?.host, "openlibrary.org")
        XCTAssertEqual(
            request.url?.path,
            "/api/volumes/brief/isbn/9780140328721.json"
        )
        XCTAssertNil(request.url?.query)
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "User-Agent"),
            "HomeLibrary/0.2 (+https://github.com/lpociask/domowa-biblioteka)"
        )
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
        XCTAssertEqual(request.timeoutInterval, 12)
    }

    func testEmptyRecordsReturnNoMatch() async throws {
        let transport = StubOpenLibraryTransport(json: """
        {"records":{},"items":[]}
        """)

        let result = try await OpenLibraryMetadataService(transport: transport)
            .lookup(isbn: "9780306406157")

        XCTAssertNil(result)
    }

    func testMissingRecordsAndEmptyArrayShapesReturnNoMatch() async throws {
        let emptyResponses = [
            "{}",
            #"{"items":[]}"#,
            "[]",
            #"{"records":[]}"#
        ]

        for json in emptyResponses {
            let result = try await OpenLibraryMetadataService(
                transport: StubOpenLibraryTransport(json: json)
            ).lookup(isbn: "9780306406157")

            XCTAssertNil(result, "Odpowiedź \(json) powinna oznaczać brak dopasowania.")
        }
    }

    func testMatchesRecordContainingOnlyEquivalentISBN10() async throws {
        let transport = StubOpenLibraryTransport(json: """
        {
          "records": {
            "/books/OL4256224M": {
              "isbns": ["0306406152"],
              "data": {
                "title": "Error-correction coding for digital communications",
                "publish_date": "1981"
              }
            }
          }
        }
        """)

        let metadata = try await OpenLibraryMetadataService(transport: transport)
            .lookup(isbn: "9780306406157")

        XCTAssertEqual(metadata?.title, "Error-correction coding for digital communications")
        XCTAssertEqual(metadata?.publicationYear, 1981)
    }

    func testUnrelatedISBNRecordReturnsNoMatch() async throws {
        let transport = StubOpenLibraryTransport(json: """
        {
          "records": {
            "/books/OL-WRONG": {
              "isbns": ["9780140328721"],
              "data": {"title": "A different book"}
            }
          }
        }
        """)

        let result = try await OpenLibraryMetadataService(transport: transport)
            .lookup(isbn: "9780306406157")

        XCTAssertNil(result)
    }

    func testRejectsInvalidISBNBeforeCallingTransport() async {
        let transport = StubOpenLibraryTransport(json: #"{"records":{}}"#)

        do {
            _ = try await OpenLibraryMetadataService(transport: transport)
                .lookup(isbn: "9780306406158")
            XCTFail("Nieprawidłowy ISBN powinien zakończyć lookup błędem.")
        } catch {
            XCTAssertEqual(error as? OpenLibraryMetadataServiceError, .invalidISBN)
        }

        let request = await transport.receivedRequest
        XCTAssertNil(request)
    }

    func testMapsRateLimitToTypedHTTPError() async {
        let transport = StubOpenLibraryTransport(
            json: #"{"error":"rate limit"}"#,
            statusCode: 429
        )

        do {
            _ = try await OpenLibraryMetadataService(transport: transport)
                .lookup(isbn: "9780306406157")
            XCTFail("Odpowiedź HTTP 429 powinna zakończyć lookup błędem.")
        } catch {
            XCTAssertEqual(
                error as? OpenLibraryMetadataServiceError,
                .httpStatus(429)
            )
        }
    }

    func testMapsMalformedPayloadToTypedFormatError() async {
        let transport = StubOpenLibraryTransport(json: #"{"records":["#)

        do {
            _ = try await OpenLibraryMetadataService(transport: transport)
                .lookup(isbn: "9780306406157")
            XCTFail("Uszkodzony JSON powinien zakończyć lookup błędem.")
        } catch {
            XCTAssertEqual(
                error as? OpenLibraryMetadataServiceError,
                .malformedResponse
            )
        }
    }

    func testMapsInvalidRecordsShapeToTypedFormatError() async {
        let transport = StubOpenLibraryTransport(json: #"{"records":"not-a-catalog"}"#)

        do {
            _ = try await OpenLibraryMetadataService(transport: transport)
                .lookup(isbn: "9780306406157")
            XCTFail("Niepusty, niekatalogowy records powinien zakończyć lookup błędem.")
        } catch {
            XCTAssertEqual(
                error as? OpenLibraryMetadataServiceError,
                .malformedResponse
            )
        }
    }
}

private actor StubOpenLibraryTransport: BookMetadataTransport {
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

private extension OpenLibraryMetadataServiceTests {
    // Representative fragment of the official Read API response. It embeds both
    // the human-friendly Books API data and raw edition details in one payload.
    static let bookFixture = """
    {
      "records": {
        "/books/OL7353617M": {
          "isbns": ["0140328726", "9780140328721"],
          "publishDates": ["October 1, 1988"],
          "recordURL": "https://openlibrary.org/books/OL7353617M",
          "data": {
            "title": "Fantastic Mr. Fox",
            "subtitle": "A tale of three farmers",
            "authors": [
              {"name": "Roald Dahl"},
              {"name": "Jill Bennett"},
              {"name": "Roald Dahl"}
            ],
            "publishers": [{"name": "Puffin"}],
            "publish_date": "October 1, 1988"
          },
          "details": {
            "details": {
              "title": "Fallback title",
              "authors": [{"key": "/authors/OL34184A", "name": "Roald Dahl"}],
              "publishers": ["Fallback publisher"],
              "publish_date": "1988",
              "languages": [{"key": "/languages/eng"}]
            }
          }
        }
      },
      "items": []
    }
    """
}
