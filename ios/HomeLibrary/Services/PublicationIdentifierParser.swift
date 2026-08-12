import Foundation

enum PublicationIdentifierKind: String, Codable, Equatable {
    case isbn10
    case isbn13
    case ean13
    case upce
    case unknown
}

struct ParsedPublicationIdentifier: Equatable {
    let kind: PublicationIdentifierKind
    let original: String
    let normalized: String
    let isValid: Bool
    let isbn13: String?
    let issn: String?
    let eanSupplement: String?
}

enum PublicationIdentifierParser {
    static func parse(_ rawValue: String) -> ParsedPublicationIdentifier {
        let compact = rawValue
            .uppercased()
            .filter { $0.isNumber || $0 == "X" }
        let (primary, detectedSupplement) = splitEANSupplement(from: rawValue, compact: compact)

        if primary.count == 10, isValidISBN10(primary) {
            let converted = convertISBN10To13(primary)
            return ParsedPublicationIdentifier(
                kind: .isbn10,
                original: rawValue,
                normalized: primary,
                isValid: true,
                isbn13: converted,
                issn: nil,
                eanSupplement: nil
            )
        }

        if primary.count == 10 {
            return ParsedPublicationIdentifier(
                kind: .isbn10,
                original: rawValue,
                normalized: primary,
                isValid: false,
                isbn13: nil,
                issn: nil,
                eanSupplement: nil
            )
        }

        if primary.count == 13 {
            let valid = isValidEAN13(primary)
            let isISBN = primary.hasPrefix("978") || primary.hasPrefix("979")
            let supplement = valid && primary.hasPrefix("977") ? detectedSupplement : nil
            return ParsedPublicationIdentifier(
                kind: isISBN ? .isbn13 : .ean13,
                original: rawValue,
                normalized: primary,
                isValid: valid,
                isbn13: isISBN && valid ? primary : nil,
                issn: valid ? deriveISSN(from: primary) : nil,
                eanSupplement: supplement
            )
        }

        if primary.count == 8, primary.allSatisfy(\.isNumber) {
            return ParsedPublicationIdentifier(
                kind: .upce,
                original: rawValue,
                normalized: primary,
                isValid: true,
                isbn13: nil,
                issn: nil,
                eanSupplement: nil
            )
        }

        return ParsedPublicationIdentifier(
            kind: .unknown,
            original: rawValue,
            normalized: rawValue.trimmingCharacters(in: .whitespacesAndNewlines),
            isValid: false,
            isbn13: nil,
            issn: nil,
            eanSupplement: nil
        )
    }

    /// Recognizes EAN-2/EAN-5 both in the scanner's canonical `main+addon`
    /// form and in manually entered 15/18-digit forms. The add-on belongs to
    /// periodicals only; ISBN add-ons are intentionally ignored.
    private static func splitEANSupplement(
        from rawValue: String,
        compact: String
    ) -> (primary: String, supplement: String?) {
        let parts = rawValue.split(separator: "+", omittingEmptySubsequences: false)
        if parts.count == 2 {
            let primary = parts[0].uppercased().filter { $0.isNumber || $0 == "X" }
            let supplement = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
            return (
                primary,
                normalizedSupplement(supplement, for: primary)
            )
        }

        guard compact.count == 15 || compact.count == 18 else {
            return (compact, nil)
        }

        let primary = String(compact.prefix(13))
        let supplement = String(compact.dropFirst(13))
        return (
            primary,
            normalizedSupplement(supplement, for: primary)
        )
    }

    private static func normalizedSupplement(_ value: String, for primary: String) -> String? {
        guard primary.hasPrefix("977"),
              value.count == 2 || value.count == 5,
              value.allSatisfy(\.isNumber) else {
            return nil
        }
        return value
    }

    static func isValidEAN13(_ value: String) -> Bool {
        guard value.count == 13,
              value.allSatisfy(\.isNumber),
              let checkDigit = value.last?.wholeNumberValue else {
            return false
        }

        let body = value.dropLast().compactMap(\.wholeNumberValue)
        let sum = body.enumerated().reduce(0) { partial, pair in
            let (index, digit) = pair
            return partial + digit * (index.isMultiple(of: 2) ? 1 : 3)
        }
        return (10 - (sum % 10)) % 10 == checkDigit
    }

    static func isValidISBN10(_ value: String) -> Bool {
        guard value.count == 10 else { return false }
        let characters = Array(value)

        var sum = 0
        for (index, character) in characters.enumerated() {
            let digit: Int
            if character == "X", index == 9 {
                digit = 10
            } else if let number = character.wholeNumberValue {
                digit = number
            } else {
                return false
            }
            sum += digit * (10 - index)
        }
        return sum.isMultiple(of: 11)
    }

    private static func deriveISSN(from ean13: String) -> String? {
        guard ean13.hasPrefix("977") else { return nil }

        let characters = Array(ean13)
        guard characters.count == 13 else { return nil }
        let baseCharacters = characters[3..<10]
        let digits = baseCharacters.compactMap(\.wholeNumberValue)
        guard digits.count == 7 else { return nil }

        let sum = digits.enumerated().reduce(0) { partial, pair in
            let (index, digit) = pair
            return partial + digit * (8 - index)
        }
        let checkValue = (11 - (sum % 11)) % 11
        let checkCharacter = checkValue == 10 ? "X" : String(checkValue)
        let base = String(baseCharacters)

        return "\(base.prefix(4))-\(base.dropFirst(4))\(checkCharacter)"
    }

    private static func convertISBN10To13(_ isbn10: String) -> String {
        let body = "978" + isbn10.prefix(9)
        let sum = body.enumerated().reduce(0) { partial, pair in
            let (index, character) = pair
            let digit = character.wholeNumberValue ?? 0
            return partial + digit * (index.isMultiple(of: 2) ? 1 : 3)
        }
        return body + String((10 - (sum % 10)) % 10)
    }
}
