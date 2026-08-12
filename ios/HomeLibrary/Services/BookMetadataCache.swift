import CryptoKit
import Foundation

/// A small, rebuildable, on-disk cache for normalized catalog responses.
///
/// Only public bibliographic data is stored here. Collection data, locations
/// and notes never enter this directory. Each ISBN has one atomic JSON file,
/// which keeps a damaged response isolated from the rest of the cache.
actor BookMetadataCache {
    enum LookupResult: Equatable, Sendable {
        case fresh(BookMetadata)
        case stale(BookMetadata)
        case notFound
        case miss
    }

    static let positiveTimeToLive: TimeInterval = 30 * 24 * 60 * 60
    static let notFoundTimeToLive: TimeInterval = 24 * 60 * 60
    static let maximumStalePositiveAge: TimeInterval = 365 * 24 * 60 * 60
    static let maximumEntryCount = 10_000
    static let maximumByteCount: Int64 = 20 * 1_024 * 1_024
    static let maximumEntryByteCount: Int64 = 512 * 1_024

    static let shared = BookMetadataCache()

    nonisolated static var defaultDirectoryURL: URL {
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory

        return applicationSupport
            .appendingPathComponent("HomeLibrary", isDirectory: true)
            .appendingPathComponent("MetadataCache", isDirectory: true)
    }

    private let directoryURL: URL
    private let now: @Sendable () -> Date
    private let positiveTTL: TimeInterval
    private let notFoundTTL: TimeInterval
    private let maximumStaleAge: TimeInterval
    private let maximumEntries: Int
    private let maximumBytes: Int64
    private let fileManager: FileManager
    private var inFlightLookups: [String: InFlightLookup] = [:]

    init(
        directoryURL: URL = BookMetadataCache.defaultDirectoryURL,
        now: @escaping @Sendable () -> Date = { Date() },
        positiveTTL: TimeInterval = BookMetadataCache.positiveTimeToLive,
        notFoundTTL: TimeInterval = BookMetadataCache.notFoundTimeToLive,
        maximumStaleAge: TimeInterval = BookMetadataCache.maximumStalePositiveAge,
        maximumEntryCount: Int = BookMetadataCache.maximumEntryCount,
        maximumByteCount: Int64 = BookMetadataCache.maximumByteCount,
        fileManager: FileManager = .default
    ) {
        self.directoryURL = directoryURL
        self.now = now
        self.positiveTTL = positiveTTL
        self.notFoundTTL = notFoundTTL
        self.maximumStaleAge = maximumStaleAge
        maximumEntries = max(0, maximumEntryCount)
        maximumBytes = max(0, maximumByteCount)
        self.fileManager = fileManager
    }

    func lookup(isbn rawISBN: String) throws -> LookupResult {
        try Task.checkCancellation()
        let isbn13 = try Self.normalizedISBN13(rawISBN)
        try Task.checkCancellation()

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: directoryURL.path, isDirectory: &isDirectory) else {
            return .miss
        }
        guard isDirectory.boolValue else {
            throw CocoaError(.fileReadUnsupportedScheme)
        }

        let fileURL = entryURL(for: isbn13)
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return .miss
        }

        guard let attributes = try? fileManager.attributesOfItem(atPath: fileURL.path),
              let byteCount = (attributes[.size] as? NSNumber)?.int64Value,
              byteCount > 0,
              byteCount <= Self.maximumEntryByteCount else {
            try? fileManager.removeItem(at: fileURL)
            return .miss
        }

        let entry: DiskEntry
        do {
            let data = try Data(contentsOf: fileURL, options: .mappedIfSafe)
            entry = try Self.decoder.decode(DiskEntry.self, from: data)
            guard entry.schemaVersion == DiskEntry.currentSchemaVersion,
                  entry.isbn13 == isbn13,
                  entry.isValid else {
                throw CacheEntryError.invalidPayload
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try Task.checkCancellation()
            try? fileManager.removeItem(at: fileURL)
            return .miss
        }

        try Task.checkCancellation()
        let age = max(0, now().timeIntervalSince(entry.storedAt))

        switch entry.outcome {
        case .metadata:
            guard let metadata = entry.metadata else {
                try? fileManager.removeItem(at: fileURL)
                return .miss
            }
            if age < positiveTTL {
                touch(fileURL)
                return .fresh(metadata)
            }
            if age <= maximumStaleAge {
                touch(fileURL)
                return .stale(metadata)
            }
        case .notFound:
            if age < notFoundTTL {
                touch(fileURL)
                return .notFound
            }
        }

        try Task.checkCancellation()
        try? fileManager.removeItem(at: fileURL)
        return .miss
    }

    func store(_ metadata: BookMetadata?, forISBN rawISBN: String) throws {
        try Task.checkCancellation()
        let isbn13 = try Self.normalizedISBN13(rawISBN)
        let storedAt = now()
        let usefulMetadata = metadata.flatMap { $0.hasUsefulData ? $0 : nil }
        let entry = DiskEntry(
            schemaVersion: DiskEntry.currentSchemaVersion,
            isbn13: isbn13,
            outcome: usefulMetadata == nil ? .notFound : .metadata,
            metadata: usefulMetadata,
            storedAt: storedAt
        )
        let encoded = try Self.encoder.encode(entry)
        guard encoded.count <= Self.maximumEntryByteCount else {
            throw CacheEntryError.entryTooLarge
        }

        try Task.checkCancellation()
        try prepareDirectoryForWriting()
        try Task.checkCancellation()

        let fileURL = entryURL(for: isbn13)
        try encoded.write(to: fileURL, options: .atomic)
        try? fileManager.setAttributes(
            [.modificationDate: storedAt],
            ofItemAtPath: fileURL.path
        )
        try enforceLimits()
    }

    /// Coalesces concurrent cache misses for one normalized ISBN. Every caller
    /// gets its own continuation, so cancelling one waiter does not implicitly
    /// cancel the unstructured upstream task used by the remaining waiters.
    /// The last departing waiter removes the flight and cancels that task.
    func fetchSingleFlight(
        isbn rawISBN: String,
        operation: @escaping @Sendable () async throws -> BookMetadata?
    ) async throws -> BookMetadata? {
        try Task.checkCancellation()
        let isbn13 = try Self.normalizedISBN13(rawISBN)
        try Task.checkCancellation()

        // Close the race between an earlier cache read and joining the flight:
        // another request may have completed and persisted a result meanwhile.
        if inFlightLookups[isbn13] == nil {
            do {
                switch try lookup(isbn: isbn13) {
                case .fresh(let metadata):
                    return metadata
                case .notFound:
                    return nil
                case .stale, .miss:
                    break
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // A broken/unavailable cache must not prevent a network lookup.
            }
        }

        try Task.checkCancellation()
        let waiterID = UUID()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let value = try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<BookMetadata?, Error>) in
                registerWaiter(
                    waiterID,
                    for: isbn13,
                    operation: operation,
                    continuation: continuation
                )

                // Covers cancellation racing with continuation registration.
                if Task.isCancelled {
                    cancelWaiter(waiterID, for: isbn13)
                }
            }
            try Task.checkCancellation()
            return value
        } onCancel: {
            Task {
                await self.cancelWaiter(waiterID, for: isbn13)
            }
        }
    }

    /// Internal diagnostic used by deterministic concurrency tests.
    func inFlightWaiterCount(forISBN rawISBN: String) throws -> Int {
        let isbn13 = try Self.normalizedISBN13(rawISBN)
        return inFlightLookups[isbn13]?.waiters.count ?? 0
    }
}

fileprivate extension BookMetadataCache {
    enum CacheEntryError: Error {
        case invalidPayload
        case entryTooLarge
    }

    struct DiskEntry: Codable {
        static let currentSchemaVersion = 1

        enum Outcome: String, Codable {
            case metadata
            case notFound
        }

        let schemaVersion: Int
        let isbn13: String
        let outcome: Outcome
        let metadata: BookMetadata?
        let storedAt: Date

        var isValid: Bool {
            switch outcome {
            case .metadata:
                metadata?.hasUsefulData == true
            case .notFound:
                metadata == nil
            }
        }
    }

    struct CachedFile {
        let url: URL
        let byteCount: Int64
        let modificationDate: Date
    }

    struct InFlightLookup {
        let id: UUID
        let task: Task<Void, Never>
        var waiters: [UUID: CheckedContinuation<BookMetadata?, Error>]
    }

    enum FlightOutcome: @unchecked Sendable {
        case success(BookMetadata?)
        case failure(Error)
    }

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }()

    static func normalizedISBN13(_ rawISBN: String) throws -> String {
        let parsed = PublicationIdentifierParser.parse(rawISBN)
        guard parsed.isValid,
              parsed.kind == .isbn10 || parsed.kind == .isbn13,
              let isbn13 = parsed.isbn13 else {
            throw BookMetadataLookupError.invalidISBN
        }
        return isbn13
    }

    func entryURL(for isbn13: String) -> URL {
        let digest = SHA256.hash(data: Data(isbn13.utf8))
        let filename = digest.map { String(format: "%02x", $0) }.joined()
        return directoryURL.appendingPathComponent(filename, isDirectory: false)
            .appendingPathExtension("json")
    }

    func prepareDirectoryForWriting() throws {
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: directoryURL.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else {
                throw CocoaError(.fileWriteFileExists)
            }
        } else {
            try fileManager.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true
            )
        }

        var mutableDirectoryURL = directoryURL
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        try mutableDirectoryURL.setResourceValues(resourceValues)
    }

    func touch(_ fileURL: URL) {
        try? fileManager.setAttributes(
            [.modificationDate: now()],
            ofItemAtPath: fileURL.path
        )
    }

    func registerWaiter(
        _ waiterID: UUID,
        for isbn13: String,
        operation: @escaping @Sendable () async throws -> BookMetadata?,
        continuation: CheckedContinuation<BookMetadata?, Error>
    ) {
        if var flight = inFlightLookups[isbn13] {
            flight.waiters[waiterID] = continuation
            inFlightLookups[isbn13] = flight
            return
        }

        let flightID = UUID()
        let priority = Task.currentPriority
        let task = Task.detached(priority: priority) { [self] in
            let outcome: FlightOutcome
            do {
                let metadata = try await operation()
                try Task.checkCancellation()
                outcome = .success(metadata)
            } catch {
                outcome = .failure(error)
            }
            await completeFlight(flightID, for: isbn13, outcome: outcome)
        }

        inFlightLookups[isbn13] = InFlightLookup(
            id: flightID,
            task: task,
            waiters: [waiterID: continuation]
        )
    }

    func cancelWaiter(_ waiterID: UUID, for isbn13: String) {
        guard var flight = inFlightLookups[isbn13],
              let continuation = flight.waiters.removeValue(forKey: waiterID) else {
            return
        }

        continuation.resume(throwing: CancellationError())
        if flight.waiters.isEmpty {
            inFlightLookups.removeValue(forKey: isbn13)
            flight.task.cancel()
        } else {
            inFlightLookups[isbn13] = flight
        }
    }

    func completeFlight(
        _ flightID: UUID,
        for isbn13: String,
        outcome: FlightOutcome
    ) {
        guard let flight = inFlightLookups[isbn13], flight.id == flightID else {
            // All waiters left. The cancelled or non-cooperative old flight is
            // not allowed to persist a result over a newer request.
            return
        }
        inFlightLookups.removeValue(forKey: isbn13)

        switch outcome {
        case .success(let fetched):
            let usefulMetadata = fetched.flatMap { $0.hasUsefulData ? $0 : nil }
            do {
                try store(usefulMetadata, forISBN: isbn13)
            } catch {
                // A cache write failure must not discard a valid network result.
            }
            for continuation in flight.waiters.values {
                continuation.resume(returning: usefulMetadata)
            }
        case .failure(let error):
            for continuation in flight.waiters.values {
                continuation.resume(throwing: error)
            }
        }
    }

    func enforceLimits() throws {
        let keys: Set<URLResourceKey> = [
            .isRegularFileKey,
            .fileSizeKey,
            .contentModificationDateKey
        ]
        let urls = try fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        )

        var files = try urls.compactMap { url -> CachedFile? in
            guard url.pathExtension == "json" else { return nil }
            let values = try url.resourceValues(forKeys: keys)
            guard values.isRegularFile != false else { return nil }
            return CachedFile(
                url: url,
                byteCount: Int64(values.fileSize ?? 0),
                modificationDate: values.contentModificationDate ?? .distantPast
            )
        }

        files.sort {
            if $0.modificationDate != $1.modificationDate {
                return $0.modificationDate < $1.modificationDate
            }
            return $0.url.lastPathComponent < $1.url.lastPathComponent
        }

        var totalBytes = files.reduce(Int64(0)) { $0 + $1.byteCount }
        while files.count > maximumEntries || totalBytes > maximumBytes {
            let oldest = files.removeFirst()
            try fileManager.removeItem(at: oldest.url)
            totalBytes -= oldest.byteCount
        }
    }
}

/// Adds durable positive and negative caching without changing the lookup API.
/// Cache failures are deliberately non-fatal; catalog availability remains
/// more important than the acceleration layer.
struct CachedBookMetadataProvider: BookMetadataProviding {
    private let upstream: any BookMetadataProviding
    private let cache: BookMetadataCache
    private let observer: BookMetadataLookupObserver

    init(
        upstream: any BookMetadataProviding,
        cache: BookMetadataCache = .shared,
        observer: BookMetadataLookupObserver = .disabled
    ) {
        self.upstream = upstream
        self.cache = cache
        self.observer = observer
    }

    func lookup(isbn rawISBN: String) async throws -> BookMetadata? {
        try Task.checkCancellation()
        let isbn13 = try BookMetadataCache.normalizedISBN13(rawISBN)

        let cacheResult: BookMetadataCache.LookupResult
        var cacheFailureWasRecorded = false
        do {
            cacheResult = try await cache.lookup(isbn: isbn13)
        } catch is CancellationError {
            await observer.record(source: .metadataCache, outcome: .cancelled)
            throw CancellationError()
        } catch {
            if Task.isCancelled {
                await observer.record(source: .metadataCache, outcome: .cancelled)
                throw CancellationError()
            }
            await observer.record(source: .metadataCache, outcome: .failed)
            cacheFailureWasRecorded = true
            cacheResult = .miss
        }

        let staleMetadata: BookMetadata?
        switch cacheResult {
        case .fresh(let metadata):
            await observer.record(source: .metadataCache, outcome: .found)
            return metadata
        case .notFound:
            await observer.record(source: .metadataCache, outcome: .notFound)
            return nil
        case .stale(let metadata):
            staleMetadata = metadata
        case .miss:
            staleMetadata = nil
            if !cacheFailureWasRecorded {
                await observer.record(source: .metadataCache, outcome: .miss)
            }
        }

        try Task.checkCancellation()
        do {
            let upstream = self.upstream
            let fetched = try await cache.fetchSingleFlight(isbn: isbn13) {
                try Task.checkCancellation()
                let fetched = try await upstream.lookup(isbn: isbn13)
                try Task.checkCancellation()
                return fetched.flatMap { $0.hasUsefulData ? $0 : nil }
            }
            if staleMetadata != nil {
                await observer.record(source: .metadataCache, outcome: .stale)
            }
            return fetched
        } catch is CancellationError {
            if staleMetadata != nil {
                await observer.record(source: .metadataCache, outcome: .stale)
            }
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            if staleMetadata != nil {
                await observer.record(source: .metadataCache, outcome: .stale)
            }
            throw CancellationError()
        } catch {
            if Task.isCancelled {
                if staleMetadata != nil {
                    await observer.record(source: .metadataCache, outcome: .stale)
                }
                throw CancellationError()
            }
            if let staleMetadata {
                await observer.record(source: .metadataCache, outcome: .staleFallback)
                return staleMetadata
            }
            throw error
        }
    }
}

/// Production metadata stack. It retains the existing BN → Open Library
/// cascade and adds one shared persistent cache around the normalized result.
struct DefaultBookMetadataProvider: BookMetadataProviding {
    private let provider: CachedBookMetadataProvider

    init(
        upstream: (any BookMetadataProviding)? = nil,
        cache: BookMetadataCache = .shared,
        observer: BookMetadataLookupObserver = .disabled
    ) {
        let effectiveUpstream = upstream ?? CascadingBookMetadataProvider.production(observer: observer)
        provider = CachedBookMetadataProvider(
            upstream: effectiveUpstream,
            cache: cache,
            observer: observer
        )
    }

    func lookup(isbn: String) async throws -> BookMetadata? {
        try await provider.lookup(isbn: isbn)
    }
}
