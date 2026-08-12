import Foundation

/// Bibliographic data shared by every issue of one periodical series.
///
/// Issue-specific data is deliberately absent from this value. In particular,
/// resolving a known series can never carry over an issue number, date, volume
/// or barcode to the next cataloguing form.
struct PeriodicalSeriesPrefill: Equatable, Sendable {
    let title: String
    let subtitle: String
    let authors: String
    let language: String
    let publisher: String
}

/// Issue-specific fields that must be cleared when a duplicate candidate is
/// explicitly turned into a separate periodical issue. The base EAN-977 may be
/// retained because it identifies the series; its add-on may not.
struct ClearedPeriodicalIssueIdentity: Equatable, Sendable {
    let barcode: String
    let eanSupplement = ""
    let issueNumber = ""
    let issueVolume = ""
    let issueDate = ""
}

enum PeriodicalIssueDraftReset {
    static func clearedIdentity(retainingSeriesEAN ean: String) -> ClearedPeriodicalIssueIdentity {
        let parsed = PublicationIdentifierParser.parse(ean)
        let mainEAN = String(parsed.normalized.prefix(13))
        let canRetainMainEAN = parsed.isValid &&
            parsed.kind == .ean13 &&
            mainEAN.hasPrefix("977") &&
            PublicationIdentifierParser.isValidEAN13(mainEAN)

        return ClearedPeriodicalIssueIdentity(barcode: canRetainMainEAN ? mainEAN : "")
    }
}

/// Selects a previously catalogued periodical series without mutating models.
/// A valid explicit ISSN is authoritative; a valid EAN-977 is used only as
/// equivalent series evidence when an explicit ISSN is unavailable.
enum PeriodicalSeriesPrefillResolver {
    static func prefill(
        in existingItems: [OwnedItem],
        incomingISSN: String,
        incomingEAN: String
    ) -> PeriodicalSeriesPrefill? {
        let incoming = IdentifierEvidence(
            explicitISSN: incomingISSN,
            eanValues: [incomingEAN]
        )
        guard let targetISSN = incoming.authoritativeISSN else {
            return nil
        }

        var seenPublications = Set<ObjectIdentifier>()
        let candidates = existingItems.compactMap { item -> Candidate? in
            guard let publication = item.publication,
                  publication.publicationType == .periodical,
                  seenPublications.insert(ObjectIdentifier(publication)).inserted else {
                return nil
            }

            let evidence = IdentifierEvidence(
                explicitISSN: publication.issn,
                eanValues: [publication.ean, publication.barcode]
            )

            // A valid explicit ISSN wins over contradictory EAN data. Without
            // one, every usable EAN field must identify the same series.
            if let explicitISSN = evidence.validExplicitISSN {
                guard explicitISSN == targetISSN else { return nil }
            } else {
                guard evidence.unambiguousDerivedISSN == targetISSN else { return nil }
            }

            return Candidate(
                publication: publication,
                hasExactExplicitISSN: evidence.validExplicitISSN == targetISSN
            )
        }

        guard let selected = candidates.sorted(by: Candidate.isPreferred).first else {
            return nil
        }

        return PeriodicalSeriesPrefill(
            title: selected.publication.title,
            subtitle: selected.publication.subtitle,
            authors: selected.publication.authorsText,
            language: selected.publication.language,
            publisher: selected.publication.publisher
        )
    }

    private struct Candidate {
        let publication: Publication
        let hasExactExplicitISSN: Bool

        static func isPreferred(_ lhs: Candidate, _ rhs: Candidate) -> Bool {
            if lhs.hasExactExplicitISSN != rhs.hasExactExplicitISSN {
                return lhs.hasExactExplicitISSN
            }
            if lhs.publication.updatedAt != rhs.publication.updatedAt {
                return lhs.publication.updatedAt > rhs.publication.updatedAt
            }

            let lhsID = lhs.publication.id.uuidString.lowercased()
            let rhsID = rhs.publication.id.uuidString.lowercased()
            if lhsID != rhsID {
                return lhsID < rhsID
            }

            // UUIDs are unique in valid collections. This final key merely
            // keeps the helper order-independent for malformed duplicate data.
            return bibliographicKey(lhs.publication) < bibliographicKey(rhs.publication)
        }

        private static func bibliographicKey(_ publication: Publication) -> String {
            [
                publication.title,
                publication.subtitle,
                publication.authorsText,
                publication.language,
                publication.publisher
            ].joined(separator: "\u{1F}")
        }
    }

    private struct IdentifierEvidence {
        let validExplicitISSN: String?
        let derivedISSNs: Set<String>

        init(explicitISSN: String, eanValues: [String]) {
            validExplicitISSN = Self.normalizedValidISSN(explicitISSN)
            derivedISSNs = Set(eanValues.compactMap(Self.derivedISSN))
        }

        var unambiguousDerivedISSN: String? {
            derivedISSNs.count == 1 ? derivedISSNs.first : nil
        }

        var authoritativeISSN: String? {
            validExplicitISSN ?? unambiguousDerivedISSN
        }

        private static func derivedISSN(from value: String) -> String? {
            let parsed = PublicationIdentifierParser.parse(value)
            guard parsed.isValid,
                  parsed.kind == .ean13,
                  parsed.normalized.hasPrefix("977"),
                  let issn = parsed.issn else {
                return nil
            }
            return Self.normalizedValidISSN(issn)
        }

        private static func normalizedValidISSN(_ value: String) -> String? {
            let compact = value.uppercased().filter { $0.isNumber || $0 == "X" }
            guard compact.count == 8 else { return nil }

            let characters = Array(compact)
            guard characters.dropLast().allSatisfy(\.isNumber) else { return nil }

            let sum = characters.dropLast().enumerated().reduce(0) { partial, pair in
                partial + (pair.element.wholeNumberValue ?? 0) * (8 - pair.offset)
            }
            let expectedCheckValue = (11 - (sum % 11)) % 11
            let actualCheckValue: Int
            if characters.last == "X" {
                actualCheckValue = 10
            } else if let digit = characters.last?.wholeNumberValue {
                actualCheckValue = digit
            } else {
                return nil
            }
            guard actualCheckValue == expectedCheckValue else { return nil }

            return "\(compact.prefix(4))-\(compact.suffix(4))"
        }
    }
}
