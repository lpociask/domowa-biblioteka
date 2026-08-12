import XCTest
@testable import HomeLibrary

final class PilotAttemptTrackerTests: XCTestCase {
    func testCompletedAttemptBuildsBookMetricAndRecognitionInterval() throws {
        let fakeClock = PilotAttemptFakeClock(100)
        var tracker = makeTracker(kind: .book, clock: fakeClock)

        XCTAssertTrue(tracker.start())
        fakeClock.set(1_200)
        XCTAssertTrue(tracker.markRecognition())
        fakeClock.set(2_500)

        let metric = try XCTUnwrap(tracker.complete(manualCorrectionCount: 3))

        XCTAssertEqual(
            metric,
            PilotCatalogMetric(
                publicationKind: .book,
                outcome: .completed,
                activeMilliseconds: 2_400,
                recognitionToSaveMilliseconds: 1_300,
                manualCorrectionCount: 3
            )
        )
        XCTAssertEqual(tracker.state, .completed)
        XCTAssertEqual(tracker.result, metric)
    }

    func testPausedTimeIsExcludedAndRepeatedPauseResumeAreIdempotent() throws {
        let fakeClock = PilotAttemptFakeClock(0)
        var tracker = makeTracker(kind: .periodical, clock: fakeClock)

        XCTAssertTrue(tracker.start())
        fakeClock.set(1_000)
        XCTAssertTrue(tracker.pause())
        XCTAssertFalse(tracker.pause())

        fakeClock.set(6_000)
        XCTAssertTrue(tracker.markRecognition())
        XCTAssertFalse(tracker.markRecognition())
        XCTAssertTrue(tracker.resume())
        XCTAssertFalse(tracker.resume())

        fakeClock.set(6_250)
        let metric = try XCTUnwrap(tracker.complete())

        XCTAssertEqual(metric.activeMilliseconds, 1_250)
        XCTAssertEqual(metric.recognitionToSaveMilliseconds, 250)
    }

    func testFirstRecognitionMarkerWins() throws {
        let fakeClock = PilotAttemptFakeClock(0)
        var tracker = makeTracker(kind: .book, clock: fakeClock)
        tracker.start()

        fakeClock.set(100)
        XCTAssertTrue(tracker.markRecognition())
        fakeClock.set(200)
        XCTAssertFalse(tracker.markRecognition())
        fakeClock.set(300)

        XCTAssertEqual(
            try XCTUnwrap(tracker.complete()).recognitionToSaveMilliseconds,
            200
        )
    }

    func testCancelledAttemptHasNoRecognitionToSaveInterval() throws {
        let fakeClock = PilotAttemptFakeClock(10)
        var tracker = makeTracker(kind: .periodical, clock: fakeClock)
        tracker.start()
        fakeClock.set(110)
        tracker.markRecognition()
        fakeClock.set(210)

        let metric = try XCTUnwrap(tracker.cancel(manualCorrectionCount: 2))

        XCTAssertEqual(metric.outcome, .cancelled)
        XCTAssertEqual(metric.activeMilliseconds, 200)
        XCTAssertNil(metric.recognitionToSaveMilliseconds)
        XCTAssertEqual(metric.manualCorrectionCount, 2)
        XCTAssertEqual(tracker.state, .cancelled)
    }

    func testTerminalOperationsAreIdempotent() throws {
        let fakeClock = PilotAttemptFakeClock(0)
        var tracker = makeTracker(kind: .book, clock: fakeClock)
        tracker.start()
        fakeClock.set(50)

        let completed = try XCTUnwrap(tracker.complete(manualCorrectionCount: 1))
        fakeClock.set(500)

        XCTAssertEqual(tracker.complete(manualCorrectionCount: 9), completed)
        XCTAssertEqual(tracker.cancel(manualCorrectionCount: 9), completed)
        XCTAssertFalse(tracker.start())
        XCTAssertFalse(tracker.pause())
        XCTAssertFalse(tracker.resume())
        XCTAssertFalse(tracker.markRecognition())
        XCTAssertEqual(tracker.state, .completed)
    }

    func testInvalidTransitionsBeforeStartDoNotCreateMetric() {
        let fakeClock = PilotAttemptFakeClock(0)
        var tracker = makeTracker(kind: .book, clock: fakeClock)

        XCTAssertFalse(tracker.pause())
        XCTAssertFalse(tracker.resume())
        XCTAssertFalse(tracker.markRecognition())
        XCTAssertNil(tracker.complete())
        XCTAssertNil(tracker.cancel())
        XCTAssertEqual(tracker.state, .ready)
    }

    func testLazySerialAttemptDoesNotEmitPhantomCancelBeforeInteraction() throws {
        let fakeClock = PilotAttemptFakeClock(0)
        var tracker = makeTracker(kind: .book, clock: fakeClock)

        XCTAssertNil(tracker.cancel())
        XCTAssertEqual(tracker.state, .ready)

        XCTAssertTrue(tracker.start())
        fakeClock.set(250)
        let metric = try XCTUnwrap(tracker.cancel())
        XCTAssertEqual(metric.outcome, .cancelled)
        XCTAssertEqual(metric.activeMilliseconds, 250)
    }

    func testClockRegressionNeverProducesNegativeDuration() throws {
        let fakeClock = PilotAttemptFakeClock(1_000)
        var tracker = makeTracker(kind: .book, clock: fakeClock)
        tracker.start()
        fakeClock.set(900)
        tracker.pause()
        fakeClock.set(800)
        tracker.resume()
        fakeClock.set(700)

        let metric = try XCTUnwrap(tracker.complete())

        XCTAssertEqual(metric.activeMilliseconds, 0)
    }

    func testDurationsAndCorrectionsClampWithoutOverflow() throws {
        let fakeClock = PilotAttemptFakeClock(0)
        var tracker = makeTracker(kind: .periodical, clock: fakeClock)
        tracker.start()
        fakeClock.set(UInt64.max)

        let metric = try XCTUnwrap(tracker.complete(manualCorrectionCount: Int.max))

        XCTAssertEqual(metric.activeMilliseconds, UInt32.max)
        XCTAssertEqual(metric.manualCorrectionCount, UInt16.max)
    }

    func testNegativeCorrectionCountClampsToZero() throws {
        let fakeClock = PilotAttemptFakeClock(0)
        var tracker = makeTracker(kind: .book, clock: fakeClock)
        tracker.start()

        let metric = try XCTUnwrap(tracker.complete(manualCorrectionCount: -10))

        XCTAssertEqual(metric.manualCorrectionCount, 0)
    }

    func testMultipleActiveSegmentsSaturateOnUInt64Overflow() throws {
        let fakeClock = PilotAttemptFakeClock(0)
        var tracker = makeTracker(kind: .book, clock: fakeClock)
        tracker.start()
        fakeClock.set(UInt64.max - 5)
        tracker.pause()

        fakeClock.set(0)
        tracker.resume()
        fakeClock.set(10)

        let metric = try XCTUnwrap(tracker.complete())

        XCTAssertEqual(metric.activeMilliseconds, UInt32.max)
    }

    func testAutofillCorrectionsTrackOnlyFieldsActuallyChangedByAutomation() {
        enum Field: Hashable, Sendable { case title, language }
        var tracker = PilotAutofillCorrectionTracker<Field>()

        XCTAssertTrue(tracker.recordAutomaticChange(for: .title, from: "", to: "Auto"))
        XCTAssertFalse(tracker.recordAutomaticChange(for: .language, from: "pl", to: "pl"))

        XCTAssertEqual(tracker.correctionCount { field in
            switch field {
            case .title: "Auto"
            case .language: "en"
            }
        }, 0)
    }

    func testAutofillCorrectionBaselineCannotBeOverwrittenByLaterLookup() {
        enum Field: Hashable, Sendable { case title }
        var tracker = PilotAutofillCorrectionTracker<Field>()

        XCTAssertTrue(tracker.recordAutomaticChange(for: .title, from: "", to: "Auto pierwsze"))
        XCTAssertFalse(tracker.recordAutomaticChange(
            for: .title,
            from: "Ręczna korekta",
            to: "Auto drugie"
        ))

        XCTAssertEqual(tracker.correctionCount { _ in "Ręczna korekta" }, 1)
    }

    func testManualEditPreservedDuringAwaitDoesNotBecomeAnAutofill() {
        enum Field: Hashable, Sendable { case title }
        var tracker = PilotAutofillCorrectionTracker<Field>()

        // The apply guard preserved the user's edit, so before and after the
        // automatic pass are equal and the field was never auto-filled.
        XCTAssertFalse(tracker.recordAutomaticChange(
            for: .title,
            from: "Ręczna wartość",
            to: "Ręczna wartość"
        ))
        XCTAssertEqual(tracker.correctionCount { _ in "Inna ręczna wartość" }, 0)
    }

    private func makeTracker(
        kind: PilotPublicationKind,
        clock: PilotAttemptFakeClock
    ) -> PilotAttemptTracker {
        PilotAttemptTracker(
            publicationKind: kind,
            clock: PilotAttemptClock(readMilliseconds: { clock.now() })
        )
    }
}

private final class PilotAttemptFakeClock: @unchecked Sendable {
    private var value: UInt64

    init(_ value: UInt64) {
        self.value = value
    }

    func now() -> UInt64 {
        value
    }

    func set(_ value: UInt64) {
        self.value = value
    }
}
