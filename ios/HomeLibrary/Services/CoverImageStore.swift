import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

protocol CoverImageTransport: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

struct URLSessionCoverImageTransport: CoverImageTransport {
    private static let maximumResponseBytes = 5 * 1_024 * 1_024
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        guard let requestURL = request.url else {
            throw CoverImageStoreError.disallowedURL
        }
        _ = try CoverImageRemoteURLPolicy.canonicalURL(requestURL)

        let redirectDelegate = CoverImageRedirectDelegate()
        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await session.bytes(
                for: request,
                delegate: redirectDelegate
            )
        } catch {
            if redirectDelegate.rejectedRedirect {
                throw CoverImageStoreError.disallowedURL
            }
            throw error
        }

        if redirectDelegate.rejectedRedirect {
            bytes.task.cancel()
            throw CoverImageStoreError.disallowedURL
        }
        guard let finalURL = response.url else {
            bytes.task.cancel()
            throw CoverImageStoreError.invalidResponse
        }
        do {
            _ = try CoverImageRemoteURLPolicy.canonicalURL(finalURL)
        } catch {
            bytes.task.cancel()
            throw error
        }

        if response.expectedContentLength > Int64(Self.maximumResponseBytes) {
            bytes.task.cancel()
            throw CoverImageStoreError.responseTooLarge
        }

        var data = Data()
        if response.expectedContentLength > 0 {
            data.reserveCapacity(min(Int(response.expectedContentLength), Self.maximumResponseBytes))
        }

        do {
            for try await byte in bytes {
                guard data.count < Self.maximumResponseBytes else {
                    bytes.task.cancel()
                    throw CoverImageStoreError.responseTooLarge
                }
                data.append(byte)
                if data.count.isMultiple(of: 64 * 1_024) {
                    try Task.checkCancellation()
                }
            }
        } catch {
            bytes.task.cancel()
            throw error
        }
        return (data, response)
    }
}

struct CoverImageClock: Sendable {
    let now: @Sendable () -> Date

    static let system = CoverImageClock(now: { Date() })
}

struct CoverImagePayload: Equatable, Sendable {
    let data: Data
    let mimeType: String

    init(data: Data, mimeType: String = "image/jpeg") {
        self.data = data
        self.mimeType = mimeType
    }
}

enum CoverImageStoreError: Error, Equatable {
    case disallowedURL
    case invalidResponse
    case httpStatus(Int)
    case unsupportedContentType(String?)
    case responseTooLarge
    case invalidImage
    case invalidDimensions
    case pixelCountExceeded
    case encodingFailed
}

private enum CoverImageRemoteURLPolicy {
    static let allowedHost = "covers.openlibrary.org"

    static func canonicalURL(_ url: URL) throws -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "https",
              components.host?.lowercased() == allowedHost,
              components.user == nil,
              components.password == nil,
              components.port == nil || components.port == 443 else {
            throw CoverImageStoreError.disallowedURL
        }
        components.scheme = "https"
        components.host = allowedHost
        // The default HTTPS port is semantically identical to an omitted port.
        // Removing it keeps cache keys and in-flight request identities stable.
        components.port = nil
        components.fragment = nil
        guard let canonicalURL = components.url else {
            throw CoverImageStoreError.disallowedURL
        }
        return canonicalURL
    }
}

final class CoverImageRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var didRejectRedirect = false

    var rejectedRedirect: Bool {
        lock.lock()
        defer { lock.unlock() }
        return didRejectRedirect
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let targetURL = request.url,
              (try? CoverImageRemoteURLPolicy.canonicalURL(targetURL)) != nil else {
            lock.lock()
            didRejectRedirect = true
            lock.unlock()
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}

/// A bounded, persistent cache for publication covers.
///
/// `cachedImage(for:)` never starts a network request and is suitable for list
/// rows. `image(for:)` may use the injected transport after both memory and disk
/// miss. All successful payloads leave the actor as metadata-free JPEG data.
actor CoverImageStore {
    struct Configuration: Sendable {
        static let maximumAllowedInputBytes = 5 * 1_024 * 1_024
        static let maximumAllowedOutputDimension = 1_200
        static let maximumAllowedDiskBytes = 100 * 1_024 * 1_024

        let maximumInputBytes: Int
        let maximumSourceDimension: Int
        let maximumSourcePixelCount: Int
        let maximumOutputDimension: Int
        let maximumMemoryBytes: Int
        let maximumDiskBytes: Int
        let maximumNegativeEntries: Int
        let negativeCacheLifetime: TimeInterval
        let requestTimeout: TimeInterval
        let jpegQuality: Double

        init(
            maximumInputBytes: Int = Configuration.maximumAllowedInputBytes,
            maximumSourceDimension: Int = 20_000,
            maximumSourcePixelCount: Int = 40_000_000,
            maximumOutputDimension: Int = Configuration.maximumAllowedOutputDimension,
            maximumMemoryBytes: Int = 20 * 1_024 * 1_024,
            maximumDiskBytes: Int = Configuration.maximumAllowedDiskBytes,
            maximumNegativeEntries: Int = 2_048,
            negativeCacheLifetime: TimeInterval = 24 * 60 * 60,
            requestTimeout: TimeInterval = 15,
            jpegQuality: Double = 0.86
        ) {
            self.maximumInputBytes = min(
                max(1, maximumInputBytes),
                Configuration.maximumAllowedInputBytes
            )
            self.maximumSourceDimension = max(1, maximumSourceDimension)
            self.maximumSourcePixelCount = max(1, maximumSourcePixelCount)
            self.maximumOutputDimension = min(
                max(1, maximumOutputDimension),
                Configuration.maximumAllowedOutputDimension
            )
            self.maximumMemoryBytes = max(0, maximumMemoryBytes)
            self.maximumDiskBytes = min(
                max(0, maximumDiskBytes),
                Configuration.maximumAllowedDiskBytes
            )
            self.maximumNegativeEntries = max(0, maximumNegativeEntries)
            self.negativeCacheLifetime = max(0, negativeCacheLifetime)
            self.requestTimeout = max(1, requestTimeout)
            self.jpegQuality = min(max(jpegQuality, 0.1), 1)
        }
    }

    private struct MemoryEntry: Sendable {
        let payload: CoverImagePayload
        var accessOrder: UInt64

        var cost: Int { payload.data.count }
    }

    private struct DiskEntry: Codable, Sendable {
        var byteCount: Int
        var accessOrder: UInt64
        var lastAccess: Date
        var negativeUntil: Date?

        var isNegative: Bool { negativeUntil != nil }
    }

    private struct DiskIndex: Codable, Sendable {
        static let currentVersion = 1

        var version: Int
        var accessCounter: UInt64
        var entries: [String: DiskEntry]
    }

    private struct InFlight: Sendable {
        let generation: UUID
        let task: Task<FetchOutcome, Error>
        var waiters: Set<UUID>
    }

    private enum FetchOutcome: Sendable {
        case image(CoverImagePayload)
        case notFound
    }

    private enum CachedLookup {
        case image(CoverImagePayload)
        case negative
        case miss
    }

    private static let indexFileName = "index.json"
    private static let acceptedMIMETypes = Set([
        "image/jpeg",
        "image/png",
        "image/webp"
    ])

    private let transport: any CoverImageTransport
    private let cacheDirectory: URL
    private let clock: CoverImageClock
    private let configuration: Configuration

    private var memoryEntries: [String: MemoryEntry] = [:]
    private var memoryByteCount = 0
    private var diskEntries: [String: DiskEntry]
    private var accessCounter: UInt64
    private var inFlight: [String: InFlight] = [:]

    init(
        transport: any CoverImageTransport = URLSessionCoverImageTransport(),
        cacheDirectory: URL? = nil,
        clock: CoverImageClock = .system,
        configuration: Configuration = Configuration()
    ) throws {
        let resolvedDirectory = try Self.prepareCacheDirectory(cacheDirectory)
        let loadedIndex = Self.loadIndex(from: resolvedDirectory)
        var entries = loadedIndex.entries
        var counter = loadedIndex.accessCounter

        Self.reconcileDisk(
            directory: resolvedDirectory,
            entries: &entries,
            accessCounter: &counter,
            now: clock.now(),
            configuration: configuration
        )

        self.transport = transport
        self.cacheDirectory = resolvedDirectory
        self.clock = clock
        self.configuration = configuration
        diskEntries = entries
        accessCounter = counter

        try? Self.persistIndex(
            directory: resolvedDirectory,
            entries: entries,
            accessCounter: counter
        )
    }

    /// Reads memory or the persistent cache without ever using the network.
    func cachedImage(for remoteURL: URL) async throws -> CoverImagePayload? {
        try Task.checkCancellation()
        let canonicalURL = try Self.canonicalRemoteURL(remoteURL)
        let key = Self.cacheKey(for: canonicalURL)

        switch cachedLookup(forKey: key) {
        case .image(let payload):
            return payload
        case .negative, .miss:
            return nil
        }
    }

    /// Reads cached data first and performs one coalesced request on a miss.
    /// A 404 is represented by `nil` and remembered for 24 hours by default.
    func image(for remoteURL: URL) async throws -> CoverImagePayload? {
        try Task.checkCancellation()
        let canonicalURL = try Self.canonicalRemoteURL(remoteURL)
        let key = Self.cacheKey(for: canonicalURL)

        switch cachedLookup(forKey: key) {
        case .image(let payload):
            return payload
        case .negative:
            return nil
        case .miss:
            break
        }

        let waiterID = UUID()
        let flight: InFlight

        if var existing = inFlight[key] {
            existing.waiters.insert(waiterID)
            inFlight[key] = existing
            flight = existing
        } else {
            let generation = UUID()
            let request = Self.request(for: canonicalURL, timeout: configuration.requestTimeout)
            let transport = self.transport
            let configuration = self.configuration
            let task = Task.detached(priority: Task.currentPriority) {
                try await Self.fetch(
                    request: request,
                    transport: transport,
                    configuration: configuration
                )
            }
            let created = InFlight(
                generation: generation,
                task: task,
                waiters: [waiterID]
            )
            inFlight[key] = created
            flight = created
        }

        return try await withTaskCancellationHandler {
            let outcome: FetchOutcome
            do {
                outcome = try await flight.task.value
            } catch is CancellationError {
                removeFlightIfCurrent(key: key, generation: flight.generation)
                throw CancellationError()
            } catch let error as URLError where error.code == .cancelled {
                removeFlightIfCurrent(key: key, generation: flight.generation)
                throw CancellationError()
            } catch {
                removeFlightIfCurrent(key: key, generation: flight.generation)
                throw error
            }

            if Task.isCancelled {
                cancelWaiter(
                    waiterID,
                    forKey: key,
                    generation: flight.generation
                )
                throw CancellationError()
            }

            return commit(
                outcome,
                forKey: key,
                generation: flight.generation
            )
        } onCancel: {
            Task {
                await self.cancelWaiter(
                    waiterID,
                    forKey: key,
                    generation: flight.generation
                )
            }
        }
    }

    private func cachedLookup(forKey key: String) -> CachedLookup {
        if var memoryEntry = memoryEntries[key] {
            let order = nextAccessOrder()
            memoryEntry.accessOrder = order
            memoryEntries[key] = memoryEntry
            touchDiskEntry(forKey: key, order: order)
            return .image(memoryEntry.payload)
        }

        guard let entry = diskEntries[key] else {
            return .miss
        }

        if let negativeUntil = entry.negativeUntil {
            guard negativeUntil > clock.now() else {
                diskEntries.removeValue(forKey: key)
                persistIndexBestEffort()
                return .miss
            }
            touchDiskEntry(forKey: key, order: nextAccessOrder())
            return .negative
        }

        let fileURL = imageFileURL(forKey: key)
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
              let fileByteCount = (attributes[.size] as? NSNumber)?.intValue,
              fileByteCount > 0,
              fileByteCount <= configuration.maximumInputBytes,
              let data = try? Data(contentsOf: fileURL, options: [.mappedIfSafe]),
              data.count == fileByteCount,
              Self.isValidCachedJPEG(data, configuration: configuration) else {
            diskEntries.removeValue(forKey: key)
            try? FileManager.default.removeItem(at: fileURL)
            persistIndexBestEffort()
            return .miss
        }

        let payload = CoverImagePayload(data: data)
        let order = nextAccessOrder()
        touchDiskEntry(forKey: key, order: order)
        insertIntoMemory(payload, forKey: key, accessOrder: order)
        return .image(payload)
    }

    private func commit(
        _ outcome: FetchOutcome,
        forKey key: String,
        generation: UUID
    ) -> CoverImagePayload? {
        guard inFlight[key]?.generation == generation else {
            switch outcome {
            case .image(let payload): return payload
            case .notFound: return nil
            }
        }

        inFlight.removeValue(forKey: key)

        switch outcome {
        case .image(let payload):
            store(payload, forKey: key)
            return payload
        case .notFound:
            storeNegativeResult(forKey: key)
            return nil
        }
    }

    private func cancelWaiter(
        _ waiterID: UUID,
        forKey key: String,
        generation: UUID
    ) {
        guard var flight = inFlight[key], flight.generation == generation else {
            return
        }

        flight.waiters.remove(waiterID)
        guard !flight.waiters.isEmpty else {
            flight.task.cancel()
            inFlight.removeValue(forKey: key)
            return
        }
        inFlight[key] = flight
    }

    private func removeFlightIfCurrent(key: String, generation: UUID) {
        guard inFlight[key]?.generation == generation else { return }
        inFlight.removeValue(forKey: key)
    }

    private func store(_ payload: CoverImagePayload, forKey key: String) {
        let order = nextAccessOrder()
        insertIntoMemory(payload, forKey: key, accessOrder: order)

        guard configuration.maximumDiskBytes > 0,
              payload.data.count <= configuration.maximumDiskBytes else {
            removeDiskEntry(forKey: key)
            persistIndexBestEffort()
            return
        }

        let fileURL = imageFileURL(forKey: key)
        do {
            try payload.data.write(to: fileURL, options: .atomic)
            diskEntries[key] = DiskEntry(
                byteCount: payload.data.count,
                accessOrder: order,
                lastAccess: clock.now(),
                negativeUntil: nil
            )
            trimDiskIfNeeded()
            persistIndexBestEffort()
        } catch {
            diskEntries.removeValue(forKey: key)
            try? FileManager.default.removeItem(at: fileURL)
            persistIndexBestEffort()
        }
    }

    private func storeNegativeResult(forKey key: String) {
        removeFromMemory(forKey: key)
        try? FileManager.default.removeItem(at: imageFileURL(forKey: key))

        guard configuration.maximumNegativeEntries > 0,
              configuration.negativeCacheLifetime > 0 else {
            diskEntries.removeValue(forKey: key)
            persistIndexBestEffort()
            return
        }

        let order = nextAccessOrder()
        diskEntries[key] = DiskEntry(
            byteCount: 0,
            accessOrder: order,
            lastAccess: clock.now(),
            negativeUntil: clock.now().addingTimeInterval(configuration.negativeCacheLifetime)
        )
        trimNegativeEntriesIfNeeded()
        persistIndexBestEffort()
    }

    private func insertIntoMemory(
        _ payload: CoverImagePayload,
        forKey key: String,
        accessOrder: UInt64
    ) {
        removeFromMemory(forKey: key)
        guard configuration.maximumMemoryBytes > 0,
              payload.data.count <= configuration.maximumMemoryBytes else {
            return
        }

        memoryEntries[key] = MemoryEntry(payload: payload, accessOrder: accessOrder)
        memoryByteCount += payload.data.count

        while memoryByteCount > configuration.maximumMemoryBytes,
              let victim = memoryEntries.min(by: Self.memoryLRUOrder)?.key {
            removeFromMemory(forKey: victim)
        }
    }

    private static func memoryLRUOrder(
        _ lhs: Dictionary<String, MemoryEntry>.Element,
        _ rhs: Dictionary<String, MemoryEntry>.Element
    ) -> Bool {
        if lhs.value.accessOrder != rhs.value.accessOrder {
            return lhs.value.accessOrder < rhs.value.accessOrder
        }
        return lhs.key < rhs.key
    }

    private func removeFromMemory(forKey key: String) {
        guard let removed = memoryEntries.removeValue(forKey: key) else { return }
        memoryByteCount -= removed.cost
    }

    private func removeDiskEntry(forKey key: String) {
        diskEntries.removeValue(forKey: key)
        try? FileManager.default.removeItem(at: imageFileURL(forKey: key))
    }

    private func trimDiskIfNeeded() {
        var total = diskEntries.values.reduce(into: 0) { partial, entry in
            if !entry.isNegative { partial += entry.byteCount }
        }

        while total > configuration.maximumDiskBytes {
            guard let victim = diskEntries
                .filter({ !$0.value.isNegative })
                .min(by: Self.diskLRUOrder) else {
                break
            }
            total -= victim.value.byteCount
            diskEntries.removeValue(forKey: victim.key)
            try? FileManager.default.removeItem(at: imageFileURL(forKey: victim.key))
        }
    }

    private func trimNegativeEntriesIfNeeded() {
        while diskEntries.values.lazy.filter(\.isNegative).count > configuration.maximumNegativeEntries {
            guard let victim = diskEntries
                .filter({ $0.value.isNegative })
                .min(by: Self.diskLRUOrder) else {
                break
            }
            diskEntries.removeValue(forKey: victim.key)
        }
    }

    private static func diskLRUOrder(
        _ lhs: Dictionary<String, DiskEntry>.Element,
        _ rhs: Dictionary<String, DiskEntry>.Element
    ) -> Bool {
        if lhs.value.accessOrder != rhs.value.accessOrder {
            return lhs.value.accessOrder < rhs.value.accessOrder
        }
        return lhs.key < rhs.key
    }

    private func touchDiskEntry(forKey key: String, order: UInt64) {
        guard var entry = diskEntries[key] else { return }
        entry.accessOrder = order
        entry.lastAccess = clock.now()
        diskEntries[key] = entry
        persistIndexBestEffort()
    }

    private func nextAccessOrder() -> UInt64 {
        if accessCounter == UInt64.max {
            renumberAccessOrders()
        }
        accessCounter += 1
        return accessCounter
    }

    private func renumberAccessOrders() {
        let sortedKeys = diskEntries.keys.sorted {
            let left = diskEntries[$0]?.accessOrder ?? 0
            let right = diskEntries[$1]?.accessOrder ?? 0
            return left == right ? $0 < $1 : left < right
        }
        accessCounter = 0
        for key in sortedKeys {
            accessCounter += 1
            diskEntries[key]?.accessOrder = accessCounter
        }

        let sortedMemoryKeys = memoryEntries.keys.sorted {
            let left = memoryEntries[$0]?.accessOrder ?? 0
            let right = memoryEntries[$1]?.accessOrder ?? 0
            return left == right ? $0 < $1 : left < right
        }
        for key in sortedMemoryKeys where memoryEntries[key]?.accessOrder == UInt64.max {
            memoryEntries[key]?.accessOrder = accessCounter
        }
    }

    private func imageFileURL(forKey key: String) -> URL {
        cacheDirectory.appendingPathComponent("\(key).jpg", isDirectory: false)
    }

    private func persistIndexBestEffort() {
        try? Self.persistIndex(
            directory: cacheDirectory,
            entries: diskEntries,
            accessCounter: accessCounter
        )
    }
}

private extension CoverImageStore {
    static func request(for url: URL, timeout: TimeInterval) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = timeout
        request.setValue("image/jpeg, image/png, image/webp", forHTTPHeaderField: "Accept")
        request.setValue(
            "HomeLibrary/0.2 (+https://github.com/lpociask/domowa-biblioteka)",
            forHTTPHeaderField: "User-Agent"
        )
        return request
    }

    private static func fetch(
        request: URLRequest,
        transport: any CoverImageTransport,
        configuration: Configuration
    ) async throws -> FetchOutcome {
        try Task.checkCancellation()
        let (data, response) = try await transport.data(for: request)
        try Task.checkCancellation()

        guard let httpResponse = response as? HTTPURLResponse else {
            throw CoverImageStoreError.invalidResponse
        }
        if let finalURL = httpResponse.url {
            _ = try canonicalRemoteURL(finalURL)
        } else {
            throw CoverImageStoreError.invalidResponse
        }

        if httpResponse.statusCode == 404 {
            return .notFound
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw CoverImageStoreError.httpStatus(httpResponse.statusCode)
        }

        if httpResponse.expectedContentLength > Int64(configuration.maximumInputBytes) {
            throw CoverImageStoreError.responseTooLarge
        }
        guard data.count <= configuration.maximumInputBytes else {
            throw CoverImageStoreError.responseTooLarge
        }

        let mimeType = normalizedMIMEType(httpResponse.mimeType)
        guard let mimeType, acceptedMIMETypes.contains(mimeType) else {
            throw CoverImageStoreError.unsupportedContentType(mimeType)
        }

        let sanitized = try sanitizedJPEG(
            from: data,
            declaredMIMEType: mimeType,
            configuration: configuration
        )
        try Task.checkCancellation()
        return .image(CoverImagePayload(data: sanitized))
    }

    static func sanitizedJPEG(
        from data: Data,
        declaredMIMEType: String,
        configuration: Configuration
    ) throws -> Data {
        guard let source = CGImageSourceCreateWithData(
            data as CFData,
            [kCGImageSourceShouldCache: false] as CFDictionary
        ), CGImageSourceGetCount(source) > 0 else {
            throw CoverImageStoreError.invalidImage
        }

        guard sourceType(CGImageSourceGetType(source), matches: declaredMIMEType) else {
            throw CoverImageStoreError.invalidImage
        }

        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              width > 0,
              height > 0 else {
            throw CoverImageStoreError.invalidDimensions
        }
        guard width <= configuration.maximumSourceDimension,
              height <= configuration.maximumSourceDimension else {
            throw CoverImageStoreError.invalidDimensions
        }

        let (pixelCount, overflow) = width.multipliedReportingOverflow(by: height)
        guard !overflow, pixelCount <= configuration.maximumSourcePixelCount else {
            throw CoverImageStoreError.pixelCountExceeded
        }

        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: configuration.maximumOutputDimension
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(
            source,
            0,
            thumbnailOptions as CFDictionary
        ), let opaqueThumbnail = opaqueImage(from: thumbnail) else {
            throw CoverImageStoreError.invalidImage
        }

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            throw CoverImageStoreError.encodingFailed
        }

        let outputProperties: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: configuration.jpegQuality
        ]
        CGImageDestinationAddImage(destination, opaqueThumbnail, outputProperties as CFDictionary)
        guard CGImageDestinationFinalize(destination), !output.isEmpty else {
            throw CoverImageStoreError.encodingFailed
        }
        return try removingJPEGMetadataSegments(
            from: output as Data,
            configuration: configuration
        )
    }

    /// ImageIO may add a minimal APP1 EXIF block containing output dimensions
    /// even when no source metadata is supplied. Removing APP1, APP13 and COM
    /// segments guarantees that the cached JPEG cannot carry EXIF/GPS/XMP/IPTC
    /// data while leaving the encoded pixel stream untouched.
    static func removingJPEGMetadataSegments(
        from data: Data,
        configuration: Configuration
    ) throws -> Data {
        let bytes = [UInt8](data)
        guard bytes.count >= 4, bytes[0] == 0xFF, bytes[1] == 0xD8 else {
            throw CoverImageStoreError.encodingFailed
        }

        var output = Data(bytes[0...1])
        var offset = 2

        while offset < bytes.count {
            let segmentStart = offset
            guard bytes[offset] == 0xFF else {
                throw CoverImageStoreError.encodingFailed
            }
            while offset < bytes.count, bytes[offset] == 0xFF {
                offset += 1
            }
            guard offset < bytes.count else {
                throw CoverImageStoreError.encodingFailed
            }

            let marker = bytes[offset]
            offset += 1

            if marker == 0xDA || marker == 0xD9 {
                output.append(contentsOf: bytes[segmentStart...])
                break
            }

            let isStandalone = marker == 0x01 || (0xD0...0xD7).contains(marker)
            if isStandalone {
                output.append(contentsOf: bytes[segmentStart..<offset])
                continue
            }

            guard offset + 1 < bytes.count else {
                throw CoverImageStoreError.encodingFailed
            }
            let declaredLength = (Int(bytes[offset]) << 8) | Int(bytes[offset + 1])
            guard declaredLength >= 2, offset + declaredLength <= bytes.count else {
                throw CoverImageStoreError.encodingFailed
            }
            let segmentEnd = offset + declaredLength
            let carriesMetadata = marker == 0xE1 || marker == 0xED || marker == 0xFE
            if !carriesMetadata {
                output.append(contentsOf: bytes[segmentStart..<segmentEnd])
            }
            offset = segmentEnd
        }

        guard isValidCachedJPEG(output, configuration: configuration) else {
            throw CoverImageStoreError.encodingFailed
        }
        return output
    }

    static func opaqueImage(from source: CGImage) -> CGImage? {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: source.width,
            height: source.height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else {
            return nil
        }

        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: source.width, height: source.height))
        context.draw(source, in: CGRect(x: 0, y: 0, width: source.width, height: source.height))
        return context.makeImage()
    }

    static func sourceType(_ type: CFString?, matches mimeType: String) -> Bool {
        guard let identifier = type as String? else { return false }
        switch mimeType {
        case "image/jpeg":
            return identifier == UTType.jpeg.identifier
        case "image/png":
            return identifier == UTType.png.identifier
        case "image/webp":
            return identifier == "org.webmproject.webp"
        default:
            return false
        }
    }

    static func normalizedMIMEType(_ value: String?) -> String? {
        value?
            .split(separator: ";", maxSplits: 1, omittingEmptySubsequences: true)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    static func isValidCachedJPEG(
        _ data: Data,
        configuration: Configuration
    ) -> Bool {
        guard !data.isEmpty,
              data.count <= configuration.maximumInputBytes,
              let source = CGImageSourceCreateWithData(
                  data as CFData,
                  [kCGImageSourceShouldCache: false] as CFDictionary
              ), CGImageSourceGetCount(source) == 1,
              CGImageSourceGetType(source) as String? == UTType.jpeg.identifier,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              width > 0,
              height > 0,
              width <= configuration.maximumOutputDimension,
              height <= configuration.maximumOutputDimension else {
            return false
        }

        let (pixelCount, overflow) = width.multipliedReportingOverflow(by: height)
        let (maximumOutputPixelCount, maximumOverflow) = configuration.maximumOutputDimension
            .multipliedReportingOverflow(by: configuration.maximumOutputDimension)
        guard !overflow,
              !maximumOverflow,
              pixelCount <= maximumOutputPixelCount,
              pixelCount <= configuration.maximumSourcePixelCount else {
            return false
        }

        return CGImageSourceCreateImageAtIndex(
            source,
            0,
            [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
        ) != nil
    }

    static func canonicalRemoteURL(_ url: URL) throws -> URL {
        try CoverImageRemoteURLPolicy.canonicalURL(url)
    }

    static func cacheKey(for url: URL) -> String {
        SHA256.hash(data: Data(url.absoluteString.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    static func prepareCacheDirectory(_ injectedDirectory: URL?) throws -> URL {
        let directory: URL
        if let injectedDirectory {
            directory = injectedDirectory
        } else {
            let applicationSupport = try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            directory = applicationSupport
                .appendingPathComponent("HomeLibrary", isDirectory: true)
                .appendingPathComponent("CoverCache", isDirectory: true)
        }

        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        var mutableDirectory = directory
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        try mutableDirectory.setResourceValues(resourceValues)
        return directory
    }

    private static func loadIndex(from directory: URL) -> DiskIndex {
        let indexURL = directory.appendingPathComponent(indexFileName, isDirectory: false)
        guard let data = try? Data(contentsOf: indexURL),
              let decoded = try? JSONDecoder().decode(DiskIndex.self, from: data),
              decoded.version == DiskIndex.currentVersion else {
            return DiskIndex(
                version: DiskIndex.currentVersion,
                accessCounter: 0,
                entries: [:]
            )
        }
        return decoded
    }

    private static func persistIndex(
        directory: URL,
        entries: [String: DiskEntry],
        accessCounter: UInt64
    ) throws {
        let index = DiskIndex(
            version: DiskIndex.currentVersion,
            accessCounter: accessCounter,
            entries: entries
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(index)
        try data.write(
            to: directory.appendingPathComponent(indexFileName, isDirectory: false),
            options: .atomic
        )
    }

    private static func reconcileDisk(
        directory: URL,
        entries: inout [String: DiskEntry],
        accessCounter: inout UInt64,
        now: Date,
        configuration: Configuration
    ) {
        let fileManager = FileManager.default
        let validKeyCharacters = CharacterSet(charactersIn: "0123456789abcdef")

        for (key, entry) in entries {
            let isValidKey = key.count == 64 &&
                key.unicodeScalars.allSatisfy(validKeyCharacters.contains)
            guard isValidKey else {
                entries.removeValue(forKey: key)
                continue
            }

            if let negativeUntil = entry.negativeUntil {
                if negativeUntil <= now {
                    entries.removeValue(forKey: key)
                }
                continue
            }

            let fileURL = directory.appendingPathComponent("\(key).jpg", isDirectory: false)
            guard let attributes = try? fileManager.attributesOfItem(atPath: fileURL.path),
                  let byteCount = (attributes[.size] as? NSNumber)?.intValue,
                  byteCount > 0,
                  byteCount <= configuration.maximumInputBytes else {
                entries.removeValue(forKey: key)
                try? fileManager.removeItem(at: fileURL)
                continue
            }
            entries[key]?.byteCount = byteCount
            accessCounter = max(accessCounter, entry.accessOrder)
        }

        let positiveKeys = Set(entries.compactMap { $0.value.isNegative ? nil : $0.key })
        if let files = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) {
            for file in files where file.pathExtension.lowercased() == "jpg" {
                guard !positiveKeys.contains(file.deletingPathExtension().lastPathComponent) else {
                    continue
                }
                try? fileManager.removeItem(at: file)
            }
        }

        trimDiskEntries(
            directory: directory,
            entries: &entries,
            maximumBytes: configuration.maximumDiskBytes
        )
        trimNegativeEntries(
            entries: &entries,
            maximumCount: configuration.maximumNegativeEntries
        )
    }

    private static func trimDiskEntries(
        directory: URL,
        entries: inout [String: DiskEntry],
        maximumBytes: Int
    ) {
        var total = entries.values.reduce(into: 0) { partial, entry in
            if !entry.isNegative { partial += entry.byteCount }
        }

        while total > maximumBytes {
            guard let victim = entries
                .filter({ !$0.value.isNegative })
                .min(by: diskLRUOrder) else {
                break
            }
            total -= victim.value.byteCount
            entries.removeValue(forKey: victim.key)
            try? FileManager.default.removeItem(
                at: directory.appendingPathComponent("\(victim.key).jpg", isDirectory: false)
            )
        }
    }

    private static func trimNegativeEntries(
        entries: inout [String: DiskEntry],
        maximumCount: Int
    ) {
        while entries.values.lazy.filter(\.isNegative).count > maximumCount {
            guard let victim = entries
                .filter({ $0.value.isNegative })
                .min(by: diskLRUOrder) else {
                break
            }
            entries.removeValue(forKey: victim.key)
        }
    }
}
