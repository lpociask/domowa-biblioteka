import Foundation

enum OpenLibrarySearchMetadataServiceError: Error, Equatable {
    case invalidISBN
    case invalidEndpoint
    case invalidResponse
    case httpStatus(Int)
    case malformedResponse
}

/// Uses the current Open Library Search API only after the legacy exact-edition
/// endpoint returns no record. Search results are accepted solely when a
/// returned ISBN normalizes to the requested ISBN-13; relevance alone never
/// counts as identity evidence.
struct OpenLibrarySearchMetadataService: BookMetadataProviding {
    private static let endpoint = URL(string: "https://openlibrary.org/search.json")!
    private static let resultLimit = "10"
    private static let fields = [
        "key", "title", "author_name", "isbn", "cover_i", "editions"
    ].joined(separator: ",")
    private static let userAgent =
        "HomeLibrary/0.2 (+https://github.com/lpociask/domowa-biblioteka)"

    private let transport: any BookMetadataTransport

    init(session: URLSession = .shared) {
        transport = OpenLibrarySearchURLSessionTransport(session: session)
    }

    init(transport: any BookMetadataTransport) {
        self.transport = transport
    }

    func lookup(isbn rawISBN: String) async throws -> BookMetadata? {
        let parsed = PublicationIdentifierParser.parse(rawISBN)
        guard parsed.isValid,
              parsed.kind == .isbn10 || parsed.kind == .isbn13,
              let isbn13 = parsed.isbn13 else {
            throw OpenLibrarySearchMetadataServiceError.invalidISBN
        }

        guard var components = URLComponents(
            url: Self.endpoint,
            resolvingAgainstBaseURL: false
        ) else {
            throw OpenLibrarySearchMetadataServiceError.invalidEndpoint
        }
        components.queryItems = [
            URLQueryItem(name: "q", value: "isbn:\(isbn13)"),
            URLQueryItem(name: "fields", value: Self.fields),
            URLQueryItem(name: "limit", value: Self.resultLimit)
        ]
        guard let url = components.url else {
            throw OpenLibrarySearchMetadataServiceError.invalidEndpoint
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.cachePolicy = .returnCacheDataElseLoad
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 12

        let (data, response) = try await transport.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw OpenLibrarySearchMetadataServiceError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw OpenLibrarySearchMetadataServiceError.httpStatus(httpResponse.statusCode)
        }

        let payload: Response
        do {
            payload = try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw OpenLibrarySearchMetadataServiceError.malformedResponse
        }

        let exactMatches = payload.docs.flatMap { work in
            (work.editions?.docs ?? []).compactMap { edition -> ExactEdition? in
                guard edition.isbn?.contains(where: {
                    PublicationIdentifierParser.parse($0).isbn13 == isbn13
                }) == true else {
                    return nil
                }
                return ExactEdition(work: work, edition: edition)
            }
        }

        if !exactMatches.isEmpty {
            guard let selected = Self.unambiguousEdition(from: exactMatches),
                  let metadata = Self.metadata(from: selected),
                  metadata.hasUsefulData else {
                return nil
            }
            return metadata
        }

        // Open Library can occasionally omit the nested edition projection.
        // In that case retain only work-level title/authors, and only when the
        // response itself still carries the exact requested ISBN. Aggregated
        // publisher/year/language/cover fields are deliberately not used as
        // they may describe a different edition of the same work.
        let exactWorks = payload.docs.filter { work in
            work.isbn?.contains(where: {
                PublicationIdentifierParser.parse($0).isbn13 == isbn13
            }) == true
        }
        guard let selected = Self.unambiguousWork(from: exactWorks),
              let metadata = Self.metadata(fromWorkFallback: selected),
              metadata.hasUsefulData else {
            return nil
        }
        return metadata
    }
}

/// Keeps Open Library as one logical source in the production KPI while using
/// its current Search API as a strict fallback for gaps in the legacy Read API.
struct FallbackOpenLibraryMetadataProvider: BookMetadataProviding {
    private let primary: any BookMetadataProviding
    private let fallback: any BookMetadataProviding

    init(
        primary: any BookMetadataProviding,
        fallback: any BookMetadataProviding
    ) {
        self.primary = primary
        self.fallback = fallback
    }

    func lookup(isbn: String) async throws -> BookMetadata? {
        var primaryError: Error?

        do {
            if let metadata = try await primary.lookup(isbn: isbn),
               metadata.hasUsefulData {
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
            primaryError = error
        }

        try Task.checkCancellation()

        do {
            let metadata = try await fallback.lookup(isbn: isbn)
            try Task.checkCancellation()

            if let metadata, metadata.hasUsefulData {
                return metadata
            }
            if let primaryError {
                throw primaryError
            }
            return metadata
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            if Task.isCancelled {
                throw CancellationError()
            }
            throw error
        }
    }
}

private struct OpenLibrarySearchURLSessionTransport: BookMetadataTransport {
    let session: URLSession

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await session.data(for: request)
    }
}

private extension OpenLibrarySearchMetadataService {
    struct Response: Decodable {
        let docs: [WorkDocument]
    }

    struct WorkDocument: Decodable {
        let key: String?
        let title: String?
        let authorName: [String]?
        let isbn: [String]?
        let coverID: Int?
        let editions: Editions?

        enum CodingKeys: String, CodingKey {
            case key
            case title
            case authorName = "author_name"
            case isbn
            case coverID = "cover_i"
            case editions
        }
    }

    struct Editions: Decodable {
        let docs: [EditionDocument]
    }

    struct EditionDocument: Decodable {
        let key: String?
        let title: String?
        let subtitle: String?
        let authorName: [String]?
        let publisher: [String]?
        let publishYear: [Int]?
        let language: [String]?
        let isbn: [String]?
        let coverID: Int?

        enum CodingKeys: String, CodingKey {
            case key
            case title
            case subtitle
            case authorName = "author_name"
            case publisher
            case publishYear = "publish_year"
            case language
            case isbn
            case coverID = "cover_i"
        }
    }

    struct ExactEdition {
        let work: WorkDocument
        let edition: EditionDocument
    }

    /// Exact ISBN is necessary but reused identifiers do exist. Conflicting
    /// titles are therefore treated as ambiguous rather than guessed by rank.
    static func unambiguousEdition(from documents: [ExactEdition]) -> ExactEdition? {
        guard let first = documents.first else { return nil }
        let titleKeys = Set(documents.compactMap {
            $0.edition.title ?? $0.work.title
        }.map(normalizedIdentity))
        guard titleKeys.count <= 1 else { return nil }

        // Duplicate Open Library edition records can carry the same ISBN.
        // Prefer the most complete exact edition, then a stable key; never use
        // relevance order to choose between conflicting bibliographic data.
        return documents.sorted { lhs, rhs in
            let lhsScore = completenessScore(lhs)
            let rhsScore = completenessScore(rhs)
            if lhsScore != rhsScore { return lhsScore > rhsScore }
            return (lhs.edition.key ?? "") < (rhs.edition.key ?? "")
        }.first ?? first
    }

    static func metadata(from document: ExactEdition) -> BookMetadata? {
        let edition = document.edition
        let title = nonEmpty(edition.title) ?? nonEmpty(document.work.title)
        let authors = edition.authorName ?? document.work.authorName ?? []
        let publisher = edition.publisher?.compactMap(nonEmpty).first
        let language = edition.language?.compactMap(normalizedLanguage).first
        let coverURL = edition.coverID.flatMap {
            OpenLibraryCoverURL.url(forCoverID: $0)
        }

        return BookMetadata(
            source: .openLibrary,
            title: title,
            subtitle: nonEmpty(edition.subtitle),
            authors: unique(authors.compactMap(nonEmpty)),
            publisher: publisher,
            publicationYear: unambiguousPublicationYear(edition.publishYear),
            language: language,
            coverURL: coverURL,
            coverSource: coverURL == nil ? nil : .openLibrary
        )
    }

    static func unambiguousWork(from documents: [WorkDocument]) -> WorkDocument? {
        guard !documents.isEmpty else { return nil }
        let titleKeys = Set(documents.compactMap(\.title).map(normalizedIdentity))
        guard titleKeys.count <= 1 else { return nil }

        return documents.sorted { lhs, rhs in
            let lhsScore = (nonEmpty(lhs.title) == nil ? 0 : 1) +
                (lhs.authorName?.isEmpty == false ? 1 : 0)
            let rhsScore = (nonEmpty(rhs.title) == nil ? 0 : 1) +
                (rhs.authorName?.isEmpty == false ? 1 : 0)
            if lhsScore != rhsScore { return lhsScore > rhsScore }
            return (lhs.key ?? "") < (rhs.key ?? "")
        }.first
    }

    static func metadata(fromWorkFallback document: WorkDocument) -> BookMetadata? {
        BookMetadata(
            source: .openLibrary,
            title: nonEmpty(document.title),
            subtitle: nil,
            authors: unique((document.authorName ?? []).compactMap(nonEmpty)),
            publisher: nil,
            publicationYear: nil,
            language: nil,
            coverURL: nil,
            coverSource: nil
        )
    }

    static func unambiguousPublicationYear(_ years: [Int]?) -> Int? {
        let plausibleYears = (years ?? []).filter { (1000...2100).contains($0) }
        let uniqueYears = Set(plausibleYears)
        return uniqueYears.count == 1 ? uniqueYears.first : nil
    }

    static func completenessScore(_ document: ExactEdition) -> Int {
        let edition = document.edition
        return [
            edition.title,
            edition.subtitle,
            edition.publisher?.first,
            edition.language?.first,
            edition.coverID.map(String.init),
            unambiguousPublicationYear(edition.publishYear).map(String.init)
        ].compactMap { $0 }.count +
            (edition.authorName?.isEmpty == false ? 1 : 0)
    }

    static func normalizedLanguage(_ value: String) -> String? {
        let code = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !code.isEmpty else { return nil }
        let iso639ToTwoLetter = [
            "eng": "en", "pol": "pl", "ger": "de", "deu": "de",
            "fre": "fr", "fra": "fr", "spa": "es", "ita": "it",
            "rus": "ru", "ukr": "uk", "cze": "cs", "ces": "cs"
        ]
        return iso639ToTwoLetter[code] ?? code
    }

    static func normalizedIdentity(_ value: String) -> String {
        value.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
        .lowercased()
        .filter { $0.isLetter || $0.isNumber }
    }

    static func nonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        return value
    }

    static func unique(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        return values.filter { value in
            let key = normalizedIdentity(value)
            return seen.insert(key).inserted
        }
    }
}
