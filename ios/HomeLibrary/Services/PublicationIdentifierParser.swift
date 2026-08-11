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
}

enum PublicationIdentifierParser {
    static func parse(_ rawValue: String) -> ParsedPublicationIdentifier {
        let compact = rawValue
            .uppercased()
            .filter { $0.isNumber || $0 == "X" }

        if compact.count == 10, isValidISBN10(compact) {
            let converted = convertISBN10To13(compact)
            return ParsedPublicationIdentifier(
                kind: .isbn10,
                original: rawValue,
                normalized: compact,
                isValid: true,
                isbn13: converted,
                issn: nil
            )
        }

        if compact.count == 10 {
            return ParsedPublicationIdentifier(
                kind: .isbn10,
                original: rawValue,
                normalized: compact,
                isValid: false,
                isbn13: nil,
                issn: nil
            )
        }

        if compact.count == 13 {
            let valid = isValidEAN13(compact)
            let isISBN = compact.hasPrefix("978") || compact.hasPrefix("979")
            return ParsedPublicationIdentifier(
                kind: isISBN ? .isbn13 : .ean13,
                original: rawValue,
                normalized: compact,
                isValid: valid,
                isbn13: isISBN && valid ? compact : nil,
                issn: valid ? deriveISSN(from: compact) : nil
            )
        }

        if compact.count == 8, compact.allSatisfy(\.isNumber) {
            return ParsedPublicationIdentifier(
                kind: .upce,
                original: rawValue,
                normalized: compact,
                isValid: true,
                isbn13: nil,
                issn: nil
            )
        }

        return ParsedPublicationIdentifier(
            kind: .unknown,
            original: rawValue,
            normalized: rawValue.trimmingCharacters(in: .whitespacesAndNewlines),
            isValid: false,
            isbn13: nil,
            issn: nil
        )
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
