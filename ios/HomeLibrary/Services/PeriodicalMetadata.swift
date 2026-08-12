import Foundation

enum PeriodicalMetadataSource: String, Codable, Equatable, Sendable {
    case nationalLibrary = "bn"

    var displayName: String {
        switch self {
        case .nationalLibrary:
            "Biblioteki Narodowej"
        }
    }
}

/// Series-level metadata for a periodical. Issue number, date, volume and the
/// EAN add-on are intentionally absent: an ISSN identifies the continuing
/// publication, not one physical issue.
struct PeriodicalMetadata: Codable, Equatable, Sendable {
    let source: PeriodicalMetadataSource
    let issn: String
    let title: String?
    let publisher: String?
    let language: String?

    var hasUsefulData: Bool {
        title != nil || publisher != nil || language != nil
    }
}

protocol PeriodicalMetadataProviding: Sendable {
    /// Accepts either an ISSN or a valid EAN-977 (with an optional EAN-2/EAN-5
    /// add-on) and resolves metadata for the periodical series.
    func lookup(identifier: String) async throws -> PeriodicalMetadata?
}

enum PeriodicalMetadataLookupError: Error, Equatable {
    case invalidIdentifier
}

/// Strict normalization shared by remote periodical lookups. An EAN-977 is
/// useful only when both its EAN check digit and its derived ISSN check digit
/// are valid. A raw ISSN is returned in the canonical `1234-567X` form.
enum PeriodicalIdentifierNormalizer {
    static func canonicalISSN(from rawValue: String) -> String? {
        let parsedEAN = PublicationIdentifierParser.parse(rawValue)
        if parsedEAN.isValid,
           parsedEAN.kind == .ean13,
           parsedEAN.normalized.hasPrefix("977"),
           let derivedISSN = parsedEAN.issn {
            return canonicalISSN(fromRawISSN: derivedISSN)
        }

        return canonicalISSN(fromRawISSN: rawValue)
    }

    private static func canonicalISSN(fromRawISSN rawValue: String) -> String? {
        let compact = rawValue.uppercased().filter { $0.isNumber || $0 == "X" }
        guard compact.count == 8 else { return nil }

        let characters = Array(compact)
        guard characters.dropLast().allSatisfy(\.isNumber) else { return nil }

        let weightedSum = characters.dropLast().enumerated().reduce(0) { partial, pair in
            partial + (pair.element.wholeNumberValue ?? 0) * (8 - pair.offset)
        }
        let expected = (11 - (weightedSum % 11)) % 11
        let actual: Int
        if characters.last == "X" {
            actual = 10
        } else if let digit = characters.last?.wholeNumberValue {
            actual = digit
        } else {
            return nil
        }

        guard actual == expected else { return nil }
        return "\(compact.prefix(4))-\(compact.suffix(4))"
    }
}
