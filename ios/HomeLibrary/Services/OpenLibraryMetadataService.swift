import Foundation

enum OpenLibraryMetadataServiceError: Error, Equatable {
    case invalidISBN
    case invalidEndpoint
    case invalidResponse
    case httpStatus(Int)
    case malformedResponse
}

private struct OpenLibraryURLSessionTransport: BookMetadataTransport {
    let session: URLSession

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await session.data(for: request)
    }
}

/// Fetches edition metadata with Open Library's official legacy Read API.
///
/// The Read API includes the Books/Data API record and edition details in one
/// response, so author names and language codes do not require follow-up calls.
/// This service is intended as an experimental, low-volume metadata fallback.
struct OpenLibraryMetadataService: BookMetadataProviding {
    private static let endpoint = URL(string: "https://openlibrary.org")!
    private static let userAgent =
        "HomeLibrary/0.2 (+https://github.com/lpociask/domowa-biblioteka)"

    private let transport: any BookMetadataTransport

    init(session: URLSession = .shared) {
        transport = OpenLibraryURLSessionTransport(session: session)
    }

    init(transport: any BookMetadataTransport) {
        self.transport = transport
    }

    func lookup(isbn rawISBN: String) async throws -> BookMetadata? {
        let parsed = PublicationIdentifierParser.parse(rawISBN)
        guard parsed.isValid,
              parsed.kind == .isbn10 || parsed.kind == .isbn13,
              let isbn13 = parsed.isbn13 else {
            throw OpenLibraryMetadataServiceError.invalidISBN
        }

        guard var components = URLComponents(
            url: Self.endpoint,
            resolvingAgainstBaseURL: false
        ) else {
            throw OpenLibraryMetadataServiceError.invalidEndpoint
        }
        components.path = "/api/volumes/brief/isbn/\(isbn13).json"
        guard let url = components.url else {
            throw OpenLibraryMetadataServiceError.invalidEndpoint
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.cachePolicy = .returnCacheDataElseLoad
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 12

        let (data, response) = try await transport.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw OpenLibraryMetadataServiceError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw OpenLibraryMetadataServiceError.httpStatus(httpResponse.statusCode)
        }

        let payload: Response
        do {
            payload = try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw OpenLibraryMetadataServiceError.malformedResponse
        }

        let records = payload.records.sorted { $0.key < $1.key }
        guard let record = records.first(where: { _, record in
            record.isbns?.contains(where: {
                Self.normalizedISBN($0) == isbn13
            }) == true
        })?.value else {
            return nil
        }

        let metadata = Self.metadata(from: record)
        return metadata.hasUsefulData ? metadata : nil
    }
}

private extension OpenLibraryMetadataService {
    struct Response: Decodable {
        let records: [String: Record]

        private enum CodingKeys: String, CodingKey {
            case records
        }

        init(from decoder: Decoder) throws {
            if let array = try? decoder.unkeyedContainer() {
                guard array.isAtEnd else {
                    throw DecodingError.dataCorruptedError(
                        in: array,
                        debugDescription: "Niepusta tablica nie jest odpowiedzią katalogową Open Library."
                    )
                }
                records = [:]
                return
            }

            let container = try decoder.container(keyedBy: CodingKeys.self)
            guard container.contains(.records) else {
                records = [:]
                return
            }

            if let decodedRecords = try? container.decode([String: Record].self, forKey: .records) {
                records = decodedRecords
                return
            }

            if let array = try? container.nestedUnkeyedContainer(forKey: .records),
               array.isAtEnd {
                records = [:]
                return
            }

            throw DecodingError.typeMismatch(
                [String: Record].self,
                DecodingError.Context(
                    codingPath: container.codingPath + [CodingKeys.records],
                    debugDescription: "Pole records musi być obiektem albo pustą tablicą."
                )
            )
        }
    }

    struct Record: Decodable {
        let isbns: [String]?
        let publishDates: [String]?
        let data: BookData?
        let details: DetailsEnvelope?
    }

    struct BookData: Decodable {
        let title: String?
        let subtitle: String?
        let authors: [NamedValue]?
        let publishers: [NamedValue]?
        let publishDate: String?
        let languages: [LanguageValue]?

        enum CodingKeys: String, CodingKey {
            case title
            case subtitle
            case authors
            case publishers
            case publishDate = "publish_date"
            case languages
        }
    }

    struct DetailsEnvelope: Decodable {
        let details: EditionDetails?
    }

    struct EditionDetails: Decodable {
        let title: String?
        let subtitle: String?
        let authors: [NamedValue]?
        let publishers: [String]?
        let publishDate: String?
        let languages: [LanguageValue]?

        enum CodingKeys: String, CodingKey {
            case title
            case subtitle
            case authors
            case publishers
            case publishDate = "publish_date"
            case languages
        }
    }

    struct NamedValue: Decodable {
        let name: String?
    }

    struct LanguageValue: Decodable {
        let key: String?
        let name: String?
    }

    static func metadata(from record: Record) -> BookMetadata {
        let edition = record.details?.details
        let authors = nonEmptyValues(record.data?.authors?.compactMap(\.name) ?? [])
        let fallbackAuthors = nonEmptyValues(edition?.authors?.compactMap(\.name) ?? [])

        let dataPublisher = record.data?.publishers?
            .compactMap(\.name)
            .compactMap(nonEmpty)
            .first
        let editionPublisher = edition?.publishers?
            .compactMap(nonEmpty)
            .first

        let languageValues = record.data?.languages ?? edition?.languages ?? []
        let language = languageValues.compactMap(normalizedLanguage).first

        let publishDate = nonEmpty(record.data?.publishDate)
            ?? nonEmpty(edition?.publishDate)
            ?? record.publishDates?.compactMap(nonEmpty).first

        return BookMetadata(
            source: .openLibrary,
            title: nonEmpty(record.data?.title) ?? nonEmpty(edition?.title),
            subtitle: nonEmpty(record.data?.subtitle) ?? nonEmpty(edition?.subtitle),
            authors: unique(authors.isEmpty ? fallbackAuthors : authors),
            publisher: dataPublisher ?? editionPublisher,
            publicationYear: extractYear(from: publishDate),
            language: language
        )
    }

    static func normalizedISBN(_ value: String) -> String? {
        PublicationIdentifierParser.parse(value).isbn13
    }

    static func nonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }
        return value
    }

    static func nonEmptyValues(_ values: [String]) -> [String] {
        values.compactMap(nonEmpty)
    }

    static func extractYear(from value: String?) -> Int? {
        guard let value,
              let range = value.range(
                  of: #"\b[12][0-9]{3}\b"#,
                  options: .regularExpression
              ) else {
            return nil
        }
        return Int(value[range])
    }

    static func normalizedLanguage(_ value: LanguageValue) -> String? {
        let rawCode = nonEmpty(value.key)?
            .split(separator: "/")
            .last
            .map(String.init)
            ?? nonEmpty(value.name)

        guard let code = rawCode?.lowercased() else { return nil }
        let iso639ToTwoLetter = [
            "ara": "ar", "ben": "bn", "bul": "bg", "cat": "ca",
            "chi": "zh", "zho": "zh", "cze": "cs", "ces": "cs",
            "dan": "da", "dut": "nl", "nld": "nl", "eng": "en",
            "est": "et", "fin": "fi", "fre": "fr", "fra": "fr",
            "ger": "de", "deu": "de", "gle": "ga", "gla": "gd",
            "gre": "el", "ell": "el", "heb": "he", "hin": "hi",
            "hrv": "hr", "hun": "hu", "ice": "is", "isl": "is",
            "ind": "id", "ita": "it", "jpn": "ja", "kor": "ko",
            "lat": "la", "lav": "lv", "lit": "lt", "may": "ms",
            "msa": "ms", "nor": "no", "per": "fa", "fas": "fa",
            "pol": "pl", "por": "pt", "rum": "ro", "ron": "ro",
            "rus": "ru", "slo": "sk", "slk": "sk", "slv": "sl",
            "spa": "es", "srp": "sr", "swe": "sv", "tha": "th",
            "tur": "tr", "ukr": "uk", "urd": "ur", "vie": "vi",
            "wel": "cy", "cym": "cy", "yid": "yi"
        ]
        return iso639ToTwoLetter[code] ?? code
    }

    static func unique(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        return values.filter { value in
            let key = value.folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
            return seen.insert(key).inserted
        }
    }
}
