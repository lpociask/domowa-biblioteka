import Foundation

struct PilotRate: Codable, Equatable, Sendable {
    let numerator: Int
    let denominator: Int
    let value: Double?

    init(numerator: Int, denominator: Int) {
        self.numerator = max(0, numerator)
        self.denominator = max(0, denominator)
        value = denominator > 0 ? Double(max(0, numerator)) / Double(denominator) : nil
    }
}
struct PilotDistribution: Codable, Equatable, Sendable {
    let sampleCount: Int
    let median: Double?
    let p90: Double?
}

struct PilotCatalogKindReport: Codable, Equatable, Sendable {
    let publicationKind: PilotPublicationKind
    let attempts: Int
    let completed: Int
    let cancelled: Int
    let activeMilliseconds: PilotDistribution
    let recognitionToSaveMilliseconds: PilotDistribution
}

struct PilotCorrectionReport: Codable, Equatable, Sendable {
    let completedItems: Int
    let correctedItems: Int
    let manualCorrections: Int
    let correctedItemRate: PilotRate
    let correctionsPerCompletedItem: PilotRate
}

struct PilotLookupSourceReport: Codable, Equatable, Sendable {
    let source: PilotLookupSource
    let attempts: Int
    let found: Int
    let notFound: Int
    let miss: Int
    let stale: Int
    let staleFallback: Int
    let failed: Int
    let cancelled: Int
    /// Denominator for definitive provider answers: found + notFound.
    let resolvedDenominator: Int
    /// Found divided by every attempt, including transport failures and cancellation.
    let foundRate: PilotRate
    /// Positive, negative or stale-fallback cache answers divided by cache attempts.
    /// It is intentionally 0/0 for BN and Open Library.
    let usableCacheRate: PilotRate
}

struct PilotLocationReport: Codable, Equatable, Sendable {
    let measurements: Int
    let freshSelections: Int
    let reusedPrevious: Int
    let changed: Int
    let none: Int
    let reuseRate: PilotRate
}

struct PilotOCRReport: Codable, Equatable, Sendable {
    let attempts: Int
    let suggestionApplied: Int
    let suggestionRejected: Int
    let noSuggestion: Int
    let failed: Int
    let cancelled: Int
    let appliedRate: PilotRate
}

struct PilotSearchReport: Codable, Equatable, Sendable {
    let sessions: Int
    let resultOpened: Int
    let resultsNotOpened: Int
    let noResults: Int
    let cancelled: Int
    let successfulOpenRate: PilotRate
}

struct PilotMutationActionReport: Codable, Equatable, Sendable {
    let action: PilotMutationAction
    let attempts: Int
    let completed: Int
    let failed: Int
    let cancelled: Int
    let completionRate: PilotRate
}

struct PilotTransferDirectionReport: Codable, Equatable, Sendable {
    let direction: PilotTransferDirection
    let attempts: Int
    let completed: Int
    let verified: Int
    let mismatch: Int
    let failed: Int
    let cancelled: Int
    let verificationDenominator: Int
    let verificationRate: PilotRate
}

/// Aggregate-only pilot report. It cannot reconstruct individual records.
struct PilotReport: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let retainedEventCount: Int
    let firstDayIndex: UInt32?
    let lastDayIndex: UInt32?
    let catalog: [PilotCatalogKindReport]
    let corrections: PilotCorrectionReport
    let lookups: [PilotLookupSourceReport]
    let location: PilotLocationReport
    let ocr: PilotOCRReport
    let search: PilotSearchReport
    let mutations: [PilotMutationActionReport]
    let transfers: [PilotTransferDirectionReport]
}

enum PilotReportBuilder {
    static func build(from records: [PilotMetricRecord]) -> PilotReport {
        let catalogMetrics = records.compactMap { record -> PilotCatalogMetric? in
            guard case .catalog(let metric) = record.event else { return nil }
            return metric
        }

        let catalog = PilotPublicationKind.allCases.map { kind in
            let attempts = catalogMetrics.filter { $0.publicationKind == kind }
            let completed = attempts.filter { $0.outcome == .completed }
            return PilotCatalogKindReport(
                publicationKind: kind,
                attempts: attempts.count,
                completed: completed.count,
                cancelled: attempts.count - completed.count,
                activeMilliseconds: distribution(
                    completed.map { Double($0.activeMilliseconds) }
                ),
                recognitionToSaveMilliseconds: distribution(
                    completed.compactMap(\.recognitionToSaveMilliseconds).map(Double.init)
                )
            )
        }

        // Correction quality is meaningful only for completed book attempts in
        // which automation filled a tracked field. Manual-only entries and
        // periodicals use different workflows and must not dilute this KPI.
        let correctionEligibleCatalog = catalogMetrics.filter {
            $0.outcome == .completed
                && $0.publicationKind == .book
                && $0.hadAutomaticFieldFill
        }
        let correctedItems = correctionEligibleCatalog.filter { $0.manualCorrectionCount > 0 }.count
        let manualCorrections = correctionEligibleCatalog.reduce(0) {
            $0 + Int($1.manualCorrectionCount)
        }
        let corrections = PilotCorrectionReport(
            completedItems: correctionEligibleCatalog.count,
            correctedItems: correctedItems,
            manualCorrections: manualCorrections,
            correctedItemRate: PilotRate(
                numerator: correctedItems,
                denominator: correctionEligibleCatalog.count
            ),
            correctionsPerCompletedItem: PilotRate(
                numerator: manualCorrections,
                denominator: correctionEligibleCatalog.count
            )
        )

        let lookupMetrics = records.compactMap { record -> PilotLookupMetric? in
            guard case .lookup(let metric) = record.event else { return nil }
            return metric
        }
        let lookups = PilotLookupSource.allCases.map { source in
            let attempts = lookupMetrics.filter { $0.source == source }
            let found = attempts.count { $0.outcome == .found }
            let notFound = attempts.count { $0.outcome == .notFound }
            let miss = attempts.count { $0.outcome == .miss }
            let stale = attempts.count { $0.outcome == .stale }
            let staleFallback = attempts.count { $0.outcome == .staleFallback }
            let failed = attempts.count { $0.outcome == .failed }
            let cancelled = attempts.count { $0.outcome == .cancelled }
            return PilotLookupSourceReport(
                source: source,
                attempts: attempts.count,
                found: found,
                notFound: notFound,
                miss: miss,
                stale: stale,
                staleFallback: staleFallback,
                failed: failed,
                cancelled: cancelled,
                resolvedDenominator: found + notFound,
                foundRate: PilotRate(numerator: found, denominator: attempts.count),
                usableCacheRate: PilotRate(
                    numerator: source == .metadataCache ? found + notFound + staleFallback : 0,
                    denominator: source == .metadataCache ? attempts.count : 0
                )
            )
        }

        let locationOutcomes = records.compactMap { record -> PilotLocationOutcome? in
            guard case .location(let metric) = record.event else { return nil }
            return metric.outcome
        }
        let freshSelections = locationOutcomes.count { $0 == .freshSelection }
        let reusedPrevious = locationOutcomes.count { $0 == .reusedPrevious }
        let changed = locationOutcomes.count { $0 == .changed }
        let noLocation = locationOutcomes.count { $0 == .none }
        let location = PilotLocationReport(
            measurements: locationOutcomes.count,
            freshSelections: freshSelections,
            reusedPrevious: reusedPrevious,
            changed: changed,
            none: noLocation,
            reuseRate: PilotRate(
                numerator: reusedPrevious,
                denominator: locationOutcomes.count
            )
        )

        let ocrOutcomes = records.compactMap { record -> PilotOCROutcome? in
            guard case .ocr(let metric) = record.event else { return nil }
            return metric.outcome
        }
        let appliedOCR = ocrOutcomes.count { $0 == .suggestionApplied }
        let ocr = PilotOCRReport(
            attempts: ocrOutcomes.count,
            suggestionApplied: appliedOCR,
            suggestionRejected: ocrOutcomes.count { $0 == .suggestionRejected },
            noSuggestion: ocrOutcomes.count { $0 == .noSuggestion },
            failed: ocrOutcomes.count { $0 == .failed },
            cancelled: ocrOutcomes.count { $0 == .cancelled },
            appliedRate: PilotRate(numerator: appliedOCR, denominator: ocrOutcomes.count)
        )

        let searchOutcomes = records.compactMap { record -> PilotSearchOutcome? in
            guard case .search(let metric) = record.event else { return nil }
            return metric.outcome
        }
        let resultOpened = searchOutcomes.count { $0 == .resultOpened }
        let search = PilotSearchReport(
            sessions: searchOutcomes.count,
            resultOpened: resultOpened,
            resultsNotOpened: searchOutcomes.count { $0 == .resultsNotOpened },
            noResults: searchOutcomes.count { $0 == .noResults },
            cancelled: searchOutcomes.count { $0 == .cancelled },
            successfulOpenRate: PilotRate(
                numerator: resultOpened,
                denominator: searchOutcomes.count
            )
        )

        let mutationMetrics = records.compactMap { record -> PilotMutationMetric? in
            guard case .mutation(let metric) = record.event else { return nil }
            return metric
        }
        let mutations = PilotMutationAction.allCases.map { action in
            let attempts = mutationMetrics.filter { $0.action == action }
            let completed = attempts.count { $0.outcome == .completed }
            return PilotMutationActionReport(
                action: action,
                attempts: attempts.count,
                completed: completed,
                failed: attempts.count { $0.outcome == .failed },
                cancelled: attempts.count { $0.outcome == .cancelled },
                completionRate: PilotRate(
                    numerator: completed,
                    denominator: attempts.count
                )
            )
        }

        let transferMetrics = records.compactMap { record -> PilotTransferMetric? in
            guard case .transfer(let metric) = record.event else { return nil }
            return metric
        }
        let transfers = PilotTransferDirection.allCases.map { direction in
            let attempts = transferMetrics.filter { $0.direction == direction }
            let completed = attempts.count { $0.outcome == .completed }
            let verified = attempts.count { $0.outcome == .verified }
            let mismatch = attempts.count { $0.outcome == .mismatch }
            return PilotTransferDirectionReport(
                direction: direction,
                attempts: attempts.count,
                completed: completed,
                verified: verified,
                mismatch: mismatch,
                failed: attempts.count { $0.outcome == .failed },
                cancelled: attempts.count { $0.outcome == .cancelled },
                verificationDenominator: verified + mismatch,
                verificationRate: PilotRate(
                    numerator: verified,
                    denominator: verified + mismatch
                )
            )
        }

        return PilotReport(
            schemaVersion: PilotReport.currentSchemaVersion,
            retainedEventCount: records.count,
            firstDayIndex: records.map(\.dayIndex).min(),
            lastDayIndex: records.map(\.dayIndex).max(),
            catalog: catalog,
            corrections: corrections,
            lookups: lookups,
            location: location,
            ocr: ocr,
            search: search,
            mutations: mutations,
            transfers: transfers
        )
    }

    static func jsonData(for report: PilotReport) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(report)
    }

    static func csvData(for report: PilotReport) -> Data {
        var rows = ["category,dimension,metric,value,denominator,rate"]

        for item in report.catalog {
            let dimension = item.publicationKind.rawValue
            append(&rows, "catalog", dimension, "attempts", item.attempts)
            append(&rows, "catalog", dimension, "completed", item.completed)
            append(&rows, "catalog", dimension, "cancelled", item.cancelled)
            append(&rows, "catalog", dimension, "active_sample_count", item.activeMilliseconds.sampleCount)
            append(&rows, "catalog", dimension, "active_median_ms", item.activeMilliseconds.median)
            append(&rows, "catalog", dimension, "active_p90_ms", item.activeMilliseconds.p90)
            append(&rows, "catalog", dimension, "recognition_sample_count", item.recognitionToSaveMilliseconds.sampleCount)
            append(&rows, "catalog", dimension, "recognition_median_ms", item.recognitionToSaveMilliseconds.median)
            append(&rows, "catalog", dimension, "recognition_p90_ms", item.recognitionToSaveMilliseconds.p90)
        }

        append(&rows, "corrections", "all", "completed_items", report.corrections.completedItems)
        append(&rows, "corrections", "all", "corrected_items", report.corrections.correctedItems)
        append(&rows, "corrections", "all", "manual_corrections", report.corrections.manualCorrections)
        append(&rows, "corrections", "all", "corrected_item_rate", report.corrections.correctedItemRate)
        append(&rows, "corrections", "all", "corrections_per_completed", report.corrections.correctionsPerCompletedItem)

        for item in report.lookups {
            let dimension = item.source.rawValue
            append(&rows, "lookup", dimension, "attempts", item.attempts)
            append(&rows, "lookup", dimension, "found", item.found)
            append(&rows, "lookup", dimension, "not_found", item.notFound)
            append(&rows, "lookup", dimension, "miss", item.miss)
            append(&rows, "lookup", dimension, "stale", item.stale)
            append(&rows, "lookup", dimension, "stale_fallback", item.staleFallback)
            append(&rows, "lookup", dimension, "failed", item.failed)
            append(&rows, "lookup", dimension, "cancelled", item.cancelled)
            append(&rows, "lookup", dimension, "resolved_denominator", item.resolvedDenominator)
            append(&rows, "lookup", dimension, "found_rate", item.foundRate)
            append(&rows, "lookup", dimension, "usable_cache_rate", item.usableCacheRate)
        }

        append(&rows, "location", "all", "measurements", report.location.measurements)
        append(&rows, "location", "all", "fresh_selection", report.location.freshSelections)
        append(&rows, "location", "all", "reused_previous", report.location.reusedPrevious)
        append(&rows, "location", "all", "changed", report.location.changed)
        append(&rows, "location", "all", "none", report.location.none)
        append(&rows, "location", "all", "reuse_rate", report.location.reuseRate)

        append(&rows, "ocr", "all", "attempts", report.ocr.attempts)
        append(&rows, "ocr", "all", "suggestion_applied", report.ocr.suggestionApplied)
        append(&rows, "ocr", "all", "suggestion_rejected", report.ocr.suggestionRejected)
        append(&rows, "ocr", "all", "no_suggestion", report.ocr.noSuggestion)
        append(&rows, "ocr", "all", "failed", report.ocr.failed)
        append(&rows, "ocr", "all", "cancelled", report.ocr.cancelled)
        append(&rows, "ocr", "all", "applied_rate", report.ocr.appliedRate)

        append(&rows, "search", "all", "sessions", report.search.sessions)
        append(&rows, "search", "all", "result_opened", report.search.resultOpened)
        append(&rows, "search", "all", "results_not_opened", report.search.resultsNotOpened)
        append(&rows, "search", "all", "no_results", report.search.noResults)
        append(&rows, "search", "all", "cancelled", report.search.cancelled)
        append(&rows, "search", "all", "successful_open_rate", report.search.successfulOpenRate)

        for item in report.mutations {
            let dimension = item.action.rawValue
            append(&rows, "mutation", dimension, "attempts", item.attempts)
            append(&rows, "mutation", dimension, "completed", item.completed)
            append(&rows, "mutation", dimension, "failed", item.failed)
            append(&rows, "mutation", dimension, "cancelled", item.cancelled)
            append(&rows, "mutation", dimension, "completion_rate", item.completionRate)
        }

        for item in report.transfers {
            let dimension = item.direction.rawValue
            append(&rows, "transfer", dimension, "attempts", item.attempts)
            append(&rows, "transfer", dimension, "completed", item.completed)
            append(&rows, "transfer", dimension, "verified", item.verified)
            append(&rows, "transfer", dimension, "mismatch", item.mismatch)
            append(&rows, "transfer", dimension, "failed", item.failed)
            append(&rows, "transfer", dimension, "cancelled", item.cancelled)
            append(&rows, "transfer", dimension, "verification_denominator", item.verificationDenominator)
            append(&rows, "transfer", dimension, "verification_rate", item.verificationRate)
        }

        return Data((rows.joined(separator: "\n") + "\n").utf8)
    }

    /// Linear interpolation between closest ranks (the common R-7 definition).
    static func quantile(_ values: [Double], probability: Double) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let p = min(1, max(0, probability))
        let position = Double(sorted.count - 1) * p
        let lowerIndex = Int(position.rounded(.down))
        let upperIndex = Int(position.rounded(.up))
        guard lowerIndex != upperIndex else { return sorted[lowerIndex] }
        let fraction = position - Double(lowerIndex)
        return sorted[lowerIndex] + ((sorted[upperIndex] - sorted[lowerIndex]) * fraction)
    }

    private static func distribution(_ values: [Double]) -> PilotDistribution {
        PilotDistribution(
            sampleCount: values.count,
            median: quantile(values, probability: 0.5),
            p90: quantile(values, probability: 0.9)
        )
    }

    private static func append(
        _ rows: inout [String],
        _ category: String,
        _ dimension: String,
        _ metric: String,
        _ value: Int
    ) {
        rows.append("\(category),\(dimension),\(metric),\(value),,")
    }

    private static func append(
        _ rows: inout [String],
        _ category: String,
        _ dimension: String,
        _ metric: String,
        _ value: Double?
    ) {
        rows.append("\(category),\(dimension),\(metric),\(format(value)),,")
    }

    private static func append(
        _ rows: inout [String],
        _ category: String,
        _ dimension: String,
        _ metric: String,
        _ rate: PilotRate
    ) {
        rows.append(
            "\(category),\(dimension),\(metric),\(rate.numerator),\(rate.denominator),\(format(rate.value))"
        )
    }

    private static func format(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "" }
        if value.rounded() == value {
            return String(Int64(value))
        }
        return String(format: "%.6f", locale: Locale(identifier: "en_US_POSIX"), value)
            .replacingOccurrences(of: #"0+$"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\.$"#, with: "", options: .regularExpression)
    }
}
