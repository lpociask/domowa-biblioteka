import Foundation

enum ISSNPortalPeriodicalMetadataServiceError: Error, Equatable {
    case invalidIdentifier
    case invalidEndpoint
    case invalidResponse
    case httpStatus(Int)
    case responseTooLarge
    case malformedResponse
}

/// Reads the freely available basic record page for one exact ISSN.
///
/// This is deliberately a low-volume, user-triggered lookup. It does not use
/// subscription-only fields, search scraping or fuzzy title matching.
struct ISSNPortalPeriodicalMetadataService: PeriodicalMetadataProviding {
    private static let endpoint = URL(string: "https://portal.issn.org")!
    private static let maximumResponseBytes = 1_000_000
    private static let userAgent =
        "HomeLibrary/0.2 (+https://github.com/lpociask/domowa-biblioteka)"

    private let transport: any BookMetadataTransport
    private let observer: BookMetadataLookupObserver

    init(
        session: URLSession = .shared,
        observer: BookMetadataLookupObserver = .disabled
    ) {
        transport = ISSNPortalURLSessionTransport(session: session)
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
            throw ISSNPortalPeriodicalMetadataServiceError.invalidIdentifier
        }

        if Task.isCancelled {
            await observer.record(source: .issnPortal, outcome: .cancelled)
            throw CancellationError()
        }

        guard var components = URLComponents(
            url: Self.endpoint,
            resolvingAgainstBaseURL: false
        ) else {
            throw ISSNPortalPeriodicalMetadataServiceError.invalidEndpoint
        }
        components.path = "/resource/ISSN/\(requestedISSN)"
        guard let url = components.url else {
            throw ISSNPortalPeriodicalMetadataServiceError.invalidEndpoint
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.cachePolicy = .returnCacheDataElseLoad
        request.setValue(
            "text/html,application/xhtml+xml",
            forHTTPHeaderField: "Accept"
        )
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 12

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await transport.data(for: request)
        } catch is CancellationError {
            await observer.record(source: .issnPortal, outcome: .cancelled)
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            await observer.record(source: .issnPortal, outcome: .cancelled)
            throw CancellationError()
        } catch {
            if Task.isCancelled {
                await observer.record(source: .issnPortal, outcome: .cancelled)
                throw CancellationError()
            }
            await observer.record(source: .issnPortal, outcome: .failed)
            throw error
        }

        if Task.isCancelled {
            await observer.record(source: .issnPortal, outcome: .cancelled)
            throw CancellationError()
        }
        guard let httpResponse = response as? HTTPURLResponse else {
            await observer.record(source: .issnPortal, outcome: .failed)
            throw ISSNPortalPeriodicalMetadataServiceError.invalidResponse
        }
        if httpResponse.statusCode == 404 || httpResponse.statusCode == 410 {
            await observer.record(source: .issnPortal, outcome: .notFound)
            return nil
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            await observer.record(source: .issnPortal, outcome: .failed)
            throw ISSNPortalPeriodicalMetadataServiceError.httpStatus(
                httpResponse.statusCode
            )
        }
        guard data.count <= Self.maximumResponseBytes else {
            await observer.record(source: .issnPortal, outcome: .failed)
            throw ISSNPortalPeriodicalMetadataServiceError.responseTooLarge
        }
        guard let html = String(data: data, encoding: .utf8) else {
            await observer.record(source: .issnPortal, outcome: .failed)
            throw ISSNPortalPeriodicalMetadataServiceError.malformedResponse
        }

        do {
            let parsed = try Self.parsePublicRecord(
                html,
                requestedISSN: requestedISSN
            )
            try Task.checkCancellation()
            await observer.record(
                source: .issnPortal,
                outcome: parsed == nil ? .notFound : .found
            )
            return parsed
        } catch is CancellationError {
            await observer.record(source: .issnPortal, outcome: .cancelled)
            throw CancellationError()
        } catch {
            await observer.record(source: .issnPortal, outcome: .failed)
            throw error
        }
    }
}

private struct ISSNPortalURLSessionTransport: BookMetadataTransport {
    let session: URLSession

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await session.data(for: request)
    }
}

private extension ISSNPortalPeriodicalMetadataService {
    static func parsePublicRecord(
        _ html: String,
        requestedISSN: String
    ) throws -> PeriodicalMetadata? {
        // The public basic record exposes the authoritative ISSN in a
        // data-key field. A title or URL alone is never identity evidence.
        guard let rawISSN = firstHTMLValue(
            in: html,
            elementPattern: #"(?:dd|span|div)"#,
            attributePattern: #"data-key\s*=\s*[\"']issn[\"']"#
        ) else {
            throw ISSNPortalPeriodicalMetadataServiceError.malformedResponse
        }
        guard let responseISSN = PeriodicalIdentifierNormalizer.canonicalISSN(
            from: rawISSN
        ) else {
            throw ISSNPortalPeriodicalMetadataServiceError.malformedResponse
        }
        guard responseISSN == requestedISSN else { return nil }

        let title = keyTitle(in: html)
            ?? firstHTMLValue(
                in: html,
                elementPattern: #"(?:dd|span|div)"#,
                attributePattern: #"data-key\s*=\s*[\"']title-proper[\"']"#
            ).map(trimCatalogPunctuation)
            ?? documentTitle(in: html, issn: requestedISSN)

        guard let title, !title.isEmpty else {
            throw ISSNPortalPeriodicalMetadataServiceError.malformedResponse
        }

        return PeriodicalMetadata(
            source: .issnPortal,
            issn: requestedISSN,
            title: title,
            publisher: nil,
            language: nil
        )
    }

    static func firstHTMLValue(
        in html: String,
        elementPattern: String,
        attributePattern: String
    ) -> String? {
        let pattern =
            #"(?is)<("# + elementPattern + #")\b(?=[^>]*\b"# +
            attributePattern + #")[^>]*>(.*?)</\1\s*>"#
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(
                  in: html,
                  range: NSRange(html.startIndex..., in: html)
              ),
              let range = Range(match.range(at: 2), in: html) else {
            return nil
        }
        return normalizedHTMLText(String(html[range]))
    }

    static func keyTitle(in html: String) -> String? {
        let pattern =
            #"(?is)Key\s+title\s*:\s*</[^>]+>\s*<span\b[^>]*>(.*?)</span\s*>"#
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(
                  in: html,
                  range: NSRange(html.startIndex..., in: html)
              ),
              let range = Range(match.range(at: 1), in: html) else {
            return nil
        }
        return normalizedHTMLText(String(html[range]))
    }

    static func documentTitle(in html: String, issn: String) -> String? {
        let pattern = #"(?is)<title\b[^>]*>(.*?)</title\s*>"#
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(
                  in: html,
                  range: NSRange(html.startIndex..., in: html)
              ),
              let range = Range(match.range(at: 1), in: html),
              let value = normalizedHTMLText(String(html[range])) else {
            return nil
        }

        let prefix = "ISSN \(issn) - "
        guard value.hasPrefix(prefix) else { return nil }
        let title = String(value.dropFirst(prefix.count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? nil : title
    }

    static func normalizedHTMLText(_ value: String) -> String? {
        let withoutTags = value.replacingOccurrences(
            of: #"(?is)<[^>]+>"#,
            with: " ",
            options: .regularExpression
        )
        let decoded = decodeBasicEntities(withoutTags)
        let normalized = decoded
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }

    static func decodeBasicEntities(_ value: String) -> String {
        var result = value
        let named = [
            "&amp;": "&", "&quot;": "\"", "&#39;": "'",
            "&apos;": "'", "&lt;": "<", "&gt;": ">", "&nbsp;": " "
        ]
        for (entity, replacement) in named {
            result = result.replacingOccurrences(of: entity, with: replacement)
        }

        let pattern = #"&#(?:x([0-9A-Fa-f]+)|([0-9]+));"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else {
            return result
        }
        let matches = expression.matches(
            in: result,
            range: NSRange(result.startIndex..., in: result)
        )
        for match in matches.reversed() {
            guard let fullRange = Range(match.range(at: 0), in: result) else {
                continue
            }
            let hex = Range(match.range(at: 1), in: result).map {
                String(result[$0])
            }
            let decimal = Range(match.range(at: 2), in: result).map {
                String(result[$0])
            }
            let scalarValue = hex.flatMap { UInt32($0, radix: 16) }
                ?? decimal.flatMap { UInt32($0, radix: 10) }
            guard let scalarValue,
                  let scalar = UnicodeScalar(scalarValue) else { continue }
            result.replaceSubrange(fullRange, with: String(Character(scalar)))
        }
        return result
    }

    static func trimCatalogPunctuation(_ value: String) -> String {
        value.trimmingCharacters(
            in: .whitespacesAndNewlines.union(
                CharacterSet(charactersIn: "/:;,.=")
            )
        )
    }
}
