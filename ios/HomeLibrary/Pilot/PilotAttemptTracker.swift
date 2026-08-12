import Foundation

/// Type-erased monotonic clock used by one cataloging attempt.
///
/// Production code uses `ContinuousClock`; tests can inject a deterministic
/// millisecond counter without relying on wall-clock time or sleeping.
struct PilotAttemptClock: Sendable {
    private let readMilliseconds: @Sendable () -> UInt64

    init(readMilliseconds: @escaping @Sendable () -> UInt64) {
        self.readMilliseconds = readMilliseconds
    }

    func nowMilliseconds() -> UInt64 {
        readMilliseconds()
    }

    static func continuous(_ clock: ContinuousClock = ContinuousClock()) -> Self {
        let origin = clock.now
        return Self {
            unsignedMilliseconds(origin.duration(to: clock.now))
        }
    }

    private static func unsignedMilliseconds(_ duration: Duration) -> UInt64 {
        let components = duration.components
        guard components.seconds >= 0 else { return 0 }

        let seconds = UInt64(components.seconds)
        guard seconds <= UInt64.max / 1_000 else { return UInt64.max }
        let wholeMilliseconds = seconds * 1_000
        let fractionalMilliseconds: UInt64
        if components.attoseconds > 0 {
            fractionalMilliseconds = UInt64(components.attoseconds) / 1_000_000_000_000_000
        } else {
            fractionalMilliseconds = 0
        }

        let (result, overflow) = wholeMilliseconds.addingReportingOverflow(
            fractionalMilliseconds
        )
        return overflow ? UInt64.max : result
    }
}

enum PilotAttemptState: Equatable, Sendable {
    case ready
    case running
    case paused
    case completed
    case cancelled
}

/// Ephemeral baselines for fields that were actually changed by automation.
///
/// The first automatic value wins. A later lookup that preserves a manual edit
/// cannot erase that correction by replacing its earlier baseline.
struct PilotAutofillCorrectionTracker<Field: Hashable & Sendable>: Sendable {
    private var baselines: [Field: String] = [:]

    /// Returns true only when this call records the field's first real automatic
    /// change. Unchanged fields and later automatic passes leave the baseline
    /// untouched.
    @discardableResult
    mutating func recordAutomaticChange(
        for field: Field,
        from previousValue: String,
        to automaticValue: String
    ) -> Bool {
        guard previousValue != automaticValue,
              baselines[field] == nil else {
            return false
        }
        baselines[field] = automaticValue
        return true
    }

    func correctionCount(currentValue: (Field) -> String) -> Int {
        baselines.reduce(into: 0) { count, entry in
            if currentValue(entry.key) != entry.value {
                count += 1
            }
        }
    }

    var hasAutomaticFieldFill: Bool { !baselines.isEmpty }
}

/// Pure state machine for privacy-safe timing of a single cataloging attempt.
/// It stores no titles, identifiers, locations, timestamps or free-form text.
struct PilotAttemptTracker: Sendable {
    let publicationKind: PilotPublicationKind
    private let clock: PilotAttemptClock

    private(set) var state: PilotAttemptState = .ready
    private(set) var result: PilotCatalogMetric?

    private var accumulatedActiveMilliseconds: UInt64 = 0
    private var activeSegmentStartedAt: UInt64?
    private var recognitionActiveMilliseconds: UInt64?

    init(
        publicationKind: PilotPublicationKind,
        clock: PilotAttemptClock = .continuous()
    ) {
        self.publicationKind = publicationKind
        self.clock = clock
    }

    @discardableResult
    mutating func start() -> Bool {
        guard state == .ready else { return false }
        activeSegmentStartedAt = clock.nowMilliseconds()
        state = .running
        return true
    }

    @discardableResult
    mutating func pause() -> Bool {
        guard state == .running else { return false }
        accumulateActiveTime(at: clock.nowMilliseconds())
        activeSegmentStartedAt = nil
        state = .paused
        return true
    }

    @discardableResult
    mutating func resume() -> Bool {
        guard state == .paused else { return false }
        activeSegmentStartedAt = clock.nowMilliseconds()
        state = .running
        return true
    }

    /// Marks the first successful scan, OCR or lookup result. Repeated marks
    /// are ignored so retries cannot silently move the measurement baseline.
    @discardableResult
    mutating func markRecognition() -> Bool {
        guard state == .running || state == .paused,
              recognitionActiveMilliseconds == nil else {
            return false
        }
        recognitionActiveMilliseconds = activeTime(at: clock.nowMilliseconds())
        return true
    }

    @discardableResult
    mutating func complete(
        publicationKind: PilotPublicationKind? = nil,
        manualCorrectionCount: Int = 0,
        hadAutomaticFieldFill: Bool = false
    ) -> PilotCatalogMetric? {
        finish(
            outcome: .completed,
            publicationKind: publicationKind,
            manualCorrectionCount: manualCorrectionCount,
            hadAutomaticFieldFill: hadAutomaticFieldFill
        )
    }

    @discardableResult
    mutating func cancel(
        publicationKind: PilotPublicationKind? = nil,
        manualCorrectionCount: Int = 0,
        hadAutomaticFieldFill: Bool = false
    ) -> PilotCatalogMetric? {
        finish(
            outcome: .cancelled,
            publicationKind: publicationKind,
            manualCorrectionCount: manualCorrectionCount,
            hadAutomaticFieldFill: hadAutomaticFieldFill
        )
    }

    private mutating func finish(
        outcome: PilotCatalogOutcome,
        publicationKind overridePublicationKind: PilotPublicationKind?,
        manualCorrectionCount: Int,
        hadAutomaticFieldFill: Bool
    ) -> PilotCatalogMetric? {
        if let result { return result }
        guard state == .running || state == .paused else { return nil }

        if state == .running {
            accumulateActiveTime(at: clock.nowMilliseconds())
            activeSegmentStartedAt = nil
        }

        let recognitionToSaveMilliseconds: UInt32?
        if outcome == .completed, let recognitionActiveMilliseconds {
            let elapsed = accumulatedActiveMilliseconds >= recognitionActiveMilliseconds
                ? accumulatedActiveMilliseconds - recognitionActiveMilliseconds
                : 0
            recognitionToSaveMilliseconds = UInt32(clamping: elapsed)
        } else {
            recognitionToSaveMilliseconds = nil
        }

        let metric = PilotCatalogMetric(
            publicationKind: overridePublicationKind ?? publicationKind,
            outcome: outcome,
            activeMilliseconds: UInt32(clamping: accumulatedActiveMilliseconds),
            recognitionToSaveMilliseconds: recognitionToSaveMilliseconds,
            manualCorrectionCount: UInt16(clamping: manualCorrectionCount),
            hadAutomaticFieldFill: hadAutomaticFieldFill
        )
        result = metric
        state = outcome == .completed ? .completed : .cancelled
        return metric
    }

    private func activeTime(at now: UInt64) -> UInt64 {
        guard let activeSegmentStartedAt else {
            return accumulatedActiveMilliseconds
        }
        return saturatingAdd(
            accumulatedActiveMilliseconds,
            nonnegativeElapsed(from: activeSegmentStartedAt, to: now)
        )
    }

    private mutating func accumulateActiveTime(at now: UInt64) {
        accumulatedActiveMilliseconds = activeTime(at: now)
    }

    private func nonnegativeElapsed(from start: UInt64, to end: UInt64) -> UInt64 {
        end >= start ? end - start : 0
    }

    private func saturatingAdd(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? UInt64.max : sum
    }
}
