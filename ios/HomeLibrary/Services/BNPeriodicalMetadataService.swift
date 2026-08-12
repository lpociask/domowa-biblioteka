import Foundation

enum BNPeriodicalMetadataServiceError: Error, Equatable {
    case invalidIdentifier
    case invalidEndpoint
    case invalidResponse
    case httpStatus(Int)
    case malformedResponse
}

/// Resolves a periodical series by exact ISSN in the National Library API.
///
/// The `kind=czasopismo` filter and a second, local exact-ISSN check are both
/// required. The BN index also contains articles carrying their parent ISSN;
/// accepting such a record would silently assign an article title to a whole
/// magazine series.
struct BNPeriodicalMetadataService: PeriodicalMetadataProviding {
    private static let endpoint = URL(
        string: "https://data.bn.org.pl/api/institutions/bibs.json"
    )!
    private static let resultLimit = "10"
    private static let userAgent =
        "HomeLibrary/0.2 (+https://github.com/lpociask/domowa-biblioteka)"

    private let transport: any BookMetadataTransport
    private let observer: BookMetadataLookupObserver

    init(
        session: URLSession = .shared,
        observer: BookMetadataLookupObserver = .disabled
    ) {
        transport = BNPeriodicalURLSessionTransport(session: session)
        self.observer = observer
    }

    init(
        transport: any BookMetadataTransport,
        observer: BookMetadataLookupObserver = .disabled
    ) {
        self.transport = transport
        self.observer = observer
    }

    func lookup(identifier rawIdentifier: String) async throws -> PeriodicalMetadata? {
        guard let requestedISSN = PeriodicalIdentifierNormalizer.canonicalISSN(
            from: rawIdentifier
        ) else {
            throw BNPeriodicalMetadataServiceError.invalidIdentifier
        }

        do {
            try Task.checkCancellation()
            let metadata = try await fetch(issn: requestedISSN)
            try Task.checkCancellation()
            await observer.record(
                source: .nationalLibrary,
                outcome: metadata == nil ? .notFound : .found
            )
            return metadata
        } catch is CancellationError {
            await observer.record(source: .nationalLibrary, outcome: .cancelled)
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            await observer.record(source: .nationalLibrary, outcome: .cancelled)
            throw CancellationError()
        } catch {
            if Task.isCancelled {
                await observer.record(source: .nationalLibrary, outcome: .cancelled)
                throw CancellationError()
            }
            await observer.record(source: .nationalLibrary, outcome: .failed)
            throw error
        }
    }
}

private struct BNPeriodicalURLSessionTransport: BookMetadataTransport {
    let session: URLSession

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await session.data(for: request)
    }
}

private extension BNPeriodicalMetadataService {
    struct Response: Decodable {
        let bibs: [BibliographicRecord]?
    }

    struct BibliographicRecord: Decodable {
        let deleted: Bool?
        let kind: String?
        let language: String?
        let isbnIssn: String?
        let title: String?
        let publisher: String?
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

    func fetch(issn: String) async throws -> PeriodicalMetadata? {
        guard var components = URLComponents(
            url: Self.endpoint,
            resolvingAgainstBaseURL: false
        ) else {
            throw BNPeriodicalMetadataServiceError.invalidEndpoint
        }
        components.queryItems = [
            // BN requires the printed, hyphenated ISSN here. The compact form
            // can return no records even though the series exists.
            URLQueryItem(name: "isbnIssn", value: issn),
            URLQueryItem(name: "kind", value: "czasopismo"),
            URLQueryItem(name: "limit", value: Self.resultLimit)
        ]
        guard let url = components.url else {
            throw BNPeriodicalMetadataServiceError.invalidEndpoint
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.cachePolicy = .returnCacheDataElseLoad
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 12

        let (data, response) = try await transport.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw BNPeriodicalMetadataServiceError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw BNPeriodicalMetadataServiceError.httpStatus(httpResponse.statusCode)
        }

        let payload: Response
        do {
            payload = try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw BNPeriodicalMetadataServiceError.malformedResponse
        }

        let matchingRecords = (payload.bibs ?? []).filter { record in
            record.deleted != true &&
                Self.normalizedKind(record.kind) == "czasopismo" &&
                Self.issnCandidates(in: record).contains(issn)
        }

        // More than one exact serial record can legitimately exist after a
        // title split. Prefer a record only when every candidate describes the
        // same normalized title; otherwise manual confirmation is safer.
        let useful = matchingRecords.compactMap { record -> PeriodicalMetadata? in
            let metadata = Self.metadata(from: record, issn: issn)
            return metadata.hasUsefulData ? metadata : nil
        }
        guard let first = useful.first else { return nil }
        let titles = useful.compactMap { $0.title }
        let titleKeys = Set(titles.map(Self.normalizedIdentity))
        guard titleKeys.count <= 1 else { return nil }
        return first
    }

    static func metadata(
        from record: BibliographicRecord,
        issn: String
    ) -> PeriodicalMetadata {
        let marcTitle = firstSubfield(in: record, tag: "245", code: "a")
            ?? firstSubfield(in: record, tag: "222", code: "a")
        let marcPublisher = firstSubfield(in: record, tag: "264", code: "b")
            ?? firstSubfield(in: record, tag: "260", code: "b")
        let marcLanguage = firstSubfield(in: record, tag: "041", code: "a")

        return PeriodicalMetadata(
            source: .nationalLibrary,
            issn: issn,
            title: nonEmpty(trimCatalogPunctuation(marcTitle, punctuation: "/:;,.="))
                ?? nonEmpty(record.title),
            publisher: nonEmpty(
                trimCatalogPunctuation(marcPublisher, punctuation: "/:;,.=")
            ) ?? nonEmpty(record.publisher),
            language: normalizedLanguage(record.language)
                ?? normalizedLanguage(marcLanguage)
        )
    }

    static func issnCandidates(in record: BibliographicRecord) -> Set<String> {
        var rawValues = record.isbnIssn.map { [$0] } ?? []
        // 022$a is the valid ISSN. 022$y/$z are incorrect or cancelled ISSNs
        // and must never count as exact identity evidence.
        rawValues.append(contentsOf: subfieldValues(in: record, tag: "022", code: "a"))
        return Set(rawValues.flatMap(issnCandidates))
    }

    static func issnCandidates(from rawValue: String) -> [String] {
        let tokens = rawValue.split(whereSeparator: { character in
            !character.isNumber && character != "X" && character != "x" &&
                character != "-" && character != "‐" && character != "‑"
        })
        var seen: Set<String> = []
        return ([rawValue] + tokens.map(String.init)).compactMap { candidate in
            guard let normalized = PeriodicalIdentifierNormalizer.canonicalISSN(
                from: candidate
            ), seen.insert(normalized).inserted else {
                return nil
            }
            return normalized
        }
    }

    static func firstSubfield(
        in record: BibliographicRecord,
        tag: String,
        code: String
    ) -> String? {
        subfieldValues(in: record, tag: tag, code: code).first
    }

    static func subfieldValues(
        in record: BibliographicRecord,
        tag: String,
        code: String
    ) -> [String] {
        guard let fields = record.marc?.fields else { return [] }
        return fields.flatMap { field -> [String] in
            guard case let .object(value)? = field[tag],
                  case let .array(rawSubfields)? = value["subfields"] else {
                return []
            }
            return rawSubfields.compactMap { rawSubfield in
                guard case let .object(subfield) = rawSubfield,
                      case let .string(text)? = subfield[code] else {
                    return nil
                }
                return text
            }
        }
    }

    static func normalizedKind(_ value: String?) -> String? {
        nonEmpty(value)?.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: Locale(identifier: "pl_PL")
        ).lowercased()
    }

    static func normalizedIdentity(_ value: String) -> String {
        value.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: Locale(identifier: "pl_PL")
        )
        .lowercased()
        .filter { $0.isLetter || $0.isNumber }
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

    static func normalizedLanguage(_ value: String?) -> String? {
        guard let raw = nonEmpty(value) else { return nil }
        let first = raw.lowercased()
            .split(whereSeparator: { $0.isWhitespace || $0 == "," || $0 == ";" })
            .first.map(String.init) ?? raw.lowercased()
        let codes = [
            "polski": "pl", "pol": "pl", "angielski": "en", "eng": "en",
            "niemiecki": "de", "ger": "de", "deu": "de", "francuski": "fr",
            "fre": "fr", "fra": "fr", "hiszpański": "es", "spa": "es",
            "włoski": "it", "ita": "it", "rosyjski": "ru", "rus": "ru"
        ]
        if let code = codes[first] { return code }
        return first.count == 2 ? first : raw
    }
}
