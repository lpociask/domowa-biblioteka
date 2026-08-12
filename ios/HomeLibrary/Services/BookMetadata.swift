import Foundation

enum BookMetadataSource: String, Codable, Equatable, Sendable {
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

struct BookMetadata: Codable, Equatable, Sendable {
    let source: BookMetadataSource
    let title: String?
    let subtitle: String?
    let authors: [String]
    let publisher: String?
    let publicationYear: Int?
    let language: String?
    let coverURL: URL?
    let coverSource: BookMetadataSource?

    init(
        source: BookMetadataSource,
        title: String?,
        subtitle: String?,
        authors: [String],
        publisher: String?,
        publicationYear: Int?,
        language: String?,
        coverURL: URL? = nil,
        coverSource: BookMetadataSource? = nil
    ) {
        self.source = source
        self.title = title
        self.subtitle = subtitle
        self.authors = authors
        self.publisher = publisher
        self.publicationYear = publicationYear
        self.language = language
        self.coverURL = coverURL
        self.coverSource = coverSource
    }

    var hasUsefulData: Bool {
        title != nil ||
            subtitle != nil ||
            !authors.isEmpty ||
            publisher != nil ||
            publicationYear != nil ||
            language != nil
    }

    func addingFallbackCover(forISBN isbn13: String) -> BookMetadata {
        guard coverURL == nil,
              let fallbackURL = OpenLibraryCoverURL.url(forISBN: isbn13) else {
            return self
        }

        return BookMetadata(
            source: source,
            title: title,
            subtitle: subtitle,
            authors: authors,
            publisher: publisher,
            publicationYear: publicationYear,
            language: language,
            coverURL: fallbackURL,
            coverSource: .openLibrary
        )
    }
}

enum OpenLibraryCoverSize: String, Sendable {
    case small = "S"
    case medium = "M"
    case large = "L"
}

/// Builds the documented Open Library Covers API URL. `default=false` makes a
/// missing cover an explicit HTTP 404, which the persistent image cache can
/// remember instead of storing Open Library's blank placeholder image.
enum OpenLibraryCoverURL {
    static func url(
        forISBN rawISBN: String,
        size: OpenLibraryCoverSize = .medium
    ) -> URL? {
        let parsed = PublicationIdentifierParser.parse(rawISBN)
        guard parsed.isValid,
              parsed.kind == .isbn10 || parsed.kind == .isbn13,
              let isbn13 = parsed.isbn13,
              var components = URLComponents(string: "https://covers.openlibrary.org") else {
            return nil
        }

        components.path = "/b/isbn/\(isbn13)-\(size.rawValue).jpg"
        components.queryItems = [URLQueryItem(name: "default", value: "false")]
        return components.url
    }
}

enum RemoteCoverURLPolicy {
    static func validatedReference(_ value: String) -> URL? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.utf8.count <= 2_048,
              trimmed.unicodeScalars.allSatisfy({ (0x21...0x7E).contains($0.value) }),
              let components = URLComponents(string: trimmed),
              components.scheme?.lowercased() == "https",
              components.host != nil,
              components.user == nil,
              components.password == nil,
              let normalizedURL = components.url,
              normalizedURL.absoluteString.utf8.count <= 2_048,
              normalizedURL.absoluteString.unicodeScalars.allSatisfy({
                  (0x21...0x7E).contains($0.value)
              }) else {
            return nil
        }
        return normalizedURL
    }

    static func canLoadAutomatically(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https" &&
            url.host?.lowercased() == "covers.openlibrary.org" &&
            url.user == nil &&
            url.password == nil &&
            (url.port == nil || url.port == 443)
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
    private struct Stage: Sendable {
        /// Nil preserves lookup compatibility for custom cascades longer than
        /// the production BN → Open Library pair without mislabelling metrics.
        let pilotSource: PilotLookupSource?
        let provider: any BookMetadataProviding
    }

    private let stages: [Stage]
    private let observer: BookMetadataLookupObserver

    init(
        providers: [any BookMetadataProviding] = [
            BNMetadataService(),
            OpenLibraryMetadataService()
        ],
        observer: BookMetadataLookupObserver = .disabled
    ) {
        // Custom provider lists are never labelled by array position. The
        // production initializer below supplies explicit BN/OL provenance.
        stages = providers.map { Stage(pilotSource: nil, provider: $0) }
        self.observer = observer
    }

    /// Explicitly-labelled two-stage cascade used by production and trace
    /// tests. Custom arrays intentionally remain unlabelled so provider order
    /// can never fabricate BN/Open Library provenance.
    init(
        nationalLibrary: any BookMetadataProviding,
        openLibrary: any BookMetadataProviding,
        observer: BookMetadataLookupObserver = .disabled
    ) {
        stages = [
            Stage(pilotSource: .nationalLibrary, provider: nationalLibrary),
            Stage(pilotSource: .openLibrary, provider: openLibrary)
        ]
        self.observer = observer
    }

    private init(productionObserver observer: BookMetadataLookupObserver) {
        self.init(
            nationalLibrary: BNMetadataService(),
            openLibrary: OpenLibraryMetadataService(),
            observer: observer
        )
    }

    static func production(observer: BookMetadataLookupObserver = .disabled) -> Self {
        Self(productionObserver: observer)
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

        for stage in stages {
            try Task.checkCancellation()

            do {
                let metadata = try await stage.provider.lookup(isbn: isbn13)
                try Task.checkCancellation()
                if let metadata, metadata.hasUsefulData {
                    if let source = stage.pilotSource {
                        await observer.record(source: source, outcome: .found)
                    }
                    return metadata.addingFallbackCover(forISBN: isbn13)
                }
                if let source = stage.pilotSource {
                    await observer.record(source: source, outcome: .notFound)
                }
            } catch is CancellationError {
                if let source = stage.pilotSource {
                    await observer.record(source: source, outcome: .cancelled)
                }
                throw CancellationError()
            } catch let error as URLError where error.code == .cancelled {
                if let source = stage.pilotSource {
                    await observer.record(source: source, outcome: .cancelled)
                }
                throw CancellationError()
            } catch {
                if Task.isCancelled {
                    if let source = stage.pilotSource {
                        await observer.record(source: source, outcome: .cancelled)
                    }
                    throw CancellationError()
                }
                if let source = stage.pilotSource {
                    await observer.record(source: source, outcome: .failed)
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
