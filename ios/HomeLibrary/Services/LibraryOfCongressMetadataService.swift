import Foundation

enum LibraryOfCongressMetadataServiceError: Error, Equatable {
    case invalidISBN
    case invalidEndpoint
    case invalidResponse
    case httpStatus(Int)
    case responseTooLarge
    case malformedResponse
}

/// Low-volume exact-ISBN lookup against the Library of Congress LCDB SRU
/// service. MODS records are accepted only when one record identifier
/// normalizes to the requested ISBN-13.
struct LibraryOfCongressMetadataService: BookMetadataProviding {
    private static let endpoint = URL(string: "https://lx2.loc.gov/sru/lcdb")!
    private static let maximumRecords = "10"
    private static let maximumResponseBytes = 5_000_000
    private static let userAgent =
        "HomeLibrary/0.2 (+https://github.com/lpociask/domowa-biblioteka)"

    private let transport: any BookMetadataTransport

    init(session: URLSession = .shared) {
        transport = LibraryOfCongressURLSessionTransport(session: session)
    }

    init(transport: any BookMetadataTransport) {
        self.transport = transport
    }

    func lookup(isbn rawISBN: String) async throws -> BookMetadata? {
        let parsed = PublicationIdentifierParser.parse(rawISBN)
        guard parsed.isValid,
              parsed.kind == .isbn10 || parsed.kind == .isbn13,
              let isbn13 = parsed.isbn13 else {
            throw LibraryOfCongressMetadataServiceError.invalidISBN
        }

        try Task.checkCancellation()

        guard var components = URLComponents(
            url: Self.endpoint,
            resolvingAgainstBaseURL: false
        ) else {
            throw LibraryOfCongressMetadataServiceError.invalidEndpoint
        }
        components.queryItems = [
            URLQueryItem(name: "version", value: "1.1"),
            URLQueryItem(name: "operation", value: "searchRetrieve"),
            URLQueryItem(name: "query", value: "bath.isbn=\"\(isbn13)\""),
            URLQueryItem(name: "maximumRecords", value: Self.maximumRecords),
            URLQueryItem(name: "recordSchema", value: "mods")
        ]
        guard let url = components.url else {
            throw LibraryOfCongressMetadataServiceError.invalidEndpoint
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.cachePolicy = .returnCacheDataElseLoad
        request.setValue(
            "application/xml,text/xml",
            forHTTPHeaderField: "Accept"
        )
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 12

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await transport.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw error
        }

        try Task.checkCancellation()
        guard let httpResponse = response as? HTTPURLResponse else {
            throw LibraryOfCongressMetadataServiceError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw LibraryOfCongressMetadataServiceError.httpStatus(
                httpResponse.statusCode
            )
        }
        guard data.count <= Self.maximumResponseBytes else {
            throw LibraryOfCongressMetadataServiceError.responseTooLarge
        }

        let delegate = LibraryOfCongressMODSParser(requestedISBN: isbn13)
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldProcessNamespaces = true
        parser.shouldReportNamespacePrefixes = false
        parser.shouldResolveExternalEntities = false
        guard parser.parse(), delegate.isStructurallyValid else {
            throw LibraryOfCongressMetadataServiceError.malformedResponse
        }

        try Task.checkCancellation()
        return delegate.unambiguousMetadata
    }
}

private struct LibraryOfCongressURLSessionTransport: BookMetadataTransport {
    let session: URLSession

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await session.data(for: request)
    }
}

private final class LibraryOfCongressMODSParser: NSObject, XMLParserDelegate {
    private struct Record {
        var identifiers: [String] = []
        var titleParts: [String] = []
        var subTitleParts: [String] = []
        var personalNameParts: [String] = []
        var corporateNameParts: [String] = []
        var publishers: [String] = []
        var dates: [String] = []
        var languages: [String] = []
    }

    private struct Capture {
        enum Kind {
            case identifier
            case title
            case subtitle
            case namePart
            case publisher
            case dateIssued
            case language
        }

        let kind: Kind
        var text = ""
    }

    private let requestedISBN: String
    private var elementStack: [String] = []
    private var currentRecord: Record?
    private var capture: Capture?
    private var currentNameType: String?
    private var currentNameIsCreator = false
    private var currentTitleInfoIsPrimary = false
    private var currentOriginInfoIsPrimary = false
    private var currentLanguageIsPrimary = false
    private var records: [Record] = []
    private(set) var sawSRUResponse = false
    private(set) var sawRecordsContainer = false

    init(requestedISBN: String) {
        self.requestedISBN = requestedISBN
    }

    var isStructurallyValid: Bool {
        sawSRUResponse && sawRecordsContainer
    }

    var unambiguousMetadata: BookMetadata? {
        let exact = records.filter { record in
            record.identifiers.contains(where: { rawIdentifier in
                PublicationIdentifierParser.parse(rawIdentifier).isbn13 == requestedISBN
            })
        }
        let values = exact.compactMap(Self.metadata)
        guard let first = values.first else { return nil }

        let titleKeys = Set(values.compactMap(\.title).map(Self.identityKey))
        guard titleKeys.count <= 1 else { return nil }

        return values.sorted { lhs, rhs in
            let lhsScore = Self.completeness(lhs)
            let rhsScore = Self.completeness(rhs)
            if lhsScore != rhsScore { return lhsScore > rhsScore }
            return (lhs.title ?? "") < (rhs.title ?? "")
        }.first ?? first
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        let name = Self.localName(elementName)
        elementStack.append(name)

        if name == "searchRetrieveResponse" { sawSRUResponse = true }
        if name == "records" { sawRecordsContainer = true }
        if name == "mods" {
            currentRecord = Record()
            return
        }
        guard currentRecord != nil else { return }

        switch name {
        case "titleInfo":
            currentTitleInfoIsPrimary = parentName == "mods" &&
                attributeDict["type"] == nil
        case "name":
            currentNameIsCreator = parentName == "mods"
            currentNameType = attributeDict["type"]?.lowercased()
        case "originInfo":
            currentOriginInfoIsPrimary = parentName == "mods"
        case "language":
            currentLanguageIsPrimary = parentName == "mods"
        case "identifier" where parentName == "mods" &&
            attributeDict["type"]?.lowercased() == "isbn":
            capture = Capture(kind: .identifier)
        case "title" where parentName == "titleInfo" &&
            currentTitleInfoIsPrimary:
            capture = Capture(kind: .title)
        case "subTitle" where parentName == "titleInfo" &&
            currentTitleInfoIsPrimary:
            capture = Capture(kind: .subtitle)
        case "namePart" where parentName == "name" && currentNameIsCreator:
            capture = Capture(kind: .namePart)
        case "publisher" where parentName == "originInfo" &&
            currentOriginInfoIsPrimary:
            capture = Capture(kind: .publisher)
        case "dateIssued" where parentName == "originInfo" &&
            currentOriginInfoIsPrimary:
            capture = Capture(kind: .dateIssued)
        case "languageTerm" where parentName == "language" &&
            currentLanguageIsPrimary:
            capture = Capture(kind: .language)
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        capture?.text.append(string)
    }

    func parser(
        _ parser: XMLParser,
        resolveExternalEntityName name: String,
        systemID: String?
    ) -> Data? {
        // Network/file entity resolution is never needed for an SRU payload.
        nil
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        let name = Self.localName(elementName)

        if let activeCapture = capture,
           Self.captureElement(for: activeCapture.kind) == name {
            let value = Self.nonEmpty(activeCapture.text)
            if let value {
                switch activeCapture.kind {
                case .identifier:
                    currentRecord?.identifiers.append(value)
                case .title:
                    currentRecord?.titleParts.append(value)
                case .subtitle:
                    currentRecord?.subTitleParts.append(value)
                case .namePart:
                    if currentNameType == "corporate" {
                        currentRecord?.corporateNameParts.append(value)
                    } else {
                        currentRecord?.personalNameParts.append(value)
                    }
                case .publisher:
                    currentRecord?.publishers.append(value)
                case .dateIssued:
                    currentRecord?.dates.append(value)
                case .language:
                    currentRecord?.languages.append(value)
                }
            }
            capture = nil
        }

        if name == "titleInfo" { currentTitleInfoIsPrimary = false }
        if name == "name" {
            currentNameType = nil
            currentNameIsCreator = false
        }
        if name == "originInfo" { currentOriginInfoIsPrimary = false }
        if name == "language" { currentLanguageIsPrimary = false }
        if name == "mods", let currentRecord {
            records.append(currentRecord)
            self.currentRecord = nil
        }
        if !elementStack.isEmpty { elementStack.removeLast() }
    }

    private var parentName: String? {
        elementStack.dropLast().last
    }

    private static func captureElement(for kind: Capture.Kind) -> String {
        switch kind {
        case .identifier: "identifier"
        case .title: "title"
        case .subtitle: "subTitle"
        case .namePart: "namePart"
        case .publisher: "publisher"
        case .dateIssued: "dateIssued"
        case .language: "languageTerm"
        }
    }

    private static func metadata(from record: Record) -> BookMetadata? {
        let title = unique(record.titleParts).first
        let subtitle = unique(record.subTitleParts).first
        let authors = unique(record.personalNameParts + record.corporateNameParts)
        let publisher = unique(record.publishers).first
        let year = record.dates.compactMap(extractYear).first
        let language = record.languages.compactMap(normalizedLanguage).first

        let metadata = BookMetadata(
            source: .libraryOfCongress,
            title: title,
            subtitle: subtitle,
            authors: authors,
            publisher: publisher,
            publicationYear: year,
            language: language
        )
        return metadata.hasUsefulData ? metadata : nil
    }

    private static func localName(_ value: String) -> String {
        value.split(separator: ":").last.map(String.init) ?? value
    }

    private static func nonEmpty(_ value: String?) -> String? {
        let result = value?
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return result?.isEmpty == false ? result : nil
    }

    private static func unique(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        return values.compactMap { value in
            guard let cleaned = nonEmpty(value),
                  seen.insert(identityKey(cleaned)).inserted else { return nil }
            return cleaned
        }
    }

    private static func identityKey(_ value: String) -> String {
        value.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        ).lowercased().filter { $0.isLetter || $0.isNumber }
    }

    private static func extractYear(_ value: String) -> Int? {
        guard let range = value.range(
            of: #"\b[12][0-9]{3}\b"#,
            options: .regularExpression
        ) else { return nil }
        return Int(value[range])
    }

    private static func normalizedLanguage(_ value: String) -> String? {
        guard let raw = nonEmpty(value)?.lowercased() else { return nil }
        let code = raw.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? raw
        let mappings = [
            "eng": "en", "pol": "pl", "ger": "de", "deu": "de",
            "fre": "fr", "fra": "fr", "spa": "es", "ita": "it",
            "rus": "ru"
        ]
        return mappings[code] ?? (code.count == 2 ? code : raw)
    }

    private static func completeness(_ metadata: BookMetadata) -> Int {
        (metadata.title == nil ? 0 : 2) +
            (metadata.subtitle == nil ? 0 : 1) +
            (metadata.authors.isEmpty ? 0 : 1) +
            (metadata.publisher == nil ? 0 : 1) +
            (metadata.publicationYear == nil ? 0 : 1) +
            (metadata.language == nil ? 0 : 1)
    }
}
