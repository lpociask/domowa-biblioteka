import Foundation

enum BookMetadataSource: String, Equatable, Sendable {
    case nationalLibrary = "bn"
    case openLibrary = "openlibrary"

    var displayName: String {
        switch self {
        case .nationalLibrary:
            "Biblioteki Narodowej"
        case .openLibrary:
            "Open Library"
        }
    }
}

struct BookMetadata: Equatable, Sendable {
    let source: BookMetadataSource
    let title: String?
    let subtitle: String?
    let authors: [String]
    let publisher: String?
    let publicationYear: Int?
    let language: String?

    var hasUsefulData: Bool {
        title != nil ||
            subtitle != nil ||
            !authors.isEmpty ||
            publisher != nil ||
            publicationYear != nil ||
            language != nil
    }
}

protocol BookMetadataProviding: Sendable {
    func lookup(isbn: String) async throws -> BookMetadata?
}

protocol BookMetadataTransport: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

enum BookMetadataLookupError: Error, Equatable {
    case invalidISBN
}

/// Tries low-volume, user-triggered catalog lookups in priority order.
/// A successful empty response means “no match”; an outage in one source does
/// not prevent a later source from answering.
struct CascadingBookMetadataProvider: BookMetadataProviding {
    private let providers: [any BookMetadataProviding]

    init(
        providers: [any BookMetadataProviding] = [
            BNMetadataService(),
            OpenLibraryMetadataService()
        ]
    ) {
        self.providers = providers
    }

    func lookup(isbn: String) async throws -> BookMetadata? {
        try Task.checkCancellation()

        let parsedISBN = PublicationIdentifierParser.parse(isbn)
        guard parsedISBN.isValid,
              parsedISBN.kind == .isbn10 || parsedISBN.kind == .isbn13,
              let isbn13 = parsedISBN.isbn13 else {
            throw BookMetadataLookupError.invalidISBN
        }

        var lastError: Error?

        for provider in providers {
            try Task.checkCancellation()

            do {
                let metadata = try await provider.lookup(isbn: isbn13)
                try Task.checkCancellation()
                if let metadata, metadata.hasUsefulData {
                    return metadata
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as URLError where error.code == .cancelled {
                throw CancellationError()
            } catch {
                if Task.isCancelled {
                    throw CancellationError()
                }
                lastError = error
            }
        }

        try Task.checkCancellation()
        if let lastError {
            throw lastError
        }
        return nil
    }
}
