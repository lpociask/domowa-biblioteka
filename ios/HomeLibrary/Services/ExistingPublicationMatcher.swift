import Foundation

struct ExistingPublicationMatch {
    enum Kind: Equatable {
        case anotherCopy
        case possibleRepeatScan
    }

    let publication: Publication
    let copyCount: Int
    let copyCountAtCurrentLocation: Int
    let kind: Kind
}

enum ExistingPublicationMatcher {
    static func match(
        in items: [OwnedItem],
        type: PublicationType,
        isbn13: String,
        issn: String,
        ean: String,
        issueNumber: String,
        issueDate: String,
        locationPath: LocationPath = LocationPath()
    ) -> ExistingPublicationMatch? {
        let matchingItems: [OwnedItem]

        switch type {
        case .book:
            guard let requestedISBN = normalizedISBN(isbn13.isEmpty ? ean : isbn13) else {
                return nil
            }
            matchingItems = items.filter { item in
                guard let publication = item.publication else { return false }
                guard publication.publicationType == .book else { return false }
                return normalizedISBN(publication.isbn13.isEmpty ? publication.ean : publication.isbn13)
                    == requestedISBN
            }

        case .periodical:
            let requestedISSN = normalizedISSN(issn)
            let requestedIssue = issueNumber.trimmed
            let requestedDate = issueDate.trimmed

            // Sam ISSN (tak samo jak bazowy EAN-977) identyfikuje tytuł ciągły,
            // a nie konkretny numer. Do bezpiecznego scalenia potrzebujemy numeru
            // albo daty wydania.
            guard !requestedISSN.isEmpty,
                  !requestedIssue.isEmpty || !requestedDate.isEmpty else {
                return nil
            }

            matchingItems = items.filter { item in
                guard let publication = item.publication else { return false }
                guard publication.publicationType == .periodical,
                      normalizedISSN(publication.issn) == requestedISSN else {
                    return false
                }

                let existingIssue = publication.issueNumber.trimmed
                let existingDate = publication.issueDate.trimmed
                let issueMatches = !requestedIssue.isEmpty && !existingIssue.isEmpty &&
                    existingIssue.caseInsensitiveCompare(requestedIssue) == .orderedSame
                let dateMatches = !requestedDate.isEmpty && !existingDate.isEmpty &&
                    existingDate.caseInsensitiveCompare(requestedDate) == .orderedSame

                if !requestedIssue.isEmpty, !existingIssue.isEmpty, !issueMatches {
                    return false
                }
                if !requestedDate.isEmpty, !existingDate.isEmpty, !dateMatches {
                    return false
                }

                // Co najmniej jedno konkretne pole musi występować po obu stronach
                // i być zgodne. Sam brak konfliktu nie wystarcza do scalenia.
                return issueMatches || dateMatches
            }
        }

        guard let matchingPublication = matchingItems
            .compactMap(\.publication)
            .min(by: { $0.id.uuidString < $1.id.uuidString }) else {
            return nil
        }
        let copyCount = matchingItems.count
        let copyCountAtCurrentLocation: Int
        if locationPath.isEmpty {
            copyCountAtCurrentLocation = 0
        } else {
            copyCountAtCurrentLocation = matchingItems.reduce(into: 0) { count, item in
                if item.status == .owned,
                   LocationPath(item.locationPathText) == locationPath {
                    count += 1
                }
            }
        }

        return ExistingPublicationMatch(
            publication: matchingPublication,
            copyCount: copyCount,
            copyCountAtCurrentLocation: copyCountAtCurrentLocation,
            kind: copyCountAtCurrentLocation > 0 ? .possibleRepeatScan : .anotherCopy
        )
    }

    private static func normalizedISBN(_ value: String) -> String? {
        let parsed = PublicationIdentifierParser.parse(value)
        guard parsed.isValid,
              parsed.kind == .isbn10 || parsed.kind == .isbn13 else {
            return nil
        }
        return parsed.isbn13 ?? parsed.normalized
    }

    private static func normalizedISSN(_ value: String) -> String {
        value.uppercased().filter { $0.isNumber || $0 == "X" }
    }
}

private extension String {
    var trimmed: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
