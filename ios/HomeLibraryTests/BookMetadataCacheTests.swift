import Foundation
import XCTest
@testable import HomeLibrary

final class BookMetadataCacheTests: XCTestCase {
    private var temporaryDirectories: [URL] = []

    override func tearDownWithError() throws {
        for directory in temporaryDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        temporaryDirectories = []
        try super.tearDownWithError()
    }

    func testFreshPositiveEntryPersistsAndSkipsUpstream() async throws {
        let directory = try makeTemporaryDirectory()
        let clock = TestClock(Self.referenceDate)
        let firstUpstream = QueueBookMetadataProvider([.success(Self.firstMetadata)])
        let firstProvider = CachedBookMetadataProvider(
            upstream: firstUpstream,
            cache: makeCache(directory: directory, clock: clock)
        )

        let firstResult = try await firstProvider.lookup(isbn: Self.isbnA)
        let firstCallCount = await firstUpstream.callCount
        XCTAssertEqual(firstResult, Self.firstMetadata)
        XCTAssertEqual(firstCallCount, 1)

        let secondUpstream = QueueBookMetadataProvider([.failure(.unavailable)])
        let secondProvider = CachedBookMetadataProvider(
            upstream: secondUpstream,
            cache: makeCache(directory: directory, clock: clock)
        )

        let secondResult = try await secondProvider.lookup(isbn: "0-306-40615-2")
        let secondCallCount = await secondUpstream.callCount
        XCTAssertEqual(secondResult, Self.firstMetadata)
        XCTAssertEqual(secondCallCount, 0)
        XCTAssertEqual(try jsonFiles(in: directory).count, 1)
    }

    func testPositiveEntryRefreshesAfterThirtyDays() async throws {
        let directory = try makeTemporaryDirectory()
        let clock = TestClock(Self.referenceDate)
        let cache = makeCache(directory: directory, clock: clock)

        let initial = QueueBookMetadataProvider([.success(Self.firstMetadata)])
        _ = try await CachedBookMetadataProvider(upstream: initial, cache: cache)
            .lookup(isbn: Self.isbnA)

        clock.advance(days: 31)
        let refresh = QueueBookMetadataProvider([.success(Self.refreshedMetadata)])
        let result = try await CachedBookMetadataProvider(upstream: refresh, cache: cache)
            .lookup(isbn: Self.isbnA)

        let refreshCallCount = await refresh.callCount
        XCTAssertEqual(result, Self.refreshedMetadata)
        XCTAssertEqual(refreshCallCount, 1)
        guard case .fresh(let stored) = try await cache.lookup(isbn: Self.isbnA) else {
            return XCTFail("Odświeżony wynik powinien zastąpić stary wpis.")
        }
        XCTAssertEqual(stored, Self.refreshedMetadata)
    }

    func testNotFoundIsCachedForTwentyFourHoursThenRefreshed() async throws {
        let directory = try makeTemporaryDirectory()
        let clock = TestClock(Self.referenceDate)
        let cache = makeCache(directory: directory, clock: clock)
        let initial = QueueBookMetadataProvider([.success(nil)])

        let initialResult = try await CachedBookMetadataProvider(upstream: initial, cache: cache)
            .lookup(isbn: Self.isbnA)
        XCTAssertNil(initialResult)

        clock.advance(hours: 23)
        let beforeExpiry = QueueBookMetadataProvider([.failure(.unavailable)])
        let cachedMiss = try await CachedBookMetadataProvider(upstream: beforeExpiry, cache: cache)
            .lookup(isbn: Self.isbnA)
        let beforeExpiryCallCount = await beforeExpiry.callCount
        XCTAssertNil(cachedMiss)
        XCTAssertEqual(beforeExpiryCallCount, 0)

        clock.advance(hours: 2)
        let afterExpiry = QueueBookMetadataProvider([.success(Self.firstMetadata)])
        let refreshed = try await CachedBookMetadataProvider(upstream: afterExpiry, cache: cache)
            .lookup(isbn: Self.isbnA)
        let afterExpiryCallCount = await afterExpiry.callCount
        XCTAssertEqual(refreshed, Self.firstMetadata)
        XCTAssertEqual(afterExpiryCallCount, 1)
    }

    func testStalePositiveFallsBackWhenUpstreamFailsWithinOneYear() async throws {
        let directory = try makeTemporaryDirectory()
        let clock = TestClock(Self.referenceDate)
        let cache = makeCache(directory: directory, clock: clock)
        try await cache.store(Self.firstMetadata, forISBN: Self.isbnA)
        clock.advance(days: 364)

        let upstream = QueueBookMetadataProvider([.failure(.unavailable)])
        let result = try await CachedBookMetadataProvider(upstream: upstream, cache: cache)
            .lookup(isbn: Self.isbnA)

        let upstreamCallCount = await upstream.callCount
        XCTAssertEqual(result, Self.firstMetadata)
        XCTAssertEqual(upstreamCallCount, 1)
    }

    func testPositiveOlderThanOneYearIsRemovedAndDoesNotHideFailure() async throws {
        let directory = try makeTemporaryDirectory()
        let clock = TestClock(Self.referenceDate)
        let cache = makeCache(directory: directory, clock: clock)
        try await cache.store(Self.firstMetadata, forISBN: Self.isbnA)
        clock.advance(days: 366)

        let upstream = QueueBookMetadataProvider([.failure(.unavailable)])
        do {
            _ = try await CachedBookMetadataProvider(upstream: upstream, cache: cache)
                .lookup(isbn: Self.isbnA)
            XCTFail("Wpis starszy niż rok nie może ukrywać błędu upstreamu.")
        } catch {
            XCTAssertEqual(error as? CacheTestError, .unavailable)
        }

        let upstreamCallCount = await upstream.callCount
        XCTAssertEqual(upstreamCallCount, 1)
        XCTAssertTrue(try jsonFiles(in: directory).isEmpty)
    }

    func testInvalidISBNDoesNotCallUpstreamOrCreateCacheDirectory() async throws {
        let root = try makeTemporaryDirectory()
        let directory = root.appendingPathComponent("not-created", isDirectory: true)
        let upstream = QueueBookMetadataProvider([.success(Self.firstMetadata)])
        let provider = CachedBookMetadataProvider(
            upstream: upstream,
            cache: makeCache(directory: directory, clock: TestClock(Self.referenceDate))
        )

        do {
            _ = try await provider.lookup(isbn: "9780306406158")
            XCTFail("Nieprawidłowy ISBN powinien zostać odrzucony.")
        } catch {
            XCTAssertEqual(error as? BookMetadataLookupError, .invalidISBN)
        }

        let upstreamCallCount = await upstream.callCount
        XCTAssertEqual(upstreamCallCount, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    func testCancellationDoesNotCallUpstreamOrCreateCacheDirectory() async throws {
        let root = try makeTemporaryDirectory()
        let directory = root.appendingPathComponent("not-created", isDirectory: true)
        let upstream = QueueBookMetadataProvider([.success(Self.firstMetadata)])
        let provider = CachedBookMetadataProvider(
            upstream: upstream,
            cache: makeCache(directory: directory, clock: TestClock(Self.referenceDate))
        )

        let task = Task<BookMetadata?, Error> {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await provider.lookup(isbn: Self.isbnA)
        }

        do {
            _ = try await task.value
            XCTFail("Anulowany lookup powinien rzucić CancellationError.")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }

        let upstreamCallCount = await upstream.callCount
        XCTAssertEqual(upstreamCallCount, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    func testCancelledUpstreamDoesNotWriteOutcome() async throws {
        let root = try makeTemporaryDirectory()
        let directory = root.appendingPathComponent("not-created", isDirectory: true)
        let upstream = CancelledBookMetadataProvider()
        let provider = CachedBookMetadataProvider(
            upstream: upstream,
            cache: makeCache(directory: directory, clock: TestClock(Self.referenceDate))
        )

        do {
            _ = try await provider.lookup(isbn: Self.isbnA)
            XCTFail("Anulowany transport powinien zachować semantykę anulowania.")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }

        let upstreamCallCount = await upstream.callCount
        XCTAssertEqual(upstreamCallCount, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    func testCorruptEntryIsRemovedAndTreatedAsMiss() async throws {
        let directory = try makeTemporaryDirectory()
        let clock = TestClock(Self.referenceDate)
        let cache = makeCache(directory: directory, clock: clock)
        try await cache.store(Self.firstMetadata, forISBN: Self.isbnA)
        let file = try XCTUnwrap(jsonFiles(in: directory).first)
        try Data("not-json".utf8).write(to: file, options: .atomic)

        let upstream = QueueBookMetadataProvider([.failure(.unavailable)])
        do {
            _ = try await CachedBookMetadataProvider(upstream: upstream, cache: cache)
                .lookup(isbn: Self.isbnA)
            XCTFail("Uszkodzony wpis powinien zachowywać się jak cache miss.")
        } catch {
            XCTAssertEqual(error as? CacheTestError, .unavailable)
        }

        let upstreamCallCount = await upstream.callCount
        XCTAssertEqual(upstreamCallCount, 1)
        XCTAssertTrue(try jsonFiles(in: directory).isEmpty)
    }

    func testOversizedDiskEntryIsRemovedBeforeReadingOrDecoding() async throws {
        let directory = try makeTemporaryDirectory()
        let cache = makeCache(directory: directory, clock: TestClock(Self.referenceDate))
        try await cache.store(Self.firstMetadata, forISBN: Self.isbnA)
        let file = try XCTUnwrap(jsonFiles(in: directory).first)
        try Data(count: Int(BookMetadataCache.maximumEntryByteCount + 1))
            .write(to: file, options: .atomic)

        let result = try await cache.lookup(isbn: Self.isbnA)

        XCTAssertEqual(result, .miss)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testEntryCountAndByteLimitsPruneDeterministically() async throws {
        let directory = try makeTemporaryDirectory()
        let clock = TestClock(Self.referenceDate)
        let countLimited = makeCache(
            directory: directory,
            clock: clock,
            maximumEntryCount: 2
        )

        try await countLimited.store(Self.firstMetadata, forISBN: Self.isbnA)
        clock.advance(seconds: 1)
        try await countLimited.store(Self.firstMetadata, forISBN: Self.isbnB)
        clock.advance(seconds: 1)
        try await countLimited.store(Self.firstMetadata, forISBN: Self.isbnC)

        XCTAssertEqual(try jsonFiles(in: directory).count, 2)
        let oldestResult = try await countLimited.lookup(isbn: Self.isbnA)
        XCTAssertEqual(oldestResult, .miss)
        guard case .fresh = try await countLimited.lookup(isbn: Self.isbnB) else {
            return XCTFail("Nowszy wpis B nie powinien zostać usunięty.")
        }
        guard case .fresh = try await countLimited.lookup(isbn: Self.isbnC) else {
            return XCTFail("Nowszy wpis C nie powinien zostać usunięty.")
        }

        let byteDirectory = try makeTemporaryDirectory()
        let byteLimited = makeCache(
            directory: byteDirectory,
            clock: clock,
            maximumByteCount: 1
        )
        try await byteLimited.store(Self.firstMetadata, forISBN: Self.isbnA)
        XCTAssertTrue(try jsonFiles(in: byteDirectory).isEmpty)

        XCTAssertEqual(BookMetadataCache.maximumEntryCount, 10_000)
        XCTAssertEqual(BookMetadataCache.maximumByteCount, 20 * 1_024 * 1_024)
        XCTAssertEqual(BookMetadataCache.maximumEntryByteCount, 512 * 1_024)
    }

    func testReadingEntryRefreshesItsLRUPositionBeforePruning() async throws {
        let directory = try makeTemporaryDirectory()
        let clock = TestClock(Self.referenceDate)
        let cache = makeCache(
            directory: directory,
            clock: clock,
            maximumEntryCount: 2
        )

        try await cache.store(Self.firstMetadata, forISBN: Self.isbnA)
        clock.advance(seconds: 1)
        try await cache.store(Self.firstMetadata, forISBN: Self.isbnB)
        clock.advance(seconds: 1)

        guard case .fresh = try await cache.lookup(isbn: Self.isbnA) else {
            return XCTFail("Odczytywany wpis A powinien istnieć przed przycięciem cache.")
        }

        clock.advance(seconds: 1)
        try await cache.store(Self.firstMetadata, forISBN: Self.isbnC)

        guard case .fresh = try await cache.lookup(isbn: Self.isbnA) else {
            return XCTFail("Ostatnio używany wpis A nie powinien zostać usunięty.")
        }
        let evictedResult = try await cache.lookup(isbn: Self.isbnB)
        XCTAssertEqual(evictedResult, .miss)
        guard case .fresh = try await cache.lookup(isbn: Self.isbnC) else {
            return XCTFail("Nowy wpis C powinien pozostać w cache.")
        }
    }

    func testDirectoryIsExcludedFromBackupAndWriteLeavesOnlyFinalJSON() async throws {
        let directory = try makeTemporaryDirectory()
        let cache = makeCache(directory: directory, clock: TestClock(Self.referenceDate))
        try await cache.store(Self.firstMetadata, forISBN: Self.isbnA)

        let values = try directory.resourceValues(forKeys: [.isExcludedFromBackupKey])
        XCTAssertEqual(values.isExcludedFromBackup, true)
        let contents = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )
        XCTAssertEqual(contents.count, 1)
        XCTAssertEqual(contents.first?.pathExtension, "json")
        let stem = try XCTUnwrap(contents.first?.deletingPathExtension().lastPathComponent)
        XCTAssertEqual(stem.count, 64)
        XCTAssertTrue(stem.allSatisfy { $0.isHexDigit && !$0.isUppercase })
        XCTAssertFalse(stem.contains(Self.isbnA))

        let defaultDirectory = BookMetadataCache.defaultDirectoryURL
        XCTAssertEqual(defaultDirectory.lastPathComponent, "MetadataCache")
        XCTAssertEqual(defaultDirectory.deletingLastPathComponent().lastPathComponent, "HomeLibrary")
        XCTAssertEqual(BookMetadataCache.positiveTimeToLive, 30 * 24 * 60 * 60)
        XCTAssertEqual(BookMetadataCache.notFoundTimeToLive, 24 * 60 * 60)
        XCTAssertEqual(BookMetadataCache.maximumStalePositiveAge, 365 * 24 * 60 * 60)
    }

    func testDefaultProviderUsesThePersistentDecorator() async throws {
        let directory = try makeTemporaryDirectory()
        let clock = TestClock(Self.referenceDate)
        let cache = makeCache(directory: directory, clock: clock)
        let initial = QueueBookMetadataProvider([.success(Self.firstMetadata)])
        let provider = DefaultBookMetadataProvider(upstream: initial, cache: cache)

        let firstResult = try await provider.lookup(isbn: Self.isbnA)
        let secondResult = try await provider.lookup(isbn: Self.isbnA)
        let callCount = await initial.callCount
        XCTAssertEqual(firstResult, Self.firstMetadata)
        XCTAssertEqual(secondResult, Self.firstMetadata)
        XCTAssertEqual(callCount, 1)
    }

    func testTwentyConcurrentLookupsShareOneUpstreamAndOneStoredResult() async throws {
        let directory = try makeTemporaryDirectory()
        let cache = makeCache(
            directory: directory,
            clock: TestClock(Self.referenceDate)
        )
        let upstream = GateBookMetadataProvider(result: Self.firstMetadata)
        let provider = CachedBookMetadataProvider(upstream: upstream, cache: cache)

        let tasks: [Task<BookMetadata?, Error>] = (0..<20).map { _ in
            Task { try await provider.lookup(isbn: Self.isbnA) }
        }

        try await waitUntil("20 lookupów nie dołączyło do wspólnego requestu") {
            try await cache.inFlightWaiterCount(forISBN: Self.isbnA) == 20
        }
        let callsBeforeRelease = await upstream.callCount
        XCTAssertEqual(callsBeforeRelease, 1)

        await upstream.releaseAll()
        for task in tasks {
            let result = try await task.value
            XCTAssertEqual(result, Self.firstMetadata)
        }

        let finalCallCount = await upstream.callCount
        XCTAssertEqual(finalCallCount, 1)
        XCTAssertEqual(try jsonFiles(in: directory).count, 1)
        guard case .fresh(let stored) = try await cache.lookup(isbn: Self.isbnA) else {
            return XCTFail("Wspólny wynik powinien zostać zapisany dokładnie jako positive hit.")
        }
        XCTAssertEqual(stored, Self.firstMetadata)
    }

    func testCancellingOneWaiterLeavesSharedUpstreamForRemainingWaiter() async throws {
        let directory = try makeTemporaryDirectory()
        let cache = makeCache(
            directory: directory,
            clock: TestClock(Self.referenceDate)
        )
        let upstream = GateBookMetadataProvider(result: Self.firstMetadata)
        let provider = CachedBookMetadataProvider(upstream: upstream, cache: cache)
        let cancelled = Task { try await provider.lookup(isbn: Self.isbnA) }
        let remaining = Task { try await provider.lookup(isbn: Self.isbnA) }

        try await waitUntil("Dwaj waiterzy nie dołączyli do requestu") {
            try await cache.inFlightWaiterCount(forISBN: Self.isbnA) == 2
        }
        cancelled.cancel()
        await assertCancellation(of: cancelled)
        try await waitUntil("Anulowany waiter nie został odłączony") {
            try await cache.inFlightWaiterCount(forISBN: Self.isbnA) == 1
        }

        let cancellationsBeforeRelease = await upstream.cancellationCount
        XCTAssertEqual(cancellationsBeforeRelease, 0)
        await upstream.releaseAll()
        let remainingResult = try await remaining.value
        let finalCallCount = await upstream.callCount
        let finalCancellationCount = await upstream.cancellationCount

        XCTAssertEqual(remainingResult, Self.firstMetadata)
        XCTAssertEqual(finalCallCount, 1)
        XCTAssertEqual(finalCancellationCount, 0)
        XCTAssertEqual(try jsonFiles(in: directory).count, 1)
    }

    func testCancellingLastWaiterCancelsUpstreamAndDoesNotStore() async throws {
        let directory = try makeTemporaryDirectory()
        let cache = makeCache(
            directory: directory,
            clock: TestClock(Self.referenceDate)
        )
        let upstream = GateBookMetadataProvider(result: Self.firstMetadata)
        let provider = CachedBookMetadataProvider(upstream: upstream, cache: cache)
        let first = Task { try await provider.lookup(isbn: Self.isbnA) }
        let last = Task { try await provider.lookup(isbn: Self.isbnA) }

        try await waitUntil("Dwaj waiterzy nie dołączyli do requestu") {
            try await cache.inFlightWaiterCount(forISBN: Self.isbnA) == 2
        }
        first.cancel()
        await assertCancellation(of: first)
        try await waitUntil("Pierwszy waiter nie został odłączony") {
            try await cache.inFlightWaiterCount(forISBN: Self.isbnA) == 1
        }
        let cancellationsBeforeLastWaiter = await upstream.cancellationCount
        XCTAssertEqual(cancellationsBeforeLastWaiter, 0)

        last.cancel()
        await assertCancellation(of: last)
        try await waitUntil("Ostatni waiter nie anulował upstreamu") {
            await upstream.cancellationCount == 1
        }

        let waiterCount = try await cache.inFlightWaiterCount(forISBN: Self.isbnA)
        let finalCallCount = await upstream.callCount
        let finalCacheResult = try await cache.lookup(isbn: Self.isbnA)
        XCTAssertEqual(waiterCount, 0)
        XCTAssertEqual(finalCallCount, 1)
        XCTAssertTrue(try jsonFiles(in: directory).isEmpty)
        XCTAssertEqual(finalCacheResult, .miss)
    }

    func testConflictingProvidersForSameISBNUseFirstFlightAndCannotOverwritePositive() async throws {
        let directory = try makeTemporaryDirectory()
        let cache = makeCache(
            directory: directory,
            clock: TestClock(Self.referenceDate)
        )
        let positiveUpstream = GateBookMetadataProvider(result: Self.firstMetadata)
        let noMatchUpstream = GateBookMetadataProvider(result: nil)
        let positiveProvider = CachedBookMetadataProvider(
            upstream: positiveUpstream,
            cache: cache
        )
        let noMatchProvider = CachedBookMetadataProvider(
            upstream: noMatchUpstream,
            cache: cache
        )

        let positiveTask = Task { try await positiveProvider.lookup(isbn: Self.isbnA) }
        try await waitUntil("Pierwszy positive flight nie wystartował") {
            await positiveUpstream.callCount == 1
        }
        let noMatchTask = Task { try await noMatchProvider.lookup(isbn: Self.isbnA) }
        try await waitUntil("Drugi provider nie dołączył do istniejącego flightu") {
            try await cache.inFlightWaiterCount(forISBN: Self.isbnA) == 2
        }

        let noMatchCallsBeforeRelease = await noMatchUpstream.callCount
        XCTAssertEqual(noMatchCallsBeforeRelease, 0)
        await positiveUpstream.releaseAll()
        let positiveResult = try await positiveTask.value
        let joinedResult = try await noMatchTask.value
        let positiveCallCount = await positiveUpstream.callCount
        let noMatchCallCount = await noMatchUpstream.callCount

        XCTAssertEqual(positiveResult, Self.firstMetadata)
        XCTAssertEqual(joinedResult, Self.firstMetadata)
        XCTAssertEqual(positiveCallCount, 1)
        XCTAssertEqual(noMatchCallCount, 0)
        guard case .fresh(let stored) = try await cache.lookup(isbn: Self.isbnA) else {
            return XCTFail("Późniejszy no-match nie może zastąpić positive wpisu.")
        }
        XCTAssertEqual(stored, Self.firstMetadata)
    }
}

private extension BookMetadataCacheTests {
    static let referenceDate = Date(timeIntervalSince1970: 1_767_225_600)
    static let isbnA = "9780306406157"
    static let isbnB = "9783161484100"
    static let isbnC = "9788328728646"

    static let firstMetadata = BookMetadata(
        source: .nationalLibrary,
        title: "Pierwsze wydanie",
        subtitle: nil,
        authors: ["Autor"],
        publisher: "Wydawnictwo",
        publicationYear: 2025,
        language: "pl",
        coverURL: URL(string: "https://covers.openlibrary.org/b/isbn/9780306406157-M.jpg"),
        coverSource: .openLibrary
    )

    static let refreshedMetadata = BookMetadata(
        source: .openLibrary,
        title: "Wynik odświeżony",
        subtitle: "Nowe dane",
        authors: ["Author"],
        publisher: "Publisher",
        publicationYear: 2026,
        language: "en"
    )

    func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BookMetadataCacheTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        temporaryDirectories.append(directory)
        return directory
    }

    func makeCache(
        directory: URL,
        clock: TestClock,
        maximumEntryCount: Int = BookMetadataCache.maximumEntryCount,
        maximumByteCount: Int64 = BookMetadataCache.maximumByteCount
    ) -> BookMetadataCache {
        BookMetadataCache(
            directoryURL: directory,
            now: { clock.now() },
            maximumEntryCount: maximumEntryCount,
            maximumByteCount: maximumByteCount
        )
    }

    func jsonFiles(in directory: URL) throws -> [URL] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ).filter { $0.pathExtension == "json" }
    }

    func waitUntil(
        _ failureMessage: String,
        timeout: TimeInterval = 2,
        condition: @escaping () async throws -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if try await condition() { return }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTFail(failureMessage)
        throw CacheTestError.timedOut
    }

    func assertCancellation(
        of task: Task<BookMetadata?, Error>,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await task.value
            XCTFail("Zadanie powinno zakończyć się CancellationError.", file: file, line: line)
        } catch {
            XCTAssertTrue(error is CancellationError, file: file, line: line)
        }
    }

}

private enum CacheTestError: Error, Equatable {
    case unavailable
    case timedOut
}

private actor QueueBookMetadataProvider: BookMetadataProviding {
    private var results: [Result<BookMetadata?, CacheTestError>]
    private(set) var callCount = 0

    init(_ results: [Result<BookMetadata?, CacheTestError>]) {
        self.results = results
    }

    func lookup(isbn: String) async throws -> BookMetadata? {
        callCount += 1
        guard !results.isEmpty else {
            throw CacheTestError.unavailable
        }
        return try results.removeFirst().get()
    }
}

private actor CancelledBookMetadataProvider: BookMetadataProviding {
    private(set) var callCount = 0

    func lookup(isbn: String) async throws -> BookMetadata? {
        callCount += 1
        throw URLError(.cancelled)
    }
}

private actor GateBookMetadataProvider: BookMetadataProviding {
    private let result: BookMetadata?
    private var isReleased = false
    private var gates: [UUID: CheckedContinuation<Void, Never>] = [:]
    private(set) var callCount = 0
    private(set) var cancellationCount = 0

    init(result: BookMetadata?) {
        self.result = result
    }

    func lookup(isbn: String) async throws -> BookMetadata? {
        callCount += 1
        let requestID = UUID()

        do {
            try await withTaskCancellationHandler {
                await waitForRelease(requestID: requestID)
                try Task.checkCancellation()
            } onCancel: {
                Task {
                    await self.unblockCancelledRequest(requestID)
                }
            }
        } catch {
            cancellationCount += 1
            throw error
        }

        return result
    }

    func releaseAll() {
        isReleased = true
        let pending = gates.values
        gates.removeAll()
        for continuation in pending {
            continuation.resume()
        }
    }

    private func waitForRelease(requestID: UUID) async {
        if isReleased { return }
        await withCheckedContinuation { continuation in
            if isReleased {
                continuation.resume()
            } else {
                gates[requestID] = continuation
            }
        }
    }

    private func unblockCancelledRequest(_ requestID: UUID) {
        gates.removeValue(forKey: requestID)?.resume()
    }
}

private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date: Date

    init(_ date: Date) {
        self.date = date
    }

    func now() -> Date {
        lock.lock()
        defer { lock.unlock() }
        return date
    }

    func advance(seconds: TimeInterval) {
        lock.lock()
        date = date.addingTimeInterval(seconds)
        lock.unlock()
    }

    func advance(hours: TimeInterval) {
        advance(seconds: hours * 60 * 60)
    }

    func advance(days: TimeInterval) {
        advance(seconds: days * 24 * 60 * 60)
    }
}
