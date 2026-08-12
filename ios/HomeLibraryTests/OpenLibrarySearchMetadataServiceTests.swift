import Foundation
import XCTest
@testable import HomeLibrary

final class OpenLibrarySearchMetadataServiceTests: XCTestCase {
    func testBuildsStrictISBNQueryAndParsesExactMatchWithCoverID() async throws {
        let transport = StubOpenLibrarySearchTransport(json: Self.exactFixture)

        let metadata = try await OpenLibrarySearchMetadataService(transport: transport)
            .lookup(isbn: "0-306-40615-2")

        let value = try XCTUnwrap(metadata)
        XCTAssertEqual(value.title, "Error-correction coding")
        XCTAssertEqual(value.subtitle, "For digital communications")
        XCTAssertEqual(value.authors, ["George C. Clark", "J. Bibb Cain"])
        XCTAssertEqual(value.publisher, "Springer")
        XCTAssertEqual(value.publicationYear, 1981)
        XCTAssertEqual(value.language, "en")
        XCTAssertEqual(
            value.coverURL?.absoluteString,
            "https://covers.openlibrary.org/b/id/12345-M.jpg?default=false"
        )
        XCTAssertEqual(value.coverSource, .openLibrary)

        let receivedRequest = await transport.receivedRequest
        let request = try XCTUnwrap(receivedRequest)
        let query = URLComponents(
            url: try XCTUnwrap(request.url),
            resolvingAgainstBaseURL: false
        )?.queryItems
        XCTAssertEqual(request.url?.path, "/search.json")
        XCTAssertEqual(query?.first(where: { $0.name == "q" })?.value, "isbn:9780306406157")
        let fields = query?.first(where: { $0.name == "fields" })?.value
        XCTAssertTrue(fields?.contains("isbn") == true)
        XCTAssertTrue(fields?.contains("editions") == true)
        XCTAssertFalse(fields?.contains("editions.*") == true)
        XCTAssertEqual(query?.first(where: { $0.name == "limit" })?.value, "10")
    }

    func testRejectsRelevantLookingDocumentWithoutExactISBN() async throws {
        let transport = StubOpenLibrarySearchTransport(json: """
        {
          "numFound": 1,
          "docs": [{
            "title": "Error-correction coding",
            "editions": {
              "docs": [{
                "title": "Error-correction coding",
                "isbn": ["9780140328721"]
              }]
            }
          }]
        }
        """)

        let result = try await OpenLibrarySearchMetadataService(transport: transport)
            .lookup(isbn: "9780306406157")

        XCTAssertNil(result)
    }

    func testMatchesEquivalentISBN10ReturnedBySearch() async throws {
        let transport = StubOpenLibrarySearchTransport(json: """
        {"docs":[{
          "key":"/works/OL123W",
          "title":"Exact edition",
          "author_name":["Exact author"],
          "isbn":["0306406152"],
          "cover_i":99999
        }]}
        """)

        let result = try await OpenLibrarySearchMetadataService(transport: transport)
            .lookup(isbn: "9780306406157")

        XCTAssertEqual(result?.title, "Exact edition")
        XCTAssertEqual(result?.authors, ["Exact author"])
        XCTAssertNil(result?.coverURL)
    }

    func testConflictingTitlesForReusedExactISBNReturnNoMatch() async throws {
        let transport = StubOpenLibrarySearchTransport(json: """
        {"docs":[{
          "title":"Work title",
          "editions":{"docs":[
            {"title":"First title","isbn":["9780306406157"]},
            {"title":"Unrelated title","isbn":["0306406152"]}
          ]}
        }]}
        """)

        let result = try await OpenLibrarySearchMetadataService(transport: transport)
            .lookup(isbn: "9780306406157")

        XCTAssertNil(result)
    }

    func testFallbackProviderCallsSearchOnlyAfterEmptyReadResult() async throws {
        let read = StubOpenLibraryProvider(result: nil)
        let search = StubOpenLibraryProvider(result: Self.searchMetadata)
        let provider = FallbackOpenLibraryMetadataProvider(
            primary: read,
            fallback: search
        )

        let result = try await provider.lookup(isbn: "9780306406157")

        XCTAssertEqual(result, Self.searchMetadata)
        let readCalls = await read.callCount
        let searchCalls = await search.callCount
        XCTAssertEqual(readCalls, 1)
        XCTAssertEqual(searchCalls, 1)
    }

    func testFallbackProviderStopsAfterUsefulReadResult() async throws {
        let read = StubOpenLibraryProvider(result: Self.searchMetadata)
        let search = StubOpenLibraryProvider(result: nil)
        let provider = FallbackOpenLibraryMetadataProvider(
            primary: read,
            fallback: search
        )

        let result = try await provider.lookup(isbn: "9780306406157")

        XCTAssertEqual(result, Self.searchMetadata)
        let readCalls = await read.callCount
        let searchCalls = await search.callCount
        XCTAssertEqual(readCalls, 1)
        XCTAssertEqual(searchCalls, 0)
    }

    func testFallbackProviderUsesSearchAfterNonCancellationReadError() async throws {
        let read = StubOpenLibraryProvider(failure: .unavailable)
        let search = StubOpenLibraryProvider(result: Self.searchMetadata)
        let provider = FallbackOpenLibraryMetadataProvider(
            primary: read,
            fallback: search
        )

        let result = try await provider.lookup(isbn: "9780306406157")

        XCTAssertEqual(result, Self.searchMetadata)
        let readCalls = await read.callCount
        let searchCalls = await search.callCount
        XCTAssertEqual(readCalls, 1)
        XCTAssertEqual(searchCalls, 1)
    }

    func testFallbackProviderPreservesReadErrorWhenSearchHasNoMatch() async {
        let read = StubOpenLibraryProvider(failure: .unavailable)
        let search = StubOpenLibraryProvider(result: nil)
        let provider = FallbackOpenLibraryMetadataProvider(
            primary: read,
            fallback: search
        )

        do {
            _ = try await provider.lookup(isbn: "9780306406157")
            XCTFail("Brak wyniku Search nie może ukryć wcześniejszej awarii Read API.")
        } catch {
            XCTAssertEqual(error as? StubOpenLibraryProviderError, .unavailable)
        }

        let readCalls = await read.callCount
        let searchCalls = await search.callCount
        XCTAssertEqual(readCalls, 1)
        XCTAssertEqual(searchCalls, 1)
    }

    func testFallbackProviderTreatsReadCancellationAsTerminal() async {
        let read = CancelledOpenLibraryProvider()
        let search = StubOpenLibraryProvider(result: Self.searchMetadata)
        let provider = FallbackOpenLibraryMetadataProvider(
            primary: read,
            fallback: search
        )

        do {
            _ = try await provider.lookup(isbn: "9780306406157")
            XCTFail("Anulowany Read API nie może uruchomić kolejnego zapytania.")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }

        let readCalls = await read.callCount
        let searchCalls = await search.callCount
        XCTAssertEqual(readCalls, 1)
        XCTAssertEqual(searchCalls, 0)
    }
}

private actor StubOpenLibrarySearchTransport: BookMetadataTransport {
    private let data: Data
    private(set) var receivedRequest: URLRequest?

    init(json: String) {
        data = Data(json.utf8)
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        receivedRequest = request
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        return (data, response)
    }
}

private actor StubOpenLibraryProvider: BookMetadataProviding {
    private let result: Result<BookMetadata?, StubOpenLibraryProviderError>
    private(set) var callCount = 0

    init(result: BookMetadata?) {
        self.result = .success(result)
    }

    init(failure: StubOpenLibraryProviderError) {
        result = .failure(failure)
    }

    func lookup(isbn: String) async throws -> BookMetadata? {
        callCount += 1
        return try result.get()
    }
}

private enum StubOpenLibraryProviderError: Error {
    case unavailable
}

private actor CancelledOpenLibraryProvider: BookMetadataProviding {
    private(set) var callCount = 0

    func lookup(isbn: String) async throws -> BookMetadata? {
        callCount += 1
        throw URLError(.cancelled)
    }
}

private extension OpenLibrarySearchMetadataServiceTests {
    static let exactFixture = """
    {
      "numFound": 1,
      "numFoundExact": true,
      "docs": [{
        "key": "/works/OL123W",
        "title": "Work-level fallback title",
        "author_name": ["Work-level author"],
        "editions": {
          "numFound": 2,
          "docs": [{
            "key": "/books/OL456M",
            "title": "Error-correction coding",
            "subtitle": "For digital communications",
            "author_name": ["George C. Clark", "J. Bibb Cain", "George C. Clark"],
            "publisher": ["Springer", "Other publisher"],
            "publish_year": [1981],
            "language": ["eng"],
            "isbn": ["0306406152", "9780306406157"],
            "cover_i": 12345
          }, {
            "key": "/books/OL789M",
            "title": "Different edition",
            "publisher": ["Wrong publisher"],
            "publish_year": [2007],
            "isbn": ["9780140328721"],
            "cover_i": 99999
          }]
        }
      }]
    }
    """

    static let searchMetadata = BookMetadata(
        source: .openLibrary,
        title: "Search result",
        subtitle: nil,
        authors: [],
        publisher: nil,
        publicationYear: nil,
        language: nil
    )
}
