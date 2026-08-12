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
        barcode: String = "",
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
            let requestedComposite = PeriodicalCompositeIdentifier(
                ean: ean,
                barcode: barcode
            )
            let requestedMainEAN = normalizedPeriodicalEAN(ean: ean, barcode: barcode)
            let requestedISSN = normalizedISSN(issn)
            let requestedIssue = issueNumber.trimmed
            let requestedDate = issueDate.trimmed

            // Sam ISSN (tak samo jak bazowy EAN-977) identyfikuje tytuł ciągły,
            // a nie konkretny numer. Konkretny numer rozpoznajemy po pełnym
            // EAN-977 z dodatkiem EAN-2/EAN-5 albo po zgodnym numerze/dacie.
            let canUseBibliographicFallback = !requestedISSN.isEmpty &&
                (!requestedIssue.isEmpty || !requestedDate.isEmpty)
            guard requestedComposite != nil || canUseBibliographicFallback else {
                return nil
            }

            matchingItems = items.filter { item in
                guard let publication = item.publication else { return false }
                guard publication.publicationType == .periodical else {
                    return false
                }

                let existingComposite = PeriodicalCompositeIdentifier(
                    ean: publication.ean,
                    barcode: publication.barcode
                )
                let existingMainEAN = normalizedPeriodicalEAN(
                    ean: publication.ean,
                    barcode: publication.barcode
                )
                if let requestedMainEAN,
                   let existingMainEAN,
                   requestedMainEAN != existingMainEAN {
                    return false
                }

                let existingIssue = publication.issueNumber.trimmed
                let existingDate = publication.issueDate.trimmed
                let issueMatches = !requestedIssue.isEmpty && !existingIssue.isEmpty &&
                    existingIssue.caseInsensitiveCompare(requestedIssue) == .orderedSame
                let dateMatches = !requestedDate.isEmpty && !existingDate.isEmpty &&
                    existingDate.caseInsensitiveCompare(requestedDate) == .orderedSame

                // The add-on is a useful candidate signal, not permission to
                // erase explicit bibliographic disagreement. Publishers may
                // reuse EAN-2 values in another cycle.
                if !requestedIssue.isEmpty, !existingIssue.isEmpty, !issueMatches {
                    return false
                }
                if !requestedDate.isEmpty, !existingDate.isEmpty, !dateMatches {
                    return false
                }

                if let requestedComposite, let existingComposite {
                    // Dwa jawne, różne dodatki zawsze opisują różne numery,
                    // nawet gdy ręcznie wpisany numer albo data są takie same.
                    guard requestedComposite.supplement == existingComposite.supplement else {
                        return false
                    }
                    if requestedComposite == existingComposite {
                        return true
                    }
                }

                guard canUseBibliographicFallback,
                      normalizedISSN(publication.issn) == requestedISSN else {
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

    private static func normalizedPeriodicalEAN(ean: String, barcode: String) -> String? {
        for value in [ean, barcode] {
            let parsed = PublicationIdentifierParser.parse(value)
            let main = String(parsed.normalized.prefix(13))
            if parsed.isValid,
               parsed.kind == .ean13,
               main.hasPrefix("977"),
               PublicationIdentifierParser.isValidEAN13(main) {
                return main
            }
        }
        return nil
    }
}

/// Concrete issue identity encoded by a valid EAN-977 and its 2- or 5-digit
/// add-on. It is derived from the existing `ean` and `barcode` fields, so the
/// persistence and exchange formats do not need another stored property.
struct PeriodicalCompositeIdentifier: Equatable {
    let ean13: String
    let supplement: String

    var canonical: String { "\(ean13)+\(supplement)" }

    init?(ean: String, barcode: String) {
        let parsedBarcode = PublicationIdentifierParser.parse(barcode)
        guard parsedBarcode.isValid,
              let supplement = parsedBarcode.eanSupplement,
              (supplement.count == 2 || supplement.count == 5),
              supplement.allSatisfy(\.isNumber) else {
            return nil
        }

        let barcodeEAN = String(parsedBarcode.normalized.prefix(13))
        guard barcodeEAN.count == 13,
              barcodeEAN.hasPrefix("977"),
              PublicationIdentifierParser.isValidEAN13(barcodeEAN) else {
            return nil
        }

        if !ean.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let parsedEAN = PublicationIdentifierParser.parse(ean)
            let explicitEAN = String(parsedEAN.normalized.prefix(13))
            guard parsedEAN.isValid,
                  explicitEAN == barcodeEAN else {
                return nil
            }
        }

        self.ean13 = barcodeEAN
        self.supplement = supplement
    }
}

private extension String {
    var trimmed: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
