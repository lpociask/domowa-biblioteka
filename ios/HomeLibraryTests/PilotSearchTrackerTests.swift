import XCTest
@testable import HomeLibrary

final class PilotSearchTrackerTests: XCTestCase {
    func testStartsOnlyOnEmptyToNonemptyTransition() {
        var tracker = PilotSearchTracker()

        XCTAssertNil(tracker.searchTextChanged(isEmpty: true))
        XCTAssertFalse(tracker.isSessionActive)

        XCTAssertNil(tracker.searchTextChanged(isEmpty: false))
        XCTAssertTrue(tracker.isSessionActive)

        XCTAssertNil(tracker.searchTextChanged(isEmpty: false))
        XCTAssertTrue(tracker.isSessionActive)
    }

    func testZeroResultsTerminateAsNoResultsExactlyOnce() {
        var tracker = startedTracker()

        XCTAssertEqual(tracker.submit(resultCount: 0), PilotSearchMetric(outcome: .noResults))
        XCTAssertEqual(tracker.terminalOutcome, .noResults)
        XCTAssertFalse(tracker.isSessionActive)

        XCTAssertNil(tracker.submit(resultCount: 0))
        XCTAssertNil(tracker.openResult())
        XCTAssertNil(tracker.disappear())
    }

    func testNegativeResultCountIsSafelyBucketedAsNoResults() {
        var tracker = startedTracker()

        XCTAssertEqual(tracker.submit(resultCount: -100)?.outcome, .noResults)
    }

    func testPositiveSubmitStaysPendingUntilResultIsOpened() {
        var tracker = startedTracker()

        XCTAssertNil(tracker.submit(resultCount: 4))
        XCTAssertEqual(tracker.latestResultCountBucket, .twoToFive)
        XCTAssertTrue(tracker.isSessionActive)

        XCTAssertEqual(tracker.openResult(), PilotSearchMetric(outcome: .resultOpened))
        XCTAssertNil(tracker.openResult())
        XCTAssertNil(tracker.disappear())
    }

    func testClearAfterPositiveResultsTerminatesAsResultsNotOpenedAndResets() {
        var tracker = startedTracker()
        tracker.submit(resultCount: 21)

        XCTAssertEqual(
            tracker.searchTextChanged(isEmpty: true),
            PilotSearchMetric(outcome: .resultsNotOpened)
        )
        XCTAssertFalse(tracker.isSessionActive)
        XCTAssertNil(tracker.terminalOutcome)
        XCTAssertNil(tracker.latestResultCountBucket)

        XCTAssertNil(tracker.searchTextChanged(isEmpty: false))
        XCTAssertTrue(tracker.isSessionActive)
    }

    func testClearBeforeSubmitTerminatesAsCancelled() {
        var tracker = startedTracker()

        XCTAssertEqual(
            tracker.searchTextChanged(isEmpty: true),
            PilotSearchMetric(outcome: .cancelled)
        )
    }

    func testBackgroundAndDisappearUsePendingSessionSemantics() {
        var unsubmitted = startedTracker()
        XCTAssertEqual(unsubmitted.background()?.outcome, .cancelled)
        XCTAssertNil(unsubmitted.disappear())

        var submitted = startedTracker()
        submitted.submit(resultCount: 1)
        XCTAssertEqual(submitted.disappear()?.outcome, .resultsNotOpened)
        XCTAssertNil(submitted.background())
    }

    func testBackgroundResetAllowsFreshNonemptySession() {
        var tracker = startedTracker()
        tracker.submit(resultCount: 7)
        XCTAssertEqual(tracker.background()?.outcome, .resultsNotOpened)

        XCTAssertNil(tracker.searchTextChanged(isEmpty: false))
        XCTAssertTrue(tracker.isSessionActive)
        XCTAssertNil(tracker.submit(resultCount: 2))
        XCTAssertEqual(tracker.openResult()?.outcome, .resultOpened)
    }

    func testExplicitResetRejectsActiveSessionAndClearsTerminalSession() {
        var tracker = startedTracker()
        XCTAssertFalse(tracker.resetForNextSession())

        tracker.openResult()
        XCTAssertEqual(tracker.terminalOutcome, .resultOpened)
        XCTAssertTrue(tracker.resetForNextSession())
        XCTAssertNil(tracker.terminalOutcome)
        XCTAssertNil(tracker.latestResultCountBucket)
    }

    func testResultCountBucketsDoNotRetainExactCounts() {
        XCTAssertEqual(PilotSearchResultCountBucket(resultCount: 0), .none)
        XCTAssertEqual(PilotSearchResultCountBucket(resultCount: 1), .one)
        XCTAssertEqual(PilotSearchResultCountBucket(resultCount: 2), .twoToFive)
        XCTAssertEqual(PilotSearchResultCountBucket(resultCount: 5), .twoToFive)
        XCTAssertEqual(PilotSearchResultCountBucket(resultCount: 6), .sixToTwenty)
        XCTAssertEqual(PilotSearchResultCountBucket(resultCount: 20), .sixToTwenty)
        XCTAssertEqual(PilotSearchResultCountBucket(resultCount: 21), .moreThanTwenty)
        XCTAssertEqual(PilotSearchResultCountBucket(resultCount: Int.max), .moreThanTwenty)
    }

    private func startedTracker() -> PilotSearchTracker {
        var tracker = PilotSearchTracker()
        tracker.searchTextChanged(isEmpty: false)
        return tracker
    }
}
