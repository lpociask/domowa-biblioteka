import Foundation

private struct BNURLSessionTransport: BookMetadataTransport {
    let session: URLSession

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await session.data(for: request)
    }
}

enum BNMetadataServiceError: Error, Equatable {
    case invalidISBN
    case invalidEndpoint
    case invalidResponse
    case httpStatus(Int)
    case malformedResponse
}

struct BNMetadataService: BookMetadataProviding {
    private static let endpoint = URL(string: "https://data.bn.org.pl/api/institutions/bibs.json")!
    private static let resultLimit = "3"
    private static let userAgent =
        "HomeLibrary/0.2 (+https://github.com/lpociask/domowa-biblioteka)"

    private let transport: any BookMetadataTransport

    init(session: URLSession = .shared) {
        transport = BNURLSessionTransport(session: session)
    }

    init(transport: any BookMetadataTransport) {
        self.transport = transport
    }

    func lookup(isbn rawISBN: String) async throws -> BookMetadata? {
        let parsed = PublicationIdentifierParser.parse(rawISBN)
        guard parsed.isValid,
              parsed.kind == .isbn10 || parsed.kind == .isbn13,
              let isbn13 = parsed.isbn13 else {
            throw BNMetadataServiceError.invalidISBN
        }

        guard var components = URLComponents(url: Self.endpoint, resolvingAgainstBaseURL: false) else {
            throw BNMetadataServiceError.invalidEndpoint
        }
        components.queryItems = [
            URLQueryItem(name: "isbnIssn", value: isbn13),
            URLQueryItem(name: "limit", value: Self.resultLimit)
        ]
        guard let url = components.url else {
            throw BNMetadataServiceError.invalidEndpoint
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.cachePolicy = .returnCacheDataElseLoad
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 12

        let (data, response) = try await transport.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw BNMetadataServiceError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw BNMetadataServiceError.httpStatus(httpResponse.statusCode)
        }

        let payload: Response
        do {
            payload = try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw BNMetadataServiceError.malformedResponse
        }

        let availableRecords = (payload.bibs ?? []).filter { $0.deleted != true }
        let record = availableRecords.first(where: {
            Self.normalizedISBN($0.isbnIssn) == isbn13
        })

        guard let record else { return nil }
        let metadata = Self.metadata(from: record)
        return metadata.hasUsefulData ? metadata : nil
    }
}

private extension BNMetadataService {
    struct Response: Decodable {
        let bibs: [BibliographicRecord]?
    }

    struct BibliographicRecord: Decodable {
        let deleted: Bool?
        let language: String?
        let isbnIssn: String?
        let author: String?
        let title: String?
        let publisher: String?
        let publicationYear: String?
        let marc: MARCRecord?
    }

    struct MARCRecord: Decodable {
        let fields: [[String: JSONValue]]?
    }

    enum JSONValue: Decodable {
        case string(String)
        case number(Double)
        case bool(Bool)
        case object([String: JSONValue])
        case array([JSONValue])
        case null

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if container.decodeNil() {
                self = .null
            } else if let value = try? container.decode(String.self) {
                self = .string(value)
            } else if let value = try? container.decode(Bool.self) {
                self = .bool(value)
            } else if let value = try? container.decode(Double.self) {
                self = .number(value)
            } else if let value = try? container.decode([String: JSONValue].self) {
                self = .object(value)
            } else if let value = try? container.decode([JSONValue].self) {
                self = .array(value)
            } else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Nieobsługiwana wartość JSON w rekordzie MARC."
                )
            }
        }
    }

    static func metadata(from record: BibliographicRecord) -> BookMetadata {
        let marcTitle = firstSubfield(in: record, tag: "245", code: "a")
        let marcSubtitle = firstSubfield(in: record, tag: "245", code: "b")

        let title = nonEmpty(trimCatalogPunctuation(marcTitle, punctuation: "/:;,="))
            ?? nonEmpty(record.title)
        let subtitle = nonEmpty(
            trimCatalogPunctuation(marcSubtitle, punctuation: "/:;,=")
        )

        let authors = marcAuthors(in: record)
        let fallbackAuthors = authors.isEmpty ? nonEmpty(record.author).map { [$0] } ?? [] : authors

        let marcPublisher = firstSubfield(in: record, tag: "264", code: "b")
            ?? firstSubfield(in: record, tag: "260", code: "b")
        let publisher = nonEmpty(trimCatalogPunctuation(marcPublisher, punctuation: "/:;,.="))
            ?? nonEmpty(record.publisher)

        let year = extractYear(from: record.publicationYear)
            ?? extractYear(from: firstSubfield(in: record, tag: "264", code: "c"))
            ?? extractYear(from: firstSubfield(in: record, tag: "260", code: "c"))

        let marcLanguage = firstSubfield(in: record, tag: "041", code: "a")
        let language = normalizedLanguage(record.language) ?? normalizedLanguage(marcLanguage)

        return BookMetadata(
            source: .nationalLibrary,
            title: title,
            subtitle: subtitle,
            authors: unique(fallbackAuthors),
            publisher: publisher,
            publicationYear: year,
            language: language
        )
    }

    static func marcAuthors(in record: BibliographicRecord) -> [String] {
        let primaryTags = ["100", "110", "111"]
        let contributorTags = ["700", "710", "711"]
        var result: [String] = []

        for tag in primaryTags {
            for fields in subfieldGroups(in: record, tag: tag) {
                if let name = nonEmpty(trimCatalogPunctuation(fields["a"], punctuation: "/;,.=")) {
                    result.append(name)
                }
            }
        }

        for tag in contributorTags {
            for fields in subfieldGroups(in: record, tag: tag) {
                let role = (fields["e"] ?? fields["4"] ?? "").lowercased()
                let isAuthor = role.contains("autor") || role == "aut"
                guard isAuthor,
                      let name = nonEmpty(trimCatalogPunctuation(fields["a"], punctuation: "/;,.=")) else {
                    continue
                }
                result.append(name)
            }
        }

        return unique(result)
    }

    static func firstSubfield(
        in record: BibliographicRecord,
        tag: String,
        code: String
    ) -> String? {
        subfieldGroups(in: record, tag: tag).compactMap { $0[code] }.first
    }

    static func subfieldGroups(
        in record: BibliographicRecord,
        tag: String
    ) -> [[String: String]] {
        guard let fields = record.marc?.fields else { return [] }

        return fields.compactMap { field in
            guard case let .object(value)? = field[tag],
                  case let .array(rawSubfields)? = value["subfields"] else {
                return nil
            }

            var result: [String: String] = [:]
            for rawSubfield in rawSubfields {
                guard case let .object(subfield) = rawSubfield else { continue }
                for (code, value) in subfield {
                    if case let .string(text) = value, result[code] == nil {
                        result[code] = text
                    }
                }
            }
            return result
        }
    }

    static func normalizedISBN(_ value: String?) -> String? {
        guard let value else { return nil }
        return PublicationIdentifierParser.parse(value).isbn13
    }

    static func trimCatalogPunctuation(_ value: String?, punctuation: String) -> String? {
        guard let value else { return nil }
        let characters = CharacterSet.whitespacesAndNewlines
            .union(CharacterSet(charactersIn: punctuation))
        return value.trimmingCharacters(in: characters)
    }

    static func nonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }
        return value
    }

    static func extractYear(from value: String?) -> Int? {
        guard let value,
              let range = value.range(of: #"\b[12][0-9]{3}\b"#, options: .regularExpression) else {
            return nil
        }
        return Int(value[range])
    }

    static func normalizedLanguage(_ value: String?) -> String? {
        guard let raw = nonEmpty(value) else { return nil }
        let first = raw
            .lowercased()
            .split(whereSeparator: { $0.isWhitespace || $0 == "," || $0 == ";" })
            .first
            .map(String.init) ?? raw.lowercased()

        let codes = [
            "polski": "pl", "pol": "pl",
            "angielski": "en", "eng": "en",
            "niemiecki": "de", "ger": "de", "deu": "de",
            "francuski": "fr", "fre": "fr", "fra": "fr",
            "hiszpański": "es", "spa": "es",
            "włoski": "it", "ita": "it",
            "rosyjski": "ru", "rus": "ru",
            "ukraiński": "uk", "ukr": "uk",
            "czeski": "cs", "cze": "cs", "ces": "cs",
            "słowacki": "sk", "slo": "sk", "slk": "sk",
            "łaciński": "la", "lat": "la"
        ]
        if let code = codes[first] { return code }
        return first.count == 2 ? first : raw
    }

    static func unique(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        return values.filter { value in
            seen.insert(value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)).inserted
        }
    }
}
