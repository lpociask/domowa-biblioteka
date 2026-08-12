import Foundation

/// Coarse result volume retained only for state-machine decisions. Exact
/// counts and search queries never enter pilot state or metrics.
enum PilotSearchResultCountBucket: Equatable, Sendable {
    case none
    case one
    case twoToFive
    case sixToTwenty
    case moreThanTwenty

    init(resultCount: Int) {
        switch max(0, resultCount) {
        case 0: self = .none
        case 1: self = .one
        case 2...5: self = .twoToFive
        case 6...20: self = .sixToTwenty
        default: self = .moreThanTwenty
        }
    }

    var hasResults: Bool { self != .none }
}

/// Privacy-safe state machine for one search interaction at a time.
///
/// The tracker sees only empty/non-empty transitions and a coarse result-count
/// bucket. It has no API capable of accepting or retaining the query itself.
struct PilotSearchTracker: Sendable {
    private(set) var isSessionActive = false
    private(set) var latestResultCountBucket: PilotSearchResultCountBucket?
    private(set) var terminalOutcome: PilotSearchOutcome?

    private var lastKnownWasEmpty = true
    private var hasSubmitted = false

    /// Starts a session only on an empty-to-non-empty transition. Clearing the
    /// search closes the current session and prepares the tracker for another.
    @discardableResult
    mutating func searchTextChanged(isEmpty: Bool) -> PilotSearchMetric? {
        if isEmpty {
            let metric = finishForAbandonment()
            resetState(lastKnownWasEmpty: true)
            return metric
        }

        if lastKnownWasEmpty, terminalOutcome == nil, !isSessionActive {
            isSessionActive = true
            hasSubmitted = false
            latestResultCountBucket = nil
        }
        lastKnownWasEmpty = false
        return nil
    }

    /// Zero results terminate immediately. A positive bucket stays pending so
    /// opening a result can still become the session's single terminal event.
    @discardableResult
    mutating func submit(resultCount: Int) -> PilotSearchMetric? {
        guard isSessionActive, terminalOutcome == nil else { return nil }

        let bucket = PilotSearchResultCountBucket(resultCount: resultCount)
        latestResultCountBucket = bucket
        hasSubmitted = true
        guard bucket.hasResults else {
            return finish(.noResults)
        }
        return nil
    }

    @discardableResult
    mutating func openResult() -> PilotSearchMetric? {
        guard isSessionActive, terminalOutcome == nil else { return nil }
        return finish(.resultOpened)
    }

    /// Backgrounding closes an unfinished interaction. The virtual empty
    /// boundary lets the next foreground non-empty notification start a fresh
    /// session without retaining the previous query state.
    @discardableResult
    mutating func background() -> PilotSearchMetric? {
        finishAndReset()
    }

    /// Disappearance has the same terminal semantics as backgrounding.
    @discardableResult
    mutating func disappear() -> PilotSearchMetric? {
        finishAndReset()
    }

    /// Explicitly prepares a completed or idle tracker for a later session.
    /// An active session must be closed through clear/background/disappear so
    /// it cannot be silently discarded without a terminal metric.
    @discardableResult
    mutating func resetForNextSession() -> Bool {
        guard !isSessionActive else { return false }
        resetState(lastKnownWasEmpty: true)
        return true
    }

    private mutating func finishForAbandonment() -> PilotSearchMetric? {
        guard isSessionActive, terminalOutcome == nil else { return nil }
        return finish(hasSubmitted ? .resultsNotOpened : .cancelled)
    }

    private mutating func finishAndReset() -> PilotSearchMetric? {
        let metric = finishForAbandonment()
        resetState(lastKnownWasEmpty: true)
        return metric
    }

    private mutating func finish(_ outcome: PilotSearchOutcome) -> PilotSearchMetric? {
        guard isSessionActive, terminalOutcome == nil else { return nil }
        terminalOutcome = outcome
        isSessionActive = false
        return PilotSearchMetric(outcome: outcome)
    }

    private mutating func resetState(lastKnownWasEmpty: Bool) {
        isSessionActive = false
        latestResultCountBucket = nil
        terminalOutcome = nil
        hasSubmitted = false
        self.lastKnownWasEmpty = lastKnownWasEmpty
    }
}
