import Foundation

struct PeriodicalRecognizedTextLine: Equatable, Sendable {
    let text: String
    let confidence: Float
}

struct PeriodicalIssueTextSuggestion: Equatable, Sendable {
    let value: String
    let confidence: Float
    let evidence: String
}

struct PeriodicalIssueTextSuggestions: Equatable, Sendable {
    let issueNumber: PeriodicalIssueTextSuggestion?
    let issueVolume: PeriodicalIssueTextSuggestion?
    let issueDate: PeriodicalIssueTextSuggestion?

    static let empty = PeriodicalIssueTextSuggestions(
        issueNumber: nil,
        issueVolume: nil,
        issueDate: nil
    )
}

/// Extracts conservative, review-only suggestions from OCR text found on a
/// periodical cover. The parser never mutates catalog data and deliberately
/// ignores ambiguous, unlabelled numbers.
enum PeriodicalIssueTextParser {
    private static let minimumConfidence: Float = 0.3

    private struct Candidate {
        let value: String
        let confidence: Float
        let evidence: String
        let quality: Int
    }

    private static let issueRegex = try! NSRegularExpression(
        pattern: #"(?<![a-z0-9])(?:nr|numer|no|issue|ausgabe|heft)\s*[.:#-]?\s*([0-9]{1,4}\s*-\s*[0-9]{1,4}\s*/\s*[0-9]{4}|[0-9]{1,4}\s*/\s*[0-9]{4}|[0-9]{1,4})(?![0-9/-])"#
    )

    private static let volumeRegex = try! NSRegularExpression(
        pattern: #"(?<![a-z0-9])(?:tom|vol|volume|band|jahrgang)\s*[.:#-]?\s*([0-9]{1,4})(?![0-9/-])"#
    )

    private static let isoMonthRegex = try! NSRegularExpression(
        pattern: #"(?<![0-9-])((?:18|19|20|21)[0-9]{2})-(0[1-9]|1[0-2])(?![0-9-])"#
    )

    private static let fullDateRegex = try! NSRegularExpression(
        pattern: #"(?<![0-9.])(0?[1-9]|[12][0-9]|3[01])\.(0?[1-9]|1[0-2])\.((?:18|19|20|21)[0-9]{2})(?![0-9.])"#
    )

    private static let monthNames: [String: Int] = [
        // Polish (nominative and the forms commonly printed with a year/date).
        "styczen": 1, "stycznia": 1,
        "luty": 2, "lutego": 2,
        "marzec": 3, "marca": 3,
        "kwiecien": 4, "kwietnia": 4,
        "maj": 5, "maja": 5,
        "czerwiec": 6, "czerwca": 6,
        "lipiec": 7, "lipca": 7,
        "sierpien": 8, "sierpnia": 8,
        "wrzesien": 9, "wrzesnia": 9,
        "pazdziernik": 10, "pazdziernika": 10,
        "listopad": 11, "listopada": 11,
        "grudzien": 12, "grudnia": 12,

        // English.
        "january": 1, "february": 2, "march": 3, "april": 4,
        "may": 5, "june": 6, "july": 7, "august": 8,
        "september": 9, "october": 10, "november": 11, "december": 12,

        // German. Both spellings of Maerz/März are supported after folding.
        "januar": 1, "februar": 2, "marz": 3, "maerz": 3,
        "mai": 5, "juni": 6, "juli": 7, "oktober": 10,
        "dezember": 12
    ]

    private static let monthNameAlternation = monthNames.keys
        .sorted { lhs, rhs in
            lhs.count == rhs.count ? lhs < rhs : lhs.count > rhs.count
        }
        .map(NSRegularExpression.escapedPattern(for:))
        .joined(separator: "|")

    private static let namedMonthThenYearRegex = try! NSRegularExpression(
        pattern: "(?<![a-z])(" + monthNameAlternation + ")\\s*[,./-]?\\s+((?:18|19|20|21)[0-9]{2})(?![0-9])"
    )

    private static let yearThenNamedMonthRegex = try! NSRegularExpression(
        pattern: "(?<![0-9])((?:18|19|20|21)[0-9]{2})\\s*[,./-]?\\s+(" + monthNameAlternation + ")(?![a-z])"
    )

    private static let identifierMarkers = try! NSRegularExpression(
        pattern: #"(?<![a-z])(?:isbn|issn|ean|upc|barcode|strichcode)(?![a-z])|kod\s+kreskowy"#
    )

    private static let priceMarkers = try! NSRegularExpression(
        pattern: #"(?<![a-z])(?:cena|price|preis|pln|eur|usd|gbp|chf|cad|aud|zl|zł)(?![a-z])|[€$£]"#
    )

    static func parse(_ lines: [PeriodicalRecognizedTextLine]) -> PeriodicalIssueTextSuggestions {
        var issueCandidates: [Candidate] = []
        var volumeCandidates: [Candidate] = []
        var dateCandidates: [Candidate] = []

        for line in lines {
            guard line.confidence.isFinite, line.confidence >= minimumConfidence else {
                continue
            }

            let evidence = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !evidence.isEmpty else { continue }

            let confidence = min(line.confidence, 1)
            let normalized = normalizedForMatching(evidence)
            guard !containsMatch(identifierMarkers, in: normalized),
                  !containsMatch(priceMarkers, in: normalized) else {
                continue
            }

            if let captured = firstCapture(issueRegex, in: normalized),
               let normalizedIssue = normalizeIssueNumber(captured.value) {
                issueCandidates.append(
                    Candidate(
                        value: normalizedIssue.value,
                        confidence: confidence,
                        evidence: evidence,
                        quality: normalizedIssue.quality
                    )
                )
            }

            if let captured = firstCapture(volumeRegex, in: normalized),
               let value = positiveIntegerString(captured.value) {
                volumeCandidates.append(
                    Candidate(value: value, confidence: confidence, evidence: evidence, quality: 100)
                )
            }

            dateCandidates.append(
                contentsOf: extractDateCandidates(
                    in: normalized,
                    evidence: evidence,
                    confidence: confidence
                )
            )
        }

        return PeriodicalIssueTextSuggestions(
            issueNumber: bestSuggestion(from: issueCandidates),
            issueVolume: bestSuggestion(from: volumeCandidates),
            issueDate: bestSuggestion(from: dateCandidates)
        )
    }

    private static func extractDateCandidates(
        in normalized: String,
        evidence: String,
        confidence: Float
    ) -> [Candidate] {
        var candidates: [Candidate] = []

        for captures in captures(fullDateRegex, in: normalized, groups: 3) {
            guard let day = Int(captures[0]),
                  let month = Int(captures[1]),
                  let year = Int(captures[2]),
                  isValidDate(day: day, month: month, year: year) else {
                continue
            }
            candidates.append(
                Candidate(
                    value: String(format: "%04d-%02d-%02d", year, month, day),
                    confidence: confidence,
                    evidence: evidence,
                    quality: 300
                )
            )
        }

        for captures in captures(isoMonthRegex, in: normalized, groups: 2) {
            guard let year = Int(captures[0]), let month = Int(captures[1]) else { continue }
            candidates.append(
                Candidate(
                    value: String(format: "%04d-%02d", year, month),
                    confidence: confidence,
                    evidence: evidence,
                    quality: 200
                )
            )
        }

        for captures in captures(namedMonthThenYearRegex, in: normalized, groups: 2) {
            guard let month = monthNames[captures[0]], let year = Int(captures[1]) else { continue }
            candidates.append(namedMonthCandidate(year: year, month: month, evidence: evidence, confidence: confidence))
        }

        for captures in captures(yearThenNamedMonthRegex, in: normalized, groups: 2) {
            guard let year = Int(captures[0]), let month = monthNames[captures[1]] else { continue }
            candidates.append(namedMonthCandidate(year: year, month: month, evidence: evidence, confidence: confidence))
        }

        return candidates
    }

    private static func namedMonthCandidate(
        year: Int,
        month: Int,
        evidence: String,
        confidence: Float
    ) -> Candidate {
        Candidate(
            value: String(format: "%04d-%02d", year, month),
            confidence: confidence,
            evidence: evidence,
            quality: 150
        )
    }

    private static func normalizeIssueNumber(_ rawValue: String) -> (value: String, quality: Int)? {
        let compact = rawValue.replacingOccurrences(of: " ", with: "")

        if let slashIndex = compact.lastIndex(of: "/") {
            let issuePart = String(compact[..<slashIndex])
            let yearPart = String(compact[compact.index(after: slashIndex)...])
            guard yearPart.count == 4,
                  let year = Int(yearPart),
                  (1800...2199).contains(year) else {
                return nil
            }

            if let dashIndex = issuePart.firstIndex(of: "-") {
                let firstPart = String(issuePart[..<dashIndex])
                let secondPart = String(issuePart[issuePart.index(after: dashIndex)...])
                guard let first = positiveInteger(firstPart),
                      let second = positiveInteger(secondPart),
                      first <= second else {
                    return nil
                }
                return ("\(first)-\(second)/\(year)", 300)
            }

            guard let issue = positiveInteger(issuePart) else { return nil }
            return ("\(issue)/\(year)", 200)
        }

        guard !compact.contains("-"), let issue = positiveInteger(compact) else { return nil }
        return (String(issue), 100)
    }

    private static func positiveIntegerString(_ rawValue: String) -> String? {
        guard let value = positiveInteger(rawValue) else { return nil }
        return String(value)
    }

    private static func positiveInteger(_ rawValue: String) -> Int? {
        guard !rawValue.isEmpty,
              rawValue.allSatisfy(\.isNumber),
              let value = Int(rawValue),
              (1...9999).contains(value) else {
            return nil
        }
        return value
    }

    private static func isValidDate(day: Int, month: Int, year: Int) -> Bool {
        guard (1800...2199).contains(year), (1...12).contains(month) else { return false }
        let leapYear = year.isMultiple(of: 400) || (year.isMultiple(of: 4) && !year.isMultiple(of: 100))
        let daysInMonth = [31, leapYear ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
        return (1...daysInMonth[month - 1]).contains(day)
    }

    private static func bestSuggestion(from candidates: [Candidate]) -> PeriodicalIssueTextSuggestion? {
        let best = candidates.sorted(by: candidatePrecedes).first
        return best.map {
            PeriodicalIssueTextSuggestion(value: $0.value, confidence: $0.confidence, evidence: $0.evidence)
        }
    }

    /// Stable tie-break: OCR confidence, parser specificity, canonical value,
    /// then evidence. It does not depend on the input order.
    private static func candidatePrecedes(_ lhs: Candidate, _ rhs: Candidate) -> Bool {
        if lhs.confidence != rhs.confidence { return lhs.confidence > rhs.confidence }
        if lhs.quality != rhs.quality { return lhs.quality > rhs.quality }
        if lhs.value != rhs.value { return lhs.value < rhs.value }
        return lhs.evidence < rhs.evidence
    }

    private static func normalizedForMatching(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\u{00A0}", with: " ")
            .replacingOccurrences(of: "–", with: "-")
            .replacingOccurrences(of: "—", with: "-")
            .folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
            .lowercased()
    }

    private static func firstCapture(
        _ regex: NSRegularExpression,
        in value: String
    ) -> (value: String, range: NSRange)? {
        let searchRange = NSRange(value.startIndex..<value.endIndex, in: value)
        guard let match = regex.firstMatch(in: value, range: searchRange),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: value) else {
            return nil
        }
        return (String(value[range]), match.range(at: 1))
    }

    private static func captures(
        _ regex: NSRegularExpression,
        in value: String,
        groups: Int
    ) -> [[String]] {
        let searchRange = NSRange(value.startIndex..<value.endIndex, in: value)
        return regex.matches(in: value, range: searchRange).compactMap { match in
            guard match.numberOfRanges > groups else { return nil }
            var values: [String] = []
            for group in 1...groups {
                guard let range = Range(match.range(at: group), in: value) else { return nil }
                values.append(String(value[range]))
            }
            return values
        }
    }

    private static func containsMatch(_ regex: NSRegularExpression, in value: String) -> Bool {
        let searchRange = NSRange(value.startIndex..<value.endIndex, in: value)
        return regex.firstMatch(in: value, range: searchRange) != nil
    }
}
