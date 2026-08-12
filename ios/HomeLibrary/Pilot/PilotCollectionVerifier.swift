import Foundation

/// Coarse, privacy-safe reasons why a restored collection differs from the
/// original export. The raw value is intentionally the only encoded form: a
/// report can never carry titles, identifiers, locations, notes or JSON.
struct PilotCollectionMismatchCategories: OptionSet, Codable, Equatable, Sendable {
    let rawValue: UInt8

    static let schema = Self(rawValue: 1 << 0)
    static let count = Self(rawValue: 1 << 1)
    static let publicationIdentity = Self(rawValue: 1 << 2)
    static let copyIdentity = Self(rawValue: 1 << 3)
    static let locationGraph = Self(rawValue: 1 << 4)
    static let metadata = Self(rawValue: 1 << 5)

    init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(rawValue: try container.decode(UInt8.self))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

enum PilotCollectionVerificationOutcome: String, Codable, Equatable, Sendable {
    case verified
    case mismatched
    case originalTooLarge
    case restoredTooLarge
    case invalidOriginal
    case invalidRestored
}

/// Counts are safe to persist in the pilot report. They contain no stable IDs
/// and no values copied from a user's collection.
struct PilotCollectionRecordCounts: Codable, Equatable, Sendable {
    let locations: Int
    let publications: Int
    let ownedItems: Int
}

/// The complete public result of a verification. Raw collection data and
/// validation errors are deliberately discarded before this value is built.
struct PilotCollectionVerificationReport: Codable, Equatable, Sendable {
    let outcome: PilotCollectionVerificationOutcome
    let mismatches: PilotCollectionMismatchCategories
    let originalCounts: PilotCollectionRecordCounts?
    let restoredCounts: PilotCollectionRecordCounts?

    var isVerified: Bool {
        outcome == .verified && mismatches.isEmpty
    }
}

/// Read-only, in-memory comparison of two canonical collection v1 documents.
///
/// Both inputs first pass the production importer's strict size, schema, date,
/// identity, reference and location-graph validation. The verifier never owns
/// or receives a `ModelContext`, so it cannot mutate the user's collection.
/// Array order and `exportedAt` are ignored; all other supported v1 semantics
/// are compared. Unknown extension fields remain forward-compatible and are
/// ignored in the same way as the production importer.
enum PilotCollectionVerifier {
    static let maximumFileSizeBytes = 25 * 1_048_576

    static func verify(
        original originalData: Data,
        restored restoredData: Data
    ) -> PilotCollectionVerificationReport {
        guard originalData.count <= maximumFileSizeBytes else {
            return failure(.originalTooLarge)
        }
        guard restoredData.count <= maximumFileSizeBytes else {
            return failure(.restoredTooLarge)
        }

        let original: CanonicalCollection
        do {
            original = try decodeAndValidate(originalData)
        } catch {
            return failure(.invalidOriginal, mismatches: .schema)
        }

        let originalCounts = original.recordCounts
        let restored: CanonicalCollection
        do {
            restored = try decodeAndValidate(restoredData)
        } catch {
            return PilotCollectionVerificationReport(
                outcome: .invalidRestored,
                mismatches: .schema,
                originalCounts: originalCounts,
                restoredCounts: nil
            )
        }

        let restoredCounts = restored.recordCounts
        let mismatches = compare(original: original, restored: restored)
        return PilotCollectionVerificationReport(
            outcome: mismatches.isEmpty ? .verified : .mismatched,
            mismatches: mismatches,
            originalCounts: originalCounts,
            restoredCounts: restoredCounts
        )
    }

    private static func failure(
        _ outcome: PilotCollectionVerificationOutcome,
        mismatches: PilotCollectionMismatchCategories = []
    ) -> PilotCollectionVerificationReport {
        PilotCollectionVerificationReport(
            outcome: outcome,
            mismatches: mismatches,
            originalCounts: nil,
            restoredCounts: nil
        )
    }

    private static func decodeAndValidate(_ data: Data) throws -> CanonicalCollection {
        // This is a read-only operation. It validates exactly the same
        // canonical v1 contract as a real import but never calls `apply`.
        _ = try CollectionImporter.prepare(data: data)
        return try JSONDecoder().decode(CanonicalCollection.self, from: data)
    }

    private static func compare(
        original: CanonicalCollection,
        restored: CanonicalCollection
    ) -> PilotCollectionMismatchCategories {
        var result: PilotCollectionMismatchCategories = []

        if original.schemaVersion != restored.schemaVersion {
            result.insert(.schema)
        }
        if original.recordCounts != restored.recordCounts {
            result.insert(.count)
        }

        let originalPublications = original.publicationsByID
        let restoredPublications = restored.publicationsByID
        let originalPublicationIDs = Set(originalPublications.keys)
        let restoredPublicationIDs = Set(restoredPublications.keys)
        if originalPublicationIDs != restoredPublicationIDs {
            result.insert(.publicationIdentity)
        }

        let originalCopies = original.copiesByID
        let restoredCopies = restored.copiesByID
        let originalCopyIDs = Set(originalCopies.keys)
        let restoredCopyIDs = Set(restoredCopies.keys)
        if originalCopyIDs != restoredCopyIDs {
            result.insert(.copyIdentity)
        }
        for id in originalCopyIDs.intersection(restoredCopyIDs) {
            guard let originalCopy = originalCopies[id],
                  let restoredCopy = restoredCopies[id] else { continue }
            if originalCopy.publicationID != restoredCopy.publicationID {
                result.insert(.copyIdentity)
            }
        }

        let originalLocations = original.locationGraph
        let restoredLocations = restored.locationGraph
        if originalLocations.locationsByID != restoredLocations.locationsByID {
            result.insert(.locationGraph)
        }
        for id in originalCopyIDs.intersection(restoredCopyIDs) {
            if originalLocations.copyLocationsByID[id] != restoredLocations.copyLocationsByID[id] {
                result.insert(.locationGraph)
            }
        }

        if original.collectionMetadata != restored.collectionMetadata {
            result.insert(.metadata)
        }
        for id in originalPublicationIDs.intersection(restoredPublicationIDs) {
            guard let originalPublication = originalPublications[id],
                  let restoredPublication = restoredPublications[id] else { continue }
            if originalPublication.metadata != restoredPublication.metadata {
                result.insert(.metadata)
            }
        }
        for id in originalCopyIDs.intersection(restoredCopyIDs) {
            guard let originalCopy = originalCopies[id],
                  let restoredCopy = restoredCopies[id] else { continue }
            if originalCopy.metadata != restoredCopy.metadata {
                result.insert(.metadata)
            }
        }

        return result
    }
}

// MARK: - Private canonical comparison model

private struct CanonicalCollection: Decodable {
    let schemaVersion: Int
    let exportedAt: String
    let collection: CanonicalCollectionMetadata
    let locations: [CanonicalLocation]
    let publications: [CanonicalPublication]
    let ownedItems: [CanonicalOwnedItem]

    var recordCounts: PilotCollectionRecordCounts {
        PilotCollectionRecordCounts(
            locations: locations.count,
            publications: publications.count,
            ownedItems: ownedItems.count
        )
    }

    var collectionMetadata: ComparableCollectionMetadata {
        ComparableCollectionMetadata(
            id: collection.id.pilotTrimmed,
            name: collection.name.pilotTrimmed
        )
    }

    var publicationsByID: [String: ComparablePublication] {
        Dictionary(uniqueKeysWithValues: publications.map { publication in
            let id = publication.id.pilotTrimmed
            return (id, ComparablePublication(source: publication))
        })
    }

    var copiesByID: [String: ComparableCopy] {
        Dictionary(uniqueKeysWithValues: ownedItems.map { item in
            let id = item.id.pilotTrimmed
            return (id, ComparableCopy(source: item))
        })
    }

    var locationGraph: ComparableLocationGraph {
        ComparableLocationGraph(
            locationsByID: Dictionary(uniqueKeysWithValues: locations.map { location in
                let id = location.id.pilotTrimmed
                return (id, ComparableLocation(source: location))
            }),
            copyLocationsByID: Dictionary(uniqueKeysWithValues: ownedItems.map { item in
                let id = item.id.pilotTrimmed
                return (id, ComparableCopyLocation(source: item))
            })
        )
    }
}

private struct CanonicalCollectionMetadata: Decodable {
    let id: String
    let name: String
}

private struct CanonicalLocation: Decodable {
    let id: String
    let name: String
    let type: String
    let parentId: String?
}

private struct CanonicalPublication: Decodable {
    let id: String
    let type: String
    let title: String
    let subtitle: String?
    let authors: [String]
    let language: String?
    let publisher: String?
    let publicationYear: Int?
    let identifiers: CanonicalIdentifiers
    let issue: CanonicalIssue?
    let metadata: CanonicalBibliographicMetadata?
    let createdAt: String
    let updatedAt: String
}

private struct CanonicalIdentifiers: Decodable, Equatable {
    let isbn13: String?
    let issn: String?
    let ean: String?
    let barcode: String?
}

private struct CanonicalIssue: Decodable, Equatable {
    let number: String?
    let volume: String?
    let date: String?
}

private struct CanonicalBibliographicMetadata: Decodable, Equatable {
    private enum CodingKeys: String, CodingKey {
        case source
        case coverUrl
        case coverSource
    }

    let source: String?
    let coverUrl: String?
    let coverSource: String?

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        source = try container.decodeIfPresent(String.self, forKey: .source)
        coverUrl = (try? container.decodeIfPresent(String.self, forKey: .coverUrl)) ?? nil
        coverSource = (try? container.decodeIfPresent(String.self, forKey: .coverSource)) ?? nil
    }
}

private struct CanonicalOwnedItem: Decodable {
    let id: String
    let publicationId: String
    let locationId: String?
    let locationPath: [String]
    let status: String
    let notes: String?
    let addedAt: String
    let updatedAt: String
}

private struct ComparableCollectionMetadata: Equatable {
    let id: String
    let name: String
}

private struct ComparablePublication: Equatable {
    let metadata: ComparablePublicationMetadata

    init(source: CanonicalPublication) {
        metadata = ComparablePublicationMetadata(source: source)
    }
}

private struct ComparablePublicationMetadata: Equatable {
    let type: String
    let title: String
    let subtitle: String?
    let authors: [String]
    let language: String?
    let publisher: String?
    let publicationYear: Int?
    let identifiers: ComparableIdentifiers
    let issue: ComparableIssue?
    let metadata: ComparableBibliographicMetadata
    let createdAt: String
    let updatedAt: String

    init(source: CanonicalPublication) {
        type = source.type
        title = source.title.pilotTrimmed
        subtitle = source.subtitle.pilotNilIfBlank
        authors = source.authors.map(\.pilotTrimmed)
        language = source.language.pilotNilIfBlank
        publisher = source.publisher.pilotNilIfBlank
        publicationYear = source.publicationYear
        identifiers = ComparableIdentifiers(source: source.identifiers)

        if source.type == PublicationType.periodical.rawValue {
            issue = ComparableIssue(source: source.issue)
        } else {
            // The production exporter does not serialize issue fields for books.
            issue = nil
        }

        metadata = ComparableBibliographicMetadata(source: source.metadata)
        createdAt = source.createdAt
        updatedAt = source.updatedAt
    }
}

private struct ComparableIdentifiers: Equatable {
    let isbn13: String?
    let issn: String?
    let ean: String?
    let barcode: String?

    init(source: CanonicalIdentifiers) {
        isbn13 = source.isbn13.pilotNilIfBlank
        issn = source.issn.pilotNilIfBlank
        ean = source.ean.pilotNilIfBlank
        barcode = source.barcode.pilotNilIfBlank
    }
}

private struct ComparableIssue: Equatable {
    let number: String?
    let volume: String?
    let date: String?

    init(source: CanonicalIssue?) {
        number = (source?.number).pilotNilIfBlank
        volume = (source?.volume).pilotNilIfBlank
        date = (source?.date).pilotNilIfBlank
    }
}

private struct ComparableBibliographicMetadata: Equatable {
    let source: String
    let coverURL: String?
    let coverSource: String?

    init(source: CanonicalBibliographicMetadata?) {
        self.source = (source?.source).pilotNilIfBlank ?? "import"
        let coverReference = (source?.coverUrl).pilotNilIfBlank
        let normalizedCoverURL: String?
        if let coverReference,
           let validatedURL = RemoteCoverURLPolicy.validatedReference(coverReference) {
            normalizedCoverURL = validatedURL.absoluteString
        } else {
            normalizedCoverURL = nil
        }
        coverURL = normalizedCoverURL
        coverSource = normalizedCoverURL == nil ? nil : (source?.coverSource).pilotNilIfBlank
    }
}

private struct ComparableCopy: Equatable {
    let publicationID: String
    let metadata: ComparableCopyMetadata

    init(source: CanonicalOwnedItem) {
        publicationID = source.publicationId.pilotTrimmed
        metadata = ComparableCopyMetadata(source: source)
    }
}

private struct ComparableCopyMetadata: Equatable {
    let status: String
    let notes: String?
    let addedAt: String
    let updatedAt: String

    init(source: CanonicalOwnedItem) {
        status = source.status
        notes = source.notes.pilotNilIfBlank
        addedAt = source.addedAt
        updatedAt = source.updatedAt
    }
}

private struct ComparableLocationGraph: Equatable {
    let locationsByID: [String: ComparableLocation]
    let copyLocationsByID: [String: ComparableCopyLocation]
}

private struct ComparableLocation: Equatable {
    let name: String
    let type: String
    let parentID: String?

    init(source: CanonicalLocation) {
        name = source.name.pilotTrimmed
        type = source.type
        parentID = source.parentId.pilotNilIfBlank
    }
}

private struct ComparableCopyLocation: Equatable {
    let locationID: String?
    let locationPath: [String]

    init(source: CanonicalOwnedItem) {
        locationID = source.locationId.pilotNilIfBlank
        locationPath = source.locationPath.map(\.pilotTrimmed)
    }
}

private extension Optional where Wrapped == String {
    var pilotNilIfBlank: String? {
        flatMap { value in
            let trimmed = value.pilotTrimmed
            return trimmed.isEmpty ? nil : trimmed
        }
    }
}

private extension String {
    var pilotTrimmed: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
