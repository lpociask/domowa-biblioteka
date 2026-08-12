import Foundation
import XCTest
@testable import HomeLibrary

final class LibraryOfCongressMetadataServiceTests: XCTestCase {
    func testBuildsExactSRUQueryAndParsesExactMODSRecord() async throws {
        let transport = StubLibraryOfCongressTransport(xml: Self.exactFixture)

        let metadata = try await LibraryOfCongressMetadataService(
            transport: transport
        ).lookup(isbn: "0-306-40615-2")

        let value = try XCTUnwrap(metadata)
        XCTAssertEqual(value.source, .libraryOfCongress)
        XCTAssertEqual(value.title, "Error-correction coding")
        XCTAssertEqual(value.subtitle, "for digital communications")
        XCTAssertEqual(value.authors, ["Clark, George C.", "Cain, J. Bibb"])
        XCTAssertEqual(value.publisher, "Plenum Press")
        XCTAssertEqual(value.publicationYear, 1981)
        XCTAssertEqual(value.language, "en")
        XCTAssertNil(value.coverURL)

        let receivedRequest = await transport.receivedRequest
        let request = try XCTUnwrap(receivedRequest)
        XCTAssertEqual(request.url?.scheme, "https")
        XCTAssertEqual(request.url?.host, "lx2.loc.gov")
        XCTAssertEqual(request.url?.path, "/sru/lcdb")
        let query = URLComponents(
            url: try XCTUnwrap(request.url),
            resolvingAgainstBaseURL: false
        )?.queryItems
        XCTAssertEqual(query?.first(where: { $0.name == "version" })?.value, "1.1")
        XCTAssertEqual(
            query?.first(where: { $0.name == "operation" })?.value,
            "searchRetrieve"
        )
        XCTAssertEqual(
            query?.first(where: { $0.name == "query" })?.value,
            "bath.isbn=\"9780306406157\""
        )
        XCTAssertEqual(
            query?.first(where: { $0.name == "maximumRecords" })?.value,
            "10"
        )
        XCTAssertEqual(
            query?.first(where: { $0.name == "recordSchema" })?.value,
            "mods"
        )
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.cachePolicy, .returnCacheDataElseLoad)
        XCTAssertEqual(request.timeoutInterval, 12)
    }

    func testRejectsRelevantRecordWithoutExactISBN() async throws {
        let xml = Self.exactFixture.replacingOccurrences(
            of: "978-0-306-40615-7",
            with: "978-0-14-032872-1"
        )

        let result = try await LibraryOfCongressMetadataService(
            transport: StubLibraryOfCongressTransport(xml: xml)
        ).lookup(isbn: "9780306406157")

        XCTAssertNil(result)
    }

    func testEquivalentISBN10InRecordIsExactIdentityEvidence() async throws {
        let xml = Self.exactFixture.replacingOccurrences(
            of: "978-0-306-40615-7",
            with: "0-306-40615-2"
        )

        let result = try await LibraryOfCongressMetadataService(
            transport: StubLibraryOfCongressTransport(xml: xml)
        ).lookup(isbn: "9780306406157")

        XCTAssertEqual(result?.title, "Error-correction coding")
    }

    func testEmptyValidSRUResponseReturnsNoMatch() async throws {
        let result = try await LibraryOfCongressMetadataService(
            transport: StubLibraryOfCongressTransport(xml: """
            <?xml version="1.0"?>
            <zs:searchRetrieveResponse xmlns:zs="http://www.loc.gov/zing/srw/">
              <zs:numberOfRecords>0</zs:numberOfRecords>
              <zs:records></zs:records>
            </zs:searchRetrieveResponse>
            """)
        ).lookup(isbn: "9780306406157")

        XCTAssertNil(result)
    }

    func testInvalidISBNFailsBeforeNetworkCall() async {
        let transport = StubLibraryOfCongressTransport(xml: Self.exactFixture)

        do {
            _ = try await LibraryOfCongressMetadataService(
                transport: transport
            ).lookup(isbn: "9780306406158")
            XCTFail("Nieprawidłowy ISBN powinien zostać odrzucony lokalnie.")
        } catch {
            XCTAssertEqual(
                error as? LibraryOfCongressMetadataServiceError,
                .invalidISBN
            )
        }

        let request = await transport.receivedRequest
        XCTAssertNil(request)
    }

    func testHTTPAndMalformedXMLAreReported() async {
        do {
            _ = try await LibraryOfCongressMetadataService(
                transport: StubLibraryOfCongressTransport(
                    xml: "Service unavailable",
                    statusCode: 503
                )
            ).lookup(isbn: "9780306406157")
            XCTFail("HTTP 503 powinno zostać zgłoszone.")
        } catch {
            XCTAssertEqual(
                error as? LibraryOfCongressMetadataServiceError,
                .httpStatus(503)
            )
        }

        do {
            _ = try await LibraryOfCongressMetadataService(
                transport: StubLibraryOfCongressTransport(
                    xml: "<searchRetrieveResponse><records>"
                )
            ).lookup(isbn: "9780306406157")
            XCTFail("Uszkodzony XML nie może zostać zaakceptowany.")
        } catch {
            XCTAssertEqual(
                error as? LibraryOfCongressMetadataServiceError,
                .malformedResponse
            )
        }
    }

    func testCancelledTransportMapsToCancellationError() async {
        do {
            _ = try await LibraryOfCongressMetadataService(
                transport: StubLibraryOfCongressTransport(
                    xml: "",
                    transportError: URLError(.cancelled)
                )
            ).lookup(isbn: "9780306406157")
            XCTFail("Anulowanie transportu musi być terminalne.")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
    }
}

private actor StubLibraryOfCongressTransport: BookMetadataTransport {
    private let data: Data
    private let statusCode: Int
    private let transportError: Error?
    private(set) var receivedRequest: URLRequest?

    init(
        xml: String,
        statusCode: Int = 200,
        transportError: Error? = nil
    ) {
        data = Data(xml.utf8)
        self.statusCode = statusCode
        self.transportError = transportError
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        receivedRequest = request
        if let transportError { throw transportError }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/xml"]
        )!
        return (data, response)
    }
}

private extension LibraryOfCongressMetadataServiceTests {
    static let exactFixture = """
    <?xml version="1.0" encoding="UTF-8"?>
    <zs:searchRetrieveResponse
      xmlns:zs="http://www.loc.gov/zing/srw/"
      xmlns:mods="http://www.loc.gov/mods/v3">
      <zs:version>1.1</zs:version>
      <zs:numberOfRecords>2</zs:numberOfRecords>
      <zs:records>
        <zs:record>
          <zs:recordSchema>mods</zs:recordSchema>
          <zs:recordData>
            <mods:mods>
              <mods:titleInfo>
                <mods:title>Error-correction coding</mods:title>
                <mods:subTitle>for digital communications</mods:subTitle>
              </mods:titleInfo>
              <mods:titleInfo type="alternative"><mods:title>Wrong alternate title</mods:title></mods:titleInfo>
              <mods:name type="personal"><mods:namePart>Clark, George C.</mods:namePart></mods:name>
              <mods:name type="personal"><mods:namePart>Cain, J. Bibb</mods:namePart></mods:name>
              <mods:subject><mods:name type="personal"><mods:namePart>Wrong subject name</mods:namePart></mods:name></mods:subject>
              <mods:originInfo>
                <mods:publisher>Plenum Press</mods:publisher>
                <mods:dateIssued>1981</mods:dateIssued>
              </mods:originInfo>
              <mods:language><mods:languageTerm type="code">eng</mods:languageTerm></mods:language>
              <mods:identifier type="isbn">978-0-306-40615-7</mods:identifier>
            </mods:mods>
          </zs:recordData>
        </zs:record>
        <zs:record>
          <zs:recordData>
            <mods:mods>
              <mods:titleInfo><mods:title>Unrelated edition</mods:title></mods:titleInfo>
              <mods:identifier type="isbn">978-0-14-032872-1</mods:identifier>
            </mods:mods>
          </zs:recordData>
        </zs:record>
      </zs:records>
    </zs:searchRetrieveResponse>
    """
}
