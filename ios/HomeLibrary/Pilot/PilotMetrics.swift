import Foundation

/// Privacy-safe measurements collected only after an explicit pilot opt-in.
///
/// Every payload is deliberately closed: it contains only bounded numbers,
/// booleans and enums. There is no escape hatch for titles, identifiers,
/// locations, notes, UUIDs, images or other user-provided strings.
enum PilotMetricEvent: Codable, Equatable, Sendable {
    case catalog(PilotCatalogMetric)
    case lookup(PilotLookupMetric)
    case location(PilotLocationMetric)
    case ocr(PilotOCRMetric)
    case search(PilotSearchMetric)
    case mutation(PilotMutationMetric)
    case transfer(PilotTransferMetric)
}

enum PilotPublicationKind: String, Codable, CaseIterable, Sendable {
    case book
    case periodical
}

enum PilotCatalogOutcome: String, Codable, CaseIterable, Sendable {
    case completed
    case cancelled
}

struct PilotCatalogMetric: Codable, Equatable, Sendable {
    let publicationKind: PilotPublicationKind
    let outcome: PilotCatalogOutcome
    /// Foreground interaction time. UInt32 bounds a single sample to about 49 days.
    let activeMilliseconds: UInt32
    /// Time from a successful scan/OCR/lookup result until save, when applicable.
    let recognitionToSaveMilliseconds: UInt32?
    /// Number of fields manually corrected during this cataloging attempt.
    let manualCorrectionCount: UInt16
    /// True only when automation actually filled at least one tracked field.
    /// This keeps manual-only entries out of the correction-rate denominator.
    let hadAutomaticFieldFill: Bool

    init(
        publicationKind: PilotPublicationKind,
        outcome: PilotCatalogOutcome,
        activeMilliseconds: UInt32,
        recognitionToSaveMilliseconds: UInt32? = nil,
        manualCorrectionCount: UInt16 = 0,
        hadAutomaticFieldFill: Bool = false
    ) {
        self.publicationKind = publicationKind
        self.outcome = outcome
        self.activeMilliseconds = activeMilliseconds
        self.recognitionToSaveMilliseconds = recognitionToSaveMilliseconds
        self.manualCorrectionCount = manualCorrectionCount
        self.hadAutomaticFieldFill = hadAutomaticFieldFill
    }
}

enum PilotLookupSource: String, Codable, CaseIterable, Sendable {
    case nationalLibrary
    case openLibrary
    case metadataCache
}

enum PilotLookupOutcome: String, Codable, CaseIterable, Sendable {
    case found
    case notFound
    /// No usable cache entry existed. Only the metadata cache emits this outcome.
    case miss
    /// A stale positive cache entry existed but was not needed as a fallback.
    case stale
    /// Upstream failed and a still-valid stale positive entry was returned.
    case staleFallback
    case failed
    case cancelled
}

struct PilotLookupMetric: Codable, Equatable, Sendable {
    let source: PilotLookupSource
    let outcome: PilotLookupOutcome

    init(source: PilotLookupSource, outcome: PilotLookupOutcome) {
        self.source = source
        self.outcome = outcome
    }
}

enum PilotLocationOutcome: String, Codable, CaseIterable, Sendable {
    case freshSelection
    case reusedPrevious
    case changed
    case none
}

struct PilotLocationMetric: Codable, Equatable, Sendable {
    let outcome: PilotLocationOutcome

    init(outcome: PilotLocationOutcome) {
        self.outcome = outcome
    }
}

enum PilotOCROutcome: String, Codable, CaseIterable, Sendable {
    case suggestionApplied
    case suggestionRejected
    case noSuggestion
    case failed
    case cancelled
}

struct PilotOCRMetric: Codable, Equatable, Sendable {
    let outcome: PilotOCROutcome

    init(outcome: PilotOCROutcome) {
        self.outcome = outcome
    }
}

enum PilotSearchOutcome: String, Codable, CaseIterable, Sendable {
    case resultOpened
    case resultsNotOpened
    case noResults
    case cancelled
}

struct PilotSearchMetric: Codable, Equatable, Sendable {
    let outcome: PilotSearchOutcome

    init(outcome: PilotSearchOutcome) {
        self.outcome = outcome
    }
}

enum PilotMutationAction: String, Codable, CaseIterable, Sendable {
    case edit
    case move
    case delete
    case undo
    case duplicatePrevented
    case duplicateOverride
}

enum PilotOperationOutcome: String, Codable, CaseIterable, Sendable {
    case completed
    case failed
    case cancelled
}

struct PilotMutationMetric: Codable, Equatable, Sendable {
    let action: PilotMutationAction
    let outcome: PilotOperationOutcome

    init(action: PilotMutationAction, outcome: PilotOperationOutcome) {
        self.action = action
        self.outcome = outcome
    }
}

enum PilotTransferDirection: String, Codable, CaseIterable, Sendable {
    case export
    case `import`
    case roundTrip
}

enum PilotTransferOutcome: String, Codable, CaseIterable, Sendable {
    /// A regular import/export completed; it was not a round-trip verification.
    case completed
    case verified
    case mismatch
    case failed
    case cancelled
}

struct PilotTransferMetric: Codable, Equatable, Sendable {
    let direction: PilotTransferDirection
    let outcome: PilotTransferOutcome

    init(direction: PilotTransferDirection, outcome: PilotTransferOutcome) {
        self.direction = direction
        self.outcome = outcome
    }
}

/// A persisted record intentionally identifies only ordering and relative day.
/// It never contains a per-event wall-clock timestamp.
struct PilotMetricRecord: Codable, Equatable, Sendable {
    let sequence: UInt64
    let dayIndex: UInt32
    let event: PilotMetricEvent
}

enum PilotAggregateExportFormat: Sendable {
    case json
    case csv
}

/// Non-throwing, privacy-safe bridge between catalog lookup providers and the
/// opt-in pilot store. The closure receives only a closed metric — never the
/// ISBN, response, error text or any bibliographic data.
struct BookMetadataLookupObserver: Sendable {
    private let handler: @Sendable (PilotLookupMetric) async -> Void

    init(handler: @escaping @Sendable (PilotLookupMetric) async -> Void) {
        self.handler = handler
    }

    func record(source: PilotLookupSource, outcome: PilotLookupOutcome) async {
        await handler(PilotLookupMetric(source: source, outcome: outcome))
    }

    static let disabled = Self { _ in }

    /// Makes lookup instrumentation write into the same serialized actor as all
    /// other pilot events. Store failures deliberately never alter lookup results.
    static func recording(in store: PilotMetricsStore) -> Self {
        Self { metric in
            _ = try? await store.record(.lookup(metric))
        }
    }
}
