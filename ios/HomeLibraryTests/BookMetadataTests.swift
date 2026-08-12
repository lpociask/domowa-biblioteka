import Foundation
import XCTest
@testable import HomeLibrary

final class BookMetadataTests: XCTestCase {
    func testCascadeStopsAfterFirstMatch() async throws {
        let primary = StubBookMetadataProvider(result: .success(Self.bnMetadata))
        let fallback = StubBookMetadataProvider(result: .success(Self.openLibraryMetadata))
        let provider = CascadingBookMetadataProvider(providers: [primary, fallback])

        let result = try await provider.lookup(isbn: "9780306406157")
        let primaryCalls = await primary.callCount
        let fallbackCalls = await fallback.callCount

        XCTAssertEqual(result, Self.bnMetadata.addingFallbackCover(forISBN: "9780306406157"))
        XCTAssertEqual(primaryCalls, 1)
        XCTAssertEqual(fallbackCalls, 0)
    }

    func testCascadeUsesOpenLibraryWhenBNHasNoMatch() async throws {
        let primary = StubBookMetadataProvider(result: .success(nil))
        let fallback = StubBookMetadataProvider(result: .success(Self.openLibraryMetadata))
        let provider = CascadingBookMetadataProvider(providers: [primary, fallback])

        let result = try await provider.lookup(isbn: "9780306406157")
        let primaryCalls = await primary.callCount
        let fallbackCalls = await fallback.callCount

        XCTAssertEqual(result, Self.openLibraryMetadata.addingFallbackCover(forISBN: "9780306406157"))
        XCTAssertEqual(primaryCalls, 1)
        XCTAssertEqual(fallbackCalls, 1)
    }

    func testCascadeRecoversWhenPrimarySourceFails() async throws {
        let primary = StubBookMetadataProvider(result: .failure(.unavailable))
        let fallback = StubBookMetadataProvider(result: .success(Self.openLibraryMetadata))
        let provider = CascadingBookMetadataProvider(providers: [primary, fallback])

        let result = try await provider.lookup(isbn: "9780306406157")
        let primaryCalls = await primary.callCount
        let fallbackCalls = await fallback.callCount

        XCTAssertEqual(result, Self.openLibraryMetadata.addingFallbackCover(forISBN: "9780306406157"))
        XCTAssertEqual(primaryCalls, 1)
        XCTAssertEqual(fallbackCalls, 1)
    }

    func testCascadeReturnsNoMatchWhenEverySourceHasNoMatch() async throws {
        let primary = StubBookMetadataProvider(result: .success(nil))
        let fallback = StubBookMetadataProvider(result: .success(nil))
        let provider = CascadingBookMetadataProvider(providers: [primary, fallback])

        let result = try await provider.lookup(isbn: "9780306406157")
        let primaryCalls = await primary.callCount
        let fallbackCalls = await fallback.callCount

        XCTAssertNil(result)
        XCTAssertEqual(primaryCalls, 1)
        XCTAssertEqual(fallbackCalls, 1)
    }

    func testCascadeTreatsMetadataWithoutUsefulFieldsAsNoMatch() async throws {
        let primary = StubBookMetadataProvider(result: .success(Self.emptyMetadata))
        let fallback = StubBookMetadataProvider(result: .success(Self.openLibraryMetadata))
        let provider = CascadingBookMetadataProvider(providers: [primary, fallback])

        let result = try await provider.lookup(isbn: "9780306406157")
        let primaryCalls = await primary.callCount
        let fallbackCalls = await fallback.callCount

        XCTAssertEqual(result, Self.openLibraryMetadata.addingFallbackCover(forISBN: "9780306406157"))
        XCTAssertEqual(primaryCalls, 1)
        XCTAssertEqual(fallbackCalls, 1)
    }

    func testCascadePreservesPrimaryFailureWhenFallbackHasNoMatch() async {
        let primary = StubBookMetadataProvider(result: .failure(.unavailable))
        let fallback = StubBookMetadataProvider(result: .success(nil))
        let provider = CascadingBookMetadataProvider(providers: [primary, fallback])

        do {
            _ = try await provider.lookup(isbn: "9780306406157")
            XCTFail("Brak wyniku w fallbacku nie może ukryć awarii źródła głównego.")
        } catch {
            XCTAssertEqual(error as? StubMetadataError, .unavailable)
        }

        let primaryCalls = await primary.callCount
        let fallbackCalls = await fallback.callCount
        XCTAssertEqual(primaryCalls, 1)
        XCTAssertEqual(fallbackCalls, 1)
    }

    func testCascadeReportsFailureWhenOneSourceAnsweredAndAnotherFailed() async {
        let primary = StubBookMetadataProvider(result: .success(nil))
        let fallback = StubBookMetadataProvider(result: .failure(.unavailable))
        let provider = CascadingBookMetadataProvider(providers: [primary, fallback])

        do {
            _ = try await provider.lookup(isbn: "9780306406157")
            XCTFail("Brak wyniku w jednym źródle nie może ukryć awarii drugiego.")
        } catch {
            XCTAssertEqual(error as? StubMetadataError, .unavailable)
        }

        let primaryCalls = await primary.callCount
        let fallbackCalls = await fallback.callCount
        XCTAssertEqual(primaryCalls, 1)
        XCTAssertEqual(fallbackCalls, 1)
    }

    func testCascadeThrowsWhenEverySourceFails() async {
        let primary = StubBookMetadataProvider(result: .failure(.unavailable))
        let fallback = StubBookMetadataProvider(result: .failure(.malformed))
        let provider = CascadingBookMetadataProvider(providers: [primary, fallback])

        do {
            _ = try await provider.lookup(isbn: "9780306406157")
            XCTFail("Awaria wszystkich źródeł powinna zwrócić błąd.")
        } catch {
            XCTAssertEqual(error as? StubMetadataError, .malformed)
        }

        let primaryCalls = await primary.callCount
        let fallbackCalls = await fallback.callCount
        XCTAssertEqual(primaryCalls, 1)
        XCTAssertEqual(fallbackCalls, 1)
    }

    func testCascadeRejectsInvalidISBNBeforeCallingProviders() async {
        let primary = StubBookMetadataProvider(result: .success(Self.bnMetadata))
        let fallback = StubBookMetadataProvider(result: .success(Self.openLibraryMetadata))
        let provider = CascadingBookMetadataProvider(providers: [primary, fallback])

        do {
            _ = try await provider.lookup(isbn: "9780306406158")
            XCTFail("Nieprawidłowy ISBN powinien zostać odrzucony przed kaskadą.")
        } catch {
            XCTAssertEqual(error as? BookMetadataLookupError, .invalidISBN)
        }

        let primaryCalls = await primary.callCount
        let fallbackCalls = await fallback.callCount
        XCTAssertEqual(primaryCalls, 0)
        XCTAssertEqual(fallbackCalls, 0)
    }

    func testCascadeDoesNotCallProvidersWhenTaskIsAlreadyCancelled() async {
        let primary = StubBookMetadataProvider(result: .success(Self.bnMetadata))
        let fallback = StubBookMetadataProvider(result: .success(Self.openLibraryMetadata))
        let provider = CascadingBookMetadataProvider(providers: [primary, fallback])

        let task = Task<BookMetadata?, Error> {
            withUnsafeCurrentTask { currentTask in
                currentTask?.cancel()
            }
            return try await provider.lookup(isbn: "9780306406157")
        }

        do {
            _ = try await task.value
            XCTFail("Anulowane zadanie powinno zakończyć lookup przez CancellationError.")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }

        let primaryCalls = await primary.callCount
        let fallbackCalls = await fallback.callCount
        XCTAssertEqual(primaryCalls, 0)
        XCTAssertEqual(fallbackCalls, 0)
    }

    func testCascadeMapsCancelledTransportAndDoesNotCallFallback() async {
        let primary = CancelledTransportBookMetadataProvider()
        let fallback = StubBookMetadataProvider(result: .success(Self.openLibraryMetadata))
        let provider = CascadingBookMetadataProvider(providers: [primary, fallback])

        do {
            _ = try await provider.lookup(isbn: "9780306406157")
            XCTFail("Anulowany transport powinien przerwać kaskadę.")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }

        let primaryCalls = await primary.callCount
        let fallbackCalls = await fallback.callCount
        XCTAssertEqual(primaryCalls, 1)
        XCTAssertEqual(fallbackCalls, 0)
    }

    func testOpenLibraryCoverURLUsesNormalizedISBNMediumSizeAndExplicit404() throws {
        let url = try XCTUnwrap(OpenLibraryCoverURL.url(forISBN: "0-306-40615-2"))

        XCTAssertEqual(url.scheme, "https")
        XCTAssertEqual(url.host, "covers.openlibrary.org")
        XCTAssertEqual(url.path, "/b/isbn/9780306406157-M.jpg")
        XCTAssertEqual(URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "default" })?.value, "false")
        XCTAssertNil(OpenLibraryCoverURL.url(forISBN: "9780306406158"))
    }

    func testRemoteCoverPolicyPreservesHTTPSReferencesButOnlyAutoLoadsTrustedDefaultPort() throws {
        let trusted = try XCTUnwrap(RemoteCoverURLPolicy.validatedReference(
            "HTTPS://covers.openlibrary.org/b/id/123-M.jpg"
        ))
        XCTAssertTrue(RemoteCoverURLPolicy.canLoadAutomatically(trusted))

        let trusted443 = try XCTUnwrap(RemoteCoverURLPolicy.validatedReference(
            "https://covers.openlibrary.org:443/b/id/123-M.jpg"
        ))
        XCTAssertTrue(RemoteCoverURLPolicy.canLoadAutomatically(trusted443))

        let customPort = try XCTUnwrap(RemoteCoverURLPolicy.validatedReference(
            "https://covers.openlibrary.org:444/b/id/123-M.jpg"
        ))
        XCTAssertFalse(RemoteCoverURLPolicy.canLoadAutomatically(customPort))

        let foreignHost = try XCTUnwrap(RemoteCoverURLPolicy.validatedReference(
            "https://example.com/cover.jpg"
        ))
        XCTAssertFalse(RemoteCoverURLPolicy.canLoadAutomatically(foreignHost))
    }

    func testRemoteCoverPolicyRejectsCredentialsUnicodeWhitespaceAndByteOverflow() {
        for rejected in [
            "https://user:secret@covers.openlibrary.org/b/id/123-M.jpg",
            "https://covers.openlibrary.org/okładka.jpg",
            "https://covers.openlibrary.org/cover name.jpg",
            "https://covers.openlibrary.org/\(String(repeating: "a", count: 2_049))",
            "https://example.com/\(String(repeating: "<", count: 700))"
        ] {
            XCTAssertNil(RemoteCoverURLPolicy.validatedReference(rejected), rejected)
        }
    }

    func testPublicationPreservesForeignCoverForExportButNeverAutoLoadsIt() throws {
        let publication = Publication(
            type: .book,
            title: "Test",
            isbn13: "9780306406157",
            coverURLString: "https://cdn.example.org/cover.jpg",
            coverSource: "import"
        )

        XCTAssertEqual(
            publication.resolvedCoverURL,
            OpenLibraryCoverURL.url(forISBN: "9780306406157")
        )
        XCTAssertEqual(publication.resolvedCoverSource, BookMetadataSource.openLibrary.rawValue)
        XCTAssertEqual(publication.exportCoverURL?.absoluteString, "https://cdn.example.org/cover.jpg")
        XCTAssertEqual(publication.exportCoverSource, "import")

        publication.isbn13 = ""
        XCTAssertNil(publication.resolvedCoverURL)
        XCTAssertEqual(publication.exportCoverURL?.absoluteString, "https://cdn.example.org/cover.jpg")

        publication.coverURLString = "https://covers.openlibrary.org:444/b/id/123-M.jpg"
        XCTAssertNil(publication.resolvedCoverURL)
        XCTAssertEqual(
            publication.exportCoverURL?.absoluteString,
            "https://covers.openlibrary.org:444/b/id/123-M.jpg"
        )
    }
}

private extension BookMetadataTests {
    static let bnMetadata = BookMetadata(
        source: .nationalLibrary,
        title: "Książka z BN",
        subtitle: nil,
        authors: ["Autor"],
        publisher: nil,
        publicationYear: 2026,
        language: "pl"
    )

    static let openLibraryMetadata = BookMetadata(
        source: .openLibrary,
        title: "Global book",
        subtitle: nil,
        authors: ["Author"],
        publisher: nil,
        publicationYear: 2025,
        language: "en"
    )

    static let emptyMetadata = BookMetadata(
        source: .nationalLibrary,
        title: nil,
        subtitle: nil,
        authors: [],
        publisher: nil,
        publicationYear: nil,
        language: nil
    )
}

private enum StubMetadataError: Error {
    case unavailable
    case malformed
}

private actor StubBookMetadataProvider: BookMetadataProviding {
    private let result: Result<BookMetadata?, StubMetadataError>
    private(set) var callCount = 0

    init(result: Result<BookMetadata?, StubMetadataError>) {
        self.result = result
    }

    func lookup(isbn: String) async throws -> BookMetadata? {
        callCount += 1
        return try result.get()
    }
}

private actor CancelledTransportBookMetadataProvider: BookMetadataProviding {
    private(set) var callCount = 0

    func lookup(isbn: String) async throws -> BookMetadata? {
        callCount += 1
        throw URLError(.cancelled)
    }
}
