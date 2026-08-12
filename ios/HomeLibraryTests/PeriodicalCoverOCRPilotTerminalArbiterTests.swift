import XCTest
@testable import HomeLibrary

final class PeriodicalCoverOCRPilotTerminalArbiterTests: XCTestCase {
    func testApplyWinsOverFollowingDisappearAndCancelCallbacks() {
        var arbiter = PeriodicalCoverOCRPilotTerminalArbiter()
        arbiter.observe(.processing)
        arbiter.observe(.suggestions)

        XCTAssertEqual(arbiter.finishApplied(), .suggestionApplied)
        XCTAssertNil(arbiter.finishDismissed())
        XCTAssertNil(arbiter.finishApplied())
        XCTAssertEqual(arbiter.terminalOutcome, .suggestionApplied)
    }

    func testClosingAfterSuggestionsRecordsOneRejection() {
        var arbiter = PeriodicalCoverOCRPilotTerminalArbiter()
        arbiter.observe(.suggestions)

        XCTAssertEqual(arbiter.finishDismissed(), .suggestionRejected)
        XCTAssertNil(arbiter.finishDismissed())
        XCTAssertEqual(arbiter.terminalOutcome, .suggestionRejected)
    }

    func testNoSuggestionFailureAndCancellationMapToClosedOutcomes() {
        var noSuggestion = PeriodicalCoverOCRPilotTerminalArbiter()
        noSuggestion.observe(.noSuggestion)
        XCTAssertEqual(noSuggestion.finishDismissed(), .noSuggestion)

        var failed = PeriodicalCoverOCRPilotTerminalArbiter()
        failed.observe(.failed)
        XCTAssertEqual(failed.finishDismissed(), .failed)

        var sourceCancelled = PeriodicalCoverOCRPilotTerminalArbiter()
        XCTAssertEqual(sourceCancelled.finishDismissed(), .cancelled)

        var processingCancelled = PeriodicalCoverOCRPilotTerminalArbiter()
        processingCancelled.observe(.processing)
        XCTAssertEqual(processingCancelled.finishDismissed(), .cancelled)
    }

    func testLatestRetryObservationDeterminesTerminalOutcome() {
        var arbiter = PeriodicalCoverOCRPilotTerminalArbiter()
        arbiter.observe(.failed)
        arbiter.observe(.source)
        arbiter.observe(.processing)
        arbiter.observe(.suggestions)

        XCTAssertEqual(arbiter.finishDismissed(), .suggestionRejected)
    }

    func testObservationsAfterTerminalCannotChangeRecordedOutcome() {
        var arbiter = PeriodicalCoverOCRPilotTerminalArbiter()
        XCTAssertEqual(arbiter.finishDismissed(), .cancelled)

        arbiter.observe(.suggestions)

        XCTAssertEqual(arbiter.observation, .source)
        XCTAssertEqual(arbiter.terminalOutcome, .cancelled)
        XCTAssertNil(arbiter.finishApplied())
    }
}
