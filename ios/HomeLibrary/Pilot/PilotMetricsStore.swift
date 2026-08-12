import Foundation

enum PilotMetricsStoreError: Error, Equatable {
    case sequenceExhausted
    case storageLimitTooSmall
}

struct PilotMetricsStatus: Equatable, Sendable {
    let enabled: Bool
    let retainedEventCount: Int
    let lastSequence: UInt64?
    let hasQuarantinedFile: Bool
}

/// Local, opt-in storage for privacy-safe pilot measurements.
///
/// It is independent from SwiftData and from the collection export format.
/// Recording is a no-op until `setEnabled(true)` succeeds.
actor PilotMetricsStore {
    static let maximumEventCount = 5_000
    static let maximumByteCount: Int64 = 1 * 1_024 * 1_024
    static let maximumEventByteCount = 4 * 1_024
    static let absoluteMaximumEventCount = 20_000
    static let absoluteMaximumByteCount: Int64 = 4 * 1_024 * 1_024
    static let stateFileName = "metrics-v1.json"
    static let quarantineFileName = "metrics-v1.corrupt.json"

    nonisolated static var defaultDirectoryURL: URL {
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory

        return applicationSupport
            .appendingPathComponent("HomeLibrary", isDirectory: true)
            .appendingPathComponent("Pilot", isDirectory: true)
    }

    private let directoryURL: URL
    private let stateFileURL: URL
    private let quarantineFileURL: URL
    private let maximumEvents: Int
    private let maximumBytes: Int64
    private let dayOrdinal: @Sendable () -> Int
    private let fileManager: FileManager

    private var enabled: Bool
    private var anchorDayOrdinal: Int
    private var nextSequence: UInt64
    private var records: [PilotMetricRecord]

    init(
        directoryURL: URL = PilotMetricsStore.defaultDirectoryURL,
        maximumEventCount: Int = PilotMetricsStore.maximumEventCount,
        maximumByteCount: Int64 = PilotMetricsStore.maximumByteCount,
        dayOrdinal: @escaping @Sendable () -> Int = {
            Int(floor(Date().timeIntervalSince1970 / 86_400))
        },
        fileManager: FileManager = .default
    ) {
        self.directoryURL = directoryURL
        stateFileURL = directoryURL.appendingPathComponent(Self.stateFileName, isDirectory: false)
        quarantineFileURL = directoryURL.appendingPathComponent(
            Self.quarantineFileName,
            isDirectory: false
        )
        maximumEvents = min(
            max(0, maximumEventCount),
            Self.absoluteMaximumEventCount
        )
        maximumBytes = min(
            max(0, maximumByteCount),
            Self.absoluteMaximumByteCount
        )
        self.dayOrdinal = dayOrdinal
        self.fileManager = fileManager

        let fallbackDay = dayOrdinal()
        if let loaded = Self.loadState(
            from: stateFileURL,
            quarantineURL: quarantineFileURL,
            maximumEventCount: maximumEvents,
            maximumByteCount: maximumBytes,
            fileManager: fileManager
        ) {
            enabled = loaded.enabled
            anchorDayOrdinal = loaded.anchorDayOrdinal
            nextSequence = loaded.nextSequence
            records = loaded.records
        } else {
            enabled = false
            anchorDayOrdinal = fallbackDay
            nextSequence = 1
            records = []
        }
    }

    func status() -> PilotMetricsStatus {
        PilotMetricsStatus(
            enabled: enabled,
            retainedEventCount: records.count,
            lastSequence: records.last?.sequence,
            hasQuarantinedFile: fileManager.fileExists(atPath: quarantineFileURL.path)
        )
    }

    /// Returns true only when the preference actually changed.
    @discardableResult
    func setEnabled(_ newValue: Bool) throws -> Bool {
        guard enabled != newValue else { return false }

        var candidate = diskState
        candidate.enabled = newValue
        if newValue, candidate.records.isEmpty {
            candidate.anchorDayOrdinal = dayOrdinal()
            candidate.nextSequence = 1
        }

        let data = try encodedWithinLimit(candidate)
        try persist(data)
        apply(candidate)
        return true
    }

    /// Records one closed event, or returns false without touching disk when disabled.
    @discardableResult
    func record(_ event: PilotMetricEvent) throws -> Bool {
        guard enabled else { return false }
        guard nextSequence < UInt64.max else {
            throw PilotMetricsStoreError.sequenceExhausted
        }
        guard try Self.encoder.encode(event).count <= Self.maximumEventByteCount else {
            throw PilotMetricsStoreError.storageLimitTooSmall
        }

        let currentDay = dayOrdinal()
        let relativeDay = max(0, currentDay - anchorDayOrdinal)
        let boundedRelativeDay = UInt32(
            min(relativeDay, Int(UInt32.max))
        )
        let nondecreasingDay = max(records.last?.dayIndex ?? 0, boundedRelativeDay)
        let insertedSequence = nextSequence

        var candidate = diskState
        candidate.records.append(
            PilotMetricRecord(
                sequence: insertedSequence,
                dayIndex: nondecreasingDay,
                event: event
            )
        )
        candidate.nextSequence += 1

        if candidate.records.count > maximumEvents {
            candidate.records.removeFirst(candidate.records.count - maximumEvents)
        }

        var data = try Self.encoder.encode(candidate)
        while Int64(data.count) > maximumBytes, !candidate.records.isEmpty {
            candidate.records.removeFirst()
            data = try Self.encoder.encode(candidate)
        }

        guard candidate.records.contains(where: { $0.sequence == insertedSequence }),
              Int64(data.count) <= maximumBytes else {
            throw PilotMetricsStoreError.storageLimitTooSmall
        }

        try persist(data)
        apply(candidate)
        return true
    }

    func report() -> PilotReport {
        PilotReportBuilder.build(from: records)
    }

    /// Exports aggregates only. There is intentionally no raw-record export API.
    func exportAggregates(_ format: PilotAggregateExportFormat) throws -> Data {
        let currentReport = PilotReportBuilder.build(from: records)
        switch format {
        case .json:
            return try PilotReportBuilder.jsonData(for: currentReport)
        case .csv:
            return PilotReportBuilder.csvData(for: currentReport)
        }
    }

    /// Clears measurements while preserving the current opt-in preference.
    /// Calling it repeatedly is safe and has the same result.
    func reset() throws {
        try clearQuarantine()

        if enabled {
            let candidate = DiskState(
                schemaVersion: DiskState.currentSchemaVersion,
                enabled: true,
                anchorDayOrdinal: dayOrdinal(),
                nextSequence: 1,
                records: []
            )
            let data = try encodedWithinLimit(candidate)
            try persist(data)
            apply(candidate)
        } else {
            if fileManager.fileExists(atPath: stateFileURL.path) {
                try fileManager.removeItem(at: stateFileURL)
            }
            anchorDayOrdinal = dayOrdinal()
            nextSequence = 1
            records = []
        }
    }

    func clearQuarantine() throws {
        if fileManager.fileExists(atPath: quarantineFileURL.path) {
            try fileManager.removeItem(at: quarantineFileURL)
        }
    }

    private var diskState: DiskState {
        DiskState(
            schemaVersion: DiskState.currentSchemaVersion,
            enabled: enabled,
            anchorDayOrdinal: anchorDayOrdinal,
            nextSequence: nextSequence,
            records: records
        )
    }

    private func encodedWithinLimit(_ state: DiskState) throws -> Data {
        let data = try Self.encoder.encode(state)
        guard state.records.count <= maximumEvents,
              Int64(data.count) <= maximumBytes else {
            throw PilotMetricsStoreError.storageLimitTooSmall
        }
        return data
    }

    private func persist(_ data: Data) throws {
        guard Int64(data.count) <= maximumBytes else {
            throw PilotMetricsStoreError.storageLimitTooSmall
        }
        try prepareDirectory()
        try data.write(to: stateFileURL, options: .atomic)
        try Self.secureAndExcludeFromBackup(stateFileURL, fileManager: fileManager)
    }

    private func prepareDirectory() throws {
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
        try Self.secureAndExcludeFromBackup(directoryURL, fileManager: fileManager)
    }

    private func apply(_ state: DiskState) {
        enabled = state.enabled
        anchorDayOrdinal = state.anchorDayOrdinal
        nextSequence = state.nextSequence
        records = state.records
    }

    private static func loadState(
        from fileURL: URL,
        quarantineURL: URL,
        maximumEventCount: Int,
        maximumByteCount: Int64,
        fileManager: FileManager
    ) -> DiskState? {
        guard fileManager.fileExists(atPath: fileURL.path) else { return nil }

        do {
            let attributes = try fileManager.attributesOfItem(atPath: fileURL.path)
            guard let byteCount = (attributes[.size] as? NSNumber)?.int64Value,
                  byteCount > 0,
                  byteCount <= maximumByteCount else {
                throw StoragePayloadError.invalid
            }

            let data = try Data(contentsOf: fileURL, options: .mappedIfSafe)
            let state = try decoder.decode(DiskState.self, from: data)
            guard state.isValid(maximumEventCount: maximumEventCount) else {
                throw StoragePayloadError.invalid
            }
            try secureAndExcludeFromBackup(
                fileURL.deletingLastPathComponent(),
                fileManager: fileManager
            )
            try secureAndExcludeFromBackup(fileURL, fileManager: fileManager)
            return state
        } catch {
            quarantine(
                fileURL,
                at: quarantineURL,
                fileManager: fileManager
            )
            return nil
        }
    }

    private static func quarantine(
        _ fileURL: URL,
        at quarantineURL: URL,
        fileManager: FileManager
    ) {
        guard fileManager.fileExists(atPath: fileURL.path) else { return }
        do {
            if fileManager.fileExists(atPath: quarantineURL.path) {
                try fileManager.removeItem(at: quarantineURL)
            }
            try fileManager.moveItem(at: fileURL, to: quarantineURL)
            try secureAndExcludeFromBackup(
                quarantineURL.deletingLastPathComponent(),
                fileManager: fileManager
            )
            try secureAndExcludeFromBackup(quarantineURL, fileManager: fileManager)
        } catch {
            // Never leave an unreadable payload active. If quarantine fails,
            // clearing the active file is safer than repeatedly decoding it.
            try? fileManager.removeItem(at: fileURL)
            try? fileManager.removeItem(at: quarantineURL)
        }
    }

    private static func secureAndExcludeFromBackup(
        _ url: URL,
        fileManager: FileManager
    ) throws {
        var mutableURL = url
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        try mutableURL.setResourceValues(resourceValues)

        #if os(iOS) && !targetEnvironment(simulator)
        try fileManager.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: url.path
        )
        #endif
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    private static var decoder: JSONDecoder { JSONDecoder() }
}

private struct DiskState: Codable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    var enabled: Bool
    var anchorDayOrdinal: Int
    var nextSequence: UInt64
    var records: [PilotMetricRecord]

    func isValid(maximumEventCount: Int) -> Bool {
        guard schemaVersion == Self.currentSchemaVersion,
              records.count <= maximumEventCount,
              nextSequence > 0 else {
            return false
        }

        var previousSequence: UInt64?
        var previousDay: UInt32?
        for record in records {
            guard let eventData = try? JSONEncoder().encode(record.event),
                  eventData.count <= PilotMetricsStore.maximumEventByteCount else {
                return false
            }
            if let previousSequence, record.sequence <= previousSequence {
                return false
            }
            if let previousDay, record.dayIndex < previousDay {
                return false
            }
            previousSequence = record.sequence
            previousDay = record.dayIndex
        }

        guard let lastSequence = records.last?.sequence else {
            return nextSequence == 1
        }
        return lastSequence < nextSequence
    }
}

private enum StoragePayloadError: Error {
    case invalid
}
