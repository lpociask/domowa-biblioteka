import Foundation

struct ExistingPublicationMatch {
    let publication: Publication
    let copyCount: Int
}

enum ExistingPublicationMatcher {
    static func match(
        in items: [OwnedItem],
        type: PublicationType,
        isbn13: String,
        issn: String,
        ean: String,
        issueNumber: String,
        issueDate: String
    ) -> ExistingPublicationMatch? {
        let matchingPublication: Publication?

        switch type {
        case .book:
            guard let requestedISBN = normalizedISBN(isbn13.isEmpty ? ean : isbn13) else {
                return nil
            }
            matchingPublication = items.lazy.compactMap(\.publication).first { publication in
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

            matchingPublication = items.lazy.compactMap(\.publication).first { publication in
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

        guard let matchingPublication else { return nil }
        let copyCount = items.reduce(into: 0) { count, item in
            if item.publication?.id == matchingPublication.id {
                count += 1
            }
        }
        return ExistingPublicationMatch(
            publication: matchingPublication,
            copyCount: max(copyCount, 1)
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
