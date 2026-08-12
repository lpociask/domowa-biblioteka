import Foundation
import XCTest
@testable import HomeLibrary

final class PilotMetricsCoreTests: XCTestCase {
    private var temporaryDirectories: [URL] = []

    override func tearDownWithError() throws {
        for directory in temporaryDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        temporaryDirectories = []
        try super.tearDownWithError()
    }

    func testDisabledStoreIsNoOpAndDoesNotTouchDisk() async throws {
        let directory = try makeTemporaryDirectory().appendingPathComponent("Pilot")
        let store = PilotMetricsStore(directoryURL: directory)

        let recorded = try await store.record(
            .search(PilotSearchMetric(outcome: .resultOpened))
        )
        let status = await store.status()

        XCTAssertFalse(recorded)
        XCTAssertFalse(status.enabled)
        XCTAssertEqual(status.retainedEventCount, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    func testEnableReloadDisableAndResetAreIdempotent() async throws {
        let directory = try makeTemporaryDirectory().appendingPathComponent("Pilot")
        let clock = PilotTestDayClock(20_000)
        let store = makeStore(directory: directory, clock: clock)

        let firstEnable = try await store.setEnabled(true)
        let secondEnable = try await store.setEnabled(true)
        XCTAssertTrue(firstEnable)
        XCTAssertFalse(secondEnable)
        let directoryValues = try directory.resourceValues(forKeys: [.isExcludedFromBackupKey])
        let fileValues = try stateURL(in: directory).resourceValues(
            forKeys: [.isExcludedFromBackupKey]
        )
        XCTAssertEqual(directoryValues.isExcludedFromBackup, true)
        XCTAssertEqual(fileValues.isExcludedFromBackup, true)

        _ = try await store.record(
            .catalog(
                PilotCatalogMetric(
                    publicationKind: .book,
                    outcome: .completed,
                    activeMilliseconds: 1_200
                )
            )
        )

        let reloaded = makeStore(directory: directory, clock: clock)
        let reloadedStatus = await reloaded.status()
        XCTAssertTrue(reloadedStatus.enabled)
        XCTAssertEqual(reloadedStatus.retainedEventCount, 1)

        try await reloaded.reset()
        let firstResetData = try Data(contentsOf: stateURL(in: directory))
        try await reloaded.reset()
        let secondResetData = try Data(contentsOf: stateURL(in: directory))
        let resetStatus = await reloaded.status()
        XCTAssertEqual(firstResetData, secondResetData)
        XCTAssertTrue(resetStatus.enabled)
        XCTAssertEqual(resetStatus.retainedEventCount, 0)
        XCTAssertNil(resetStatus.lastSequence)

        let firstDisable = try await reloaded.setEnabled(false)
        let secondDisable = try await reloaded.setEnabled(false)
        XCTAssertTrue(firstDisable)
        XCTAssertFalse(secondDisable)
        try await reloaded.reset()
        try await reloaded.reset()
        XCTAssertFalse(FileManager.default.fileExists(atPath: stateURL(in: directory).path))
    }

    func testRecordsUseSequenceAndRelativeDayWithoutPerEventTimestamps() async throws {
        let directory = try makeTemporaryDirectory().appendingPathComponent("Pilot")
        let clock = PilotTestDayClock(21_000)
        let store = makeStore(directory: directory, clock: clock)
        try await store.setEnabled(true)

        _ = try await store.record(.location(PilotLocationMetric(outcome: .freshSelection)))
        clock.advance(days: 2)
        _ = try await store.record(.location(PilotLocationMetric(outcome: .reusedPrevious)))

        let data = try Data(contentsOf: stateURL(in: directory))
        let root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let records = try XCTUnwrap(root["records"] as? [[String: Any]])
        XCTAssertEqual(records.count, 2)
        XCTAssertEqual((records[0]["sequence"] as? NSNumber)?.uint64Value, 1)
        XCTAssertEqual((records[0]["dayIndex"] as? NSNumber)?.uint32Value, 0)
        XCTAssertEqual((records[1]["sequence"] as? NSNumber)?.uint64Value, 2)
        XCTAssertEqual((records[1]["dayIndex"] as? NSNumber)?.uint32Value, 2)

        let eventKeys = records.flatMap { recursiveKeys(in: $0["event"] as Any) }
        XCTAssertFalse(eventKeys.contains { key in
            ["timestamp", "date", "createdat", "updatedat"].contains(key.lowercased())
        })

        let report = await store.report()
        XCTAssertEqual(report.firstDayIndex, 0)
        XCTAssertEqual(report.lastDayIndex, 2)
    }

    func testClockRollbackNeverMakesDayIndexDecrease() async throws {
        let directory = try makeTemporaryDirectory().appendingPathComponent("Pilot")
        let clock = PilotTestDayClock(30_000)
        let store = makeStore(directory: directory, clock: clock)
        try await store.setEnabled(true)
        clock.advance(days: 4)
        _ = try await store.record(.search(PilotSearchMetric(outcome: .noResults)))
        clock.advance(days: -3)
        _ = try await store.record(.search(PilotSearchMetric(outcome: .resultOpened)))

        let data = try Data(contentsOf: stateURL(in: directory))
        let root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let records = try XCTUnwrap(root["records"] as? [[String: Any]])
        XCTAssertEqual((records[0]["dayIndex"] as? NSNumber)?.uint32Value, 4)
        XCTAssertEqual((records[1]["dayIndex"] as? NSNumber)?.uint32Value, 4)
    }

    func testCorruptFileIsQuarantinedAndResetClearsQuarantine() async throws {
        let directory = try makeTemporaryDirectory().appendingPathComponent("Pilot")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        try Data("not-json".utf8).write(to: stateURL(in: directory), options: .atomic)

        let store = PilotMetricsStore(directoryURL: directory)
        var status = await store.status()
        XCTAssertFalse(status.enabled)
        XCTAssertEqual(status.retainedEventCount, 0)
        XCTAssertTrue(status.hasQuarantinedFile)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stateURL(in: directory).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: quarantineURL(in: directory).path))

        try await store.clearQuarantine()
        status = await store.status()
        XCTAssertFalse(status.hasQuarantinedFile)
        try await store.clearQuarantine()
    }

    func testOversizedFileIsQuarantinedBeforeDecode() async throws {
        let directory = try makeTemporaryDirectory().appendingPathComponent("Pilot")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(repeating: 0x7B, count: 513)
            .write(to: stateURL(in: directory), options: .atomic)

        let store = PilotMetricsStore(
            directoryURL: directory,
            maximumByteCount: 512
        )
        let status = await store.status()

        XCTAssertFalse(status.enabled)
        XCTAssertTrue(status.hasQuarantinedFile)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stateURL(in: directory).path))
    }

    func testEventCountLimitRetainsNewestRecordsAndSequenceContinues() async throws {
        let directory = try makeTemporaryDirectory().appendingPathComponent("Pilot")
        let store = PilotMetricsStore(
            directoryURL: directory,
            maximumEventCount: 3
        )
        try await store.setEnabled(true)

        for index in 0..<5 {
            let outcome: PilotSearchOutcome = index == 4 ? .resultOpened : .noResults
            _ = try await store.record(.search(PilotSearchMetric(outcome: outcome)))
        }

        let status = await store.status()
        let report = await store.report()
        XCTAssertEqual(status.retainedEventCount, 3)
        XCTAssertEqual(status.lastSequence, 5)
        XCTAssertEqual(report.retainedEventCount, 3)
        XCTAssertEqual(report.search.sessions, 3)
        XCTAssertEqual(report.search.resultOpened, 1)

        let reloaded = PilotMetricsStore(
            directoryURL: directory,
            maximumEventCount: 3
        )
        _ = try await reloaded.record(.search(PilotSearchMetric(outcome: .cancelled)))
        let reloadedStatus = await reloaded.status()
        XCTAssertEqual(reloadedStatus.retainedEventCount, 3)
        XCTAssertEqual(reloadedStatus.lastSequence, 6)
    }

    func testByteLimitPrunesOldestRecordsWithoutExceedingFileLimit() async throws {
        let directory = try makeTemporaryDirectory().appendingPathComponent("Pilot")
        let maximumBytes: Int64 = 640
        let store = PilotMetricsStore(
            directoryURL: directory,
            maximumEventCount: 100,
            maximumByteCount: maximumBytes
        )
        try await store.setEnabled(true)

        for _ in 0..<20 {
            _ = try await store.record(
                .catalog(
                    PilotCatalogMetric(
                        publicationKind: .periodical,
                        outcome: .completed,
                        activeMilliseconds: 42_000,
                        recognitionToSaveMilliseconds: 2_000,
                        manualCorrectionCount: 1
                    )
                )
            )
        }

        let attributes = try FileManager.default.attributesOfItem(
            atPath: stateURL(in: directory).path
        )
        let byteCount = try XCTUnwrap((attributes[.size] as? NSNumber)?.int64Value)
        let status = await store.status()
        XCTAssertLessThanOrEqual(byteCount, maximumBytes)
        XCTAssertGreaterThan(status.retainedEventCount, 0)
        XCTAssertLessThan(status.retainedEventCount, 20)
        XCTAssertEqual(status.lastSequence, 20)
    }

    func testTooSmallStorageLimitDoesNotEnableOrCreateFile() async throws {
        let directory = try makeTemporaryDirectory().appendingPathComponent("Pilot")
        let store = PilotMetricsStore(
            directoryURL: directory,
            maximumByteCount: 1
        )

        do {
            try await store.setEnabled(true)
            XCTFail("Limit mniejszy od dokumentu bazowego powinien zostać odrzucony.")
        } catch {
            XCTAssertEqual(error as? PilotMetricsStoreError, .storageLimitTooSmall)
        }

        let status = await store.status()
        XCTAssertFalse(status.enabled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stateURL(in: directory).path))
    }

    func testReportUsesCompletedSamplesForMedianP90AndCorrectionRates() throws {
        let records: [PilotMetricRecord] = [
            record(1, .catalog(catalog(.book, .completed, 100, recognition: 20, corrections: 0, autofilled: true))),
            record(2, .catalog(catalog(.book, .completed, 200, recognition: 40, corrections: 1, autofilled: true))),
            record(3, .catalog(catalog(.book, .completed, 300, recognition: 60, corrections: 2, autofilled: true))),
            record(4, .catalog(catalog(.book, .completed, 400, recognition: 80, corrections: 0, autofilled: true))),
            record(5, .catalog(catalog(.book, .cancelled, 9_999, recognition: 9_999, corrections: 99, autofilled: true))),
            record(6, .catalog(catalog(.periodical, .cancelled, 500))),
            record(7, .catalog(catalog(.book, .completed, 500, corrections: 0))),
            record(8, .catalog(catalog(.periodical, .completed, 600, corrections: 4, autofilled: true)))
        ]

        let report = PilotReportBuilder.build(from: records)
        let book = try XCTUnwrap(report.catalog.first { $0.publicationKind == .book })
        let periodical = try XCTUnwrap(report.catalog.first { $0.publicationKind == .periodical })

        XCTAssertEqual(book.attempts, 6)
        XCTAssertEqual(book.completed, 5)
        XCTAssertEqual(book.cancelled, 1)
        XCTAssertEqual(book.activeMilliseconds.sampleCount, 5)
        XCTAssertEqual(try XCTUnwrap(book.activeMilliseconds.median), 300, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(book.activeMilliseconds.p90), 460, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(book.recognitionToSaveMilliseconds.median), 50, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(book.recognitionToSaveMilliseconds.p90), 74, accuracy: 0.001)
        XCTAssertEqual(periodical.completed, 1)
        XCTAssertEqual(periodical.activeMilliseconds.median, 600)

        XCTAssertEqual(report.corrections.completedItems, 4)
        XCTAssertEqual(report.corrections.correctedItems, 2)
        XCTAssertEqual(report.corrections.manualCorrections, 3)
        XCTAssertEqual(report.corrections.correctedItemRate.denominator, 4)
        XCTAssertEqual(report.corrections.correctedItemRate.value, 0.5)
        XCTAssertEqual(report.corrections.correctionsPerCompletedItem.value, 0.75)
    }

    func testLookupReportsExplicitDenominatorsAndSafeZeroRates() throws {
        let records: [PilotMetricRecord] = [
            record(1, .lookup(PilotLookupMetric(source: .nationalLibrary, outcome: .found))),
            record(2, .lookup(PilotLookupMetric(source: .nationalLibrary, outcome: .notFound))),
            record(3, .lookup(PilotLookupMetric(source: .nationalLibrary, outcome: .failed))),
            record(4, .lookup(PilotLookupMetric(source: .nationalLibrary, outcome: .cancelled))),
            record(5, .lookup(PilotLookupMetric(source: .libraryOfCongress, outcome: .found))),
            record(6, .lookup(PilotLookupMetric(source: .issnPortal, outcome: .notFound))),
            record(7, .lookup(PilotLookupMetric(source: .metadataCache, outcome: .found))),
            record(8, .lookup(PilotLookupMetric(source: .metadataCache, outcome: .notFound))),
            record(9, .lookup(PilotLookupMetric(source: .metadataCache, outcome: .miss))),
            record(10, .lookup(PilotLookupMetric(source: .metadataCache, outcome: .stale))),
            record(11, .lookup(PilotLookupMetric(source: .metadataCache, outcome: .staleFallback)))
        ]

        let report = PilotReportBuilder.build(from: records)
        let nationalLibrary = try XCTUnwrap(
            report.lookups.first { $0.source == .nationalLibrary }
        )
        let openLibrary = try XCTUnwrap(
            report.lookups.first { $0.source == .openLibrary }
        )
        let libraryOfCongress = try XCTUnwrap(
            report.lookups.first { $0.source == .libraryOfCongress }
        )
        let issnPortal = try XCTUnwrap(
            report.lookups.first { $0.source == .issnPortal }
        )
        let cache = try XCTUnwrap(
            report.lookups.first { $0.source == .metadataCache }
        )

        XCTAssertEqual(nationalLibrary.attempts, 4)
        XCTAssertEqual(nationalLibrary.found, 1)
        XCTAssertEqual(nationalLibrary.notFound, 1)
        XCTAssertEqual(nationalLibrary.failed, 1)
        XCTAssertEqual(nationalLibrary.cancelled, 1)
        XCTAssertEqual(nationalLibrary.resolvedDenominator, 2)
        XCTAssertEqual(nationalLibrary.foundRate.numerator, 1)
        XCTAssertEqual(nationalLibrary.foundRate.denominator, 4)
        XCTAssertEqual(nationalLibrary.foundRate.value, 0.25)
        XCTAssertEqual(openLibrary.attempts, 0)
        XCTAssertEqual(openLibrary.foundRate.denominator, 0)
        XCTAssertNil(openLibrary.foundRate.value)
        XCTAssertEqual(libraryOfCongress.attempts, 1)
        XCTAssertEqual(libraryOfCongress.foundRate.value, 1)
        XCTAssertEqual(issnPortal.attempts, 1)
        XCTAssertEqual(issnPortal.notFound, 1)
        XCTAssertEqual(issnPortal.foundRate.value, 0)
        XCTAssertEqual(cache.attempts, 5)
        XCTAssertEqual(cache.found, 1)
        XCTAssertEqual(cache.notFound, 1)
        XCTAssertEqual(cache.miss, 1)
        XCTAssertEqual(cache.stale, 1)
        XCTAssertEqual(cache.staleFallback, 1)
        XCTAssertEqual(cache.foundRate.value, 0.2)
        XCTAssertEqual(cache.usableCacheRate.numerator, 3)
        XCTAssertEqual(cache.usableCacheRate.denominator, 5)
        XCTAssertEqual(cache.usableCacheRate.value, 0.6)
    }

    func testOperationalKPIsCoverLocationOCRSearchMutationsAndTransfers() throws {
        let records: [PilotMetricRecord] = [
            record(1, .location(PilotLocationMetric(outcome: .freshSelection))),
            record(2, .location(PilotLocationMetric(outcome: .reusedPrevious))),
            record(3, .location(PilotLocationMetric(outcome: .changed))),
            record(4, .location(PilotLocationMetric(outcome: .none))),
            record(5, .ocr(PilotOCRMetric(outcome: .suggestionApplied))),
            record(6, .ocr(PilotOCRMetric(outcome: .suggestionRejected))),
            record(7, .ocr(PilotOCRMetric(outcome: .noSuggestion))),
            record(8, .search(PilotSearchMetric(outcome: .resultOpened))),
            record(9, .search(PilotSearchMetric(outcome: .noResults))),
            record(10, .mutation(PilotMutationMetric(action: .move, outcome: .completed))),
            record(11, .mutation(PilotMutationMetric(action: .move, outcome: .failed))),
            record(12, .transfer(PilotTransferMetric(direction: .roundTrip, outcome: .verified))),
            record(13, .transfer(PilotTransferMetric(direction: .roundTrip, outcome: .mismatch))),
            record(14, .transfer(PilotTransferMetric(direction: .roundTrip, outcome: .completed))),
            record(15, .transfer(PilotTransferMetric(direction: .export, outcome: .completed))),
            record(16, .mutation(PilotMutationMetric(action: .delete, outcome: .completed)))
        ]

        let report = PilotReportBuilder.build(from: records)
        XCTAssertEqual(report.location.measurements, 4)
        XCTAssertEqual(report.location.reusedPrevious, 1)
        XCTAssertEqual(report.location.reuseRate.value, 0.25)
        XCTAssertEqual(report.ocr.attempts, 3)
        XCTAssertEqual(report.ocr.appliedRate.value, 1.0 / 3.0)
        XCTAssertEqual(report.search.sessions, 2)
        XCTAssertEqual(report.search.successfulOpenRate.value, 0.5)

        let move = try XCTUnwrap(report.mutations.first { $0.action == .move })
        XCTAssertEqual(move.attempts, 2)
        XCTAssertEqual(move.completed, 1)
        XCTAssertEqual(move.failed, 1)
        XCTAssertEqual(move.completionRate.value, 0.5)

        let delete = try XCTUnwrap(report.mutations.first { $0.action == .delete })
        XCTAssertEqual(delete.attempts, 1)
        XCTAssertEqual(delete.completed, 1)

        let roundTrip = try XCTUnwrap(
            report.transfers.first { $0.direction == .roundTrip }
        )
        XCTAssertEqual(roundTrip.attempts, 3)
        XCTAssertEqual(roundTrip.completed, 1)
        XCTAssertEqual(roundTrip.verified, 1)
        XCTAssertEqual(roundTrip.mismatch, 1)
        XCTAssertEqual(roundTrip.verificationDenominator, 2)
        XCTAssertEqual(roundTrip.verificationRate.value, 0.5)

        let export = try XCTUnwrap(report.transfers.first { $0.direction == .export })
        XCTAssertEqual(export.attempts, 1)
        XCTAssertEqual(export.completed, 1)
        XCTAssertEqual(export.verificationDenominator, 0)
        XCTAssertNil(export.verificationRate.value)
    }

    func testAggregateExportsContainNoRawRecordsOrPrivacySentinels() async throws {
        let directory = try makeTemporaryDirectory().appendingPathComponent("Pilot")
        let store = PilotMetricsStore(directoryURL: directory)
        try await store.setEnabled(true)

        let events: [PilotMetricEvent] = [
            .catalog(catalog(.book, .completed, 1_000, recognition: 300, corrections: 1)),
            .lookup(PilotLookupMetric(source: .nationalLibrary, outcome: .found)),
            .lookup(PilotLookupMetric(source: .openLibrary, outcome: .notFound)),
            .lookup(PilotLookupMetric(source: .metadataCache, outcome: .found)),
            .location(PilotLocationMetric(outcome: .reusedPrevious)),
            .ocr(PilotOCRMetric(outcome: .suggestionApplied)),
            .search(PilotSearchMetric(outcome: .resultOpened)),
            .mutation(PilotMutationMetric(action: .undo, outcome: .completed)),
            .transfer(PilotTransferMetric(direction: .roundTrip, outcome: .verified))
        ]
        for event in events {
            _ = try await store.record(event)
        }

        let rawStorage = try Data(contentsOf: stateURL(in: directory))
        let jsonExport = try await store.exportAggregates(.json)
        let csvExport = try await store.exportAggregates(.csv)
        let rawText = String(decoding: rawStorage, as: UTF8.self)
        let jsonText = String(decoding: jsonExport, as: UTF8.self)
        let csvText = String(decoding: csvExport, as: UTF8.self)
        let sentinels = [
            "9780306406157",
            "Tajny tytuł",
            "Gabinet / Regał 2 / Półka 3",
            "4E88FC04-410D-4A18-A076-FA6C05EF1C01",
            "private-cover.jpeg"
        ]
        for sentinel in sentinels {
            XCTAssertFalse(rawText.contains(sentinel))
            XCTAssertFalse(jsonText.contains(sentinel))
            XCTAssertFalse(csvText.contains(sentinel))
        }

        XCTAssertFalse(jsonText.contains("\"records\""))
        XCTAssertFalse(jsonText.contains("\"sequence\""))
        XCTAssertFalse(jsonText.contains("\"event\""))
        XCTAssertFalse(jsonText.contains("anchorDayOrdinal"))
        XCTAssertTrue(jsonText.contains("retainedEventCount"))
        XCTAssertTrue(csvText.hasPrefix("category,dimension,metric,value,denominator,rate\n"))
        XCTAssertFalse(csvText.contains("sequence"))

        let decodedReport = try JSONDecoder().decode(PilotReport.self, from: jsonExport)
        XCTAssertEqual(decodedReport.retainedEventCount, events.count)

        let rawObject = try JSONSerialization.jsonObject(with: rawStorage)
        let allowedEnumStrings = Set(
            PilotPublicationKind.allCases.map(\.rawValue)
            + PilotCatalogOutcome.allCases.map(\.rawValue)
            + PilotLookupSource.allCases.map(\.rawValue)
            + PilotLookupOutcome.allCases.map(\.rawValue)
            + PilotLocationOutcome.allCases.map(\.rawValue)
            + PilotOCROutcome.allCases.map(\.rawValue)
            + PilotSearchOutcome.allCases.map(\.rawValue)
            + PilotMutationAction.allCases.map(\.rawValue)
            + PilotOperationOutcome.allCases.map(\.rawValue)
            + PilotTransferDirection.allCases.map(\.rawValue)
            + PilotTransferOutcome.allCases.map(\.rawValue)
        )
        XCTAssertTrue(strings(in: rawObject).allSatisfy(allowedEnumStrings.contains))
    }

    func testQuantileHandlesEmptySingletonAndClampedProbability() {
        XCTAssertNil(PilotReportBuilder.quantile([], probability: 0.5))
        XCTAssertEqual(PilotReportBuilder.quantile([42], probability: 0.9), 42)
        XCTAssertEqual(PilotReportBuilder.quantile([10, 20], probability: -1), 10)
        XCTAssertEqual(PilotReportBuilder.quantile([10, 20], probability: 2), 20)
    }

    func testEveryClosedEventEncodingFitsExplicitPerEventBound() throws {
        let events: [PilotMetricEvent] = [
            .catalog(catalog(.periodical, .completed, .max, recognition: .max, corrections: .max)),
            .lookup(PilotLookupMetric(source: .openLibrary, outcome: .cancelled)),
            .location(PilotLocationMetric(outcome: .changed)),
            .ocr(PilotOCRMetric(outcome: .suggestionRejected)),
            .search(PilotSearchMetric(outcome: .resultsNotOpened)),
            .mutation(PilotMutationMetric(action: .duplicateOverride, outcome: .failed)),
            .transfer(PilotTransferMetric(direction: .roundTrip, outcome: .mismatch))
        ]
        let encoder = JSONEncoder()

        for event in events {
            XCTAssertLessThanOrEqual(
                try encoder.encode(event).count,
                PilotMetricsStore.maximumEventByteCount
            )
        }
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("PilotMetricsCoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        temporaryDirectories.append(url)
        return url
    }

    private func makeStore(
        directory: URL,
        clock: PilotTestDayClock
    ) -> PilotMetricsStore {
        PilotMetricsStore(
            directoryURL: directory,
            dayOrdinal: { clock.value }
        )
    }

    private func stateURL(in directory: URL) -> URL {
        directory.appendingPathComponent(PilotMetricsStore.stateFileName)
    }

    private func quarantineURL(in directory: URL) -> URL {
        directory.appendingPathComponent(PilotMetricsStore.quarantineFileName)
    }

    private func record(
        _ sequence: UInt64,
        dayIndex: UInt32 = 0,
        _ event: PilotMetricEvent
    ) -> PilotMetricRecord {
        PilotMetricRecord(sequence: sequence, dayIndex: dayIndex, event: event)
    }

    private func catalog(
        _ kind: PilotPublicationKind,
        _ outcome: PilotCatalogOutcome,
        _ activeMilliseconds: UInt32,
        recognition: UInt32? = nil,
        corrections: UInt16 = 0,
        autofilled: Bool = false
    ) -> PilotCatalogMetric {
        PilotCatalogMetric(
            publicationKind: kind,
            outcome: outcome,
            activeMilliseconds: activeMilliseconds,
            recognitionToSaveMilliseconds: recognition,
            manualCorrectionCount: corrections,
            hadAutomaticFieldFill: autofilled
        )
    }

    private func recursiveKeys(in value: Any) -> [String] {
        if let dictionary = value as? [String: Any] {
            return Array(dictionary.keys) + dictionary.values.flatMap(recursiveKeys)
        }
        if let array = value as? [Any] {
            return array.flatMap(recursiveKeys)
        }
        return []
    }

    private func strings(in value: Any) -> [String] {
        if let string = value as? String { return [string] }
        if let dictionary = value as? [String: Any] {
            return dictionary.values.flatMap(strings)
        }
        if let array = value as? [Any] {
            return array.flatMap(strings)
        }
        return []
    }
}

private final class PilotTestDayClock: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: Int

    init(_ value: Int) {
        storedValue = value
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedValue
    }

    func advance(days: Int) {
        lock.lock()
        storedValue += days
        lock.unlock()
    }
}
