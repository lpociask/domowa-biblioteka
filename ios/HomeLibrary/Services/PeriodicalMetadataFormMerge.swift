import Foundation

struct PeriodicalMetadataFormFields: Equatable, Sendable {
    var title: String
    var publisher: String
    var language: String
}

struct PeriodicalMetadataFormMergeResult: Equatable, Sendable {
    let fields: PeriodicalMetadataFormFields
    let didApplyMetadata: Bool
}

/// Applies series-level catalog data without overwriting a value that was
/// already known or edited while the asynchronous lookup was in flight.
enum PeriodicalMetadataFormMerge {
    static func merge(
        metadata: PeriodicalMetadata,
        baseline: PeriodicalMetadataFormFields,
        current: PeriodicalMetadataFormFields
    ) -> PeriodicalMetadataFormMergeResult {
        var result = current

        result.title = fillBlank(
            current: current.title,
            baseline: baseline.title,
            incoming: metadata.title
        )
        result.publisher = fillBlank(
            current: current.publisher,
            baseline: baseline.publisher,
            incoming: metadata.publisher
        )

        let baselineLanguage = clean(baseline.language)
        let canReplaceDefaultLanguage = baselineLanguage == "pl" &&
            clean(baseline.title).isEmpty &&
            clean(baseline.publisher).isEmpty
        if current.language == baseline.language,
           baselineLanguage.isEmpty || canReplaceDefaultLanguage,
           let incoming = metadata.language.map(clean),
           !incoming.isEmpty {
            result.language = incoming
        }

        return PeriodicalMetadataFormMergeResult(
            fields: result,
            didApplyMetadata: result != current
        )
    }

    private static func fillBlank(
        current: String,
        baseline: String,
        incoming: String?
    ) -> String {
        guard current == baseline,
              clean(baseline).isEmpty,
              let incoming = incoming.map(clean),
              !incoming.isEmpty else {
            return current
        }
        return incoming
    }

    private static func clean(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Keeps an asynchronous periodical lookup scoped to the form identity that
/// started it. In particular, changing the form to a book invalidates a late
/// periodical response, while the automatic switch caused by a fresh EAN-977
/// scan keeps that new periodical lookup alive.
enum PeriodicalMetadataLookupGate {
    static func canFinish(
        requestedISSN: String,
        activeISSN: String?,
        currentISSN: String?,
        publicationType: PublicationType
    ) -> Bool {
        publicationType == .periodical &&
            activeISSN == requestedISSN &&
            currentISSN == requestedISSN
    }

    static func shouldResetLookup(
        activeISBN: String?,
        activeISSN: String?,
        publicationType: PublicationType
    ) -> Bool {
        switch publicationType {
        case .book:
            activeISSN != nil
        case .periodical:
            activeISBN != nil
        }
    }
}
