import CryptoKit
import Foundation
import SwiftUI
import UniformTypeIdentifiers

struct CollectionExport: Codable {
    let schemaVersion: Int
    let exportedAt: Date
    let collection: ExportCollection
    let locations: [ExportLocation]
    let publications: [ExportPublication]
    let ownedItems: [ExportOwnedItem]
}

struct ExportCollection: Codable {
    let id: String
    let name: String
}

struct ExportLocation: Codable, Equatable {
    let id: String
    let name: String
    let type: String
    let parentId: String?
}

struct ExportPublication: Codable {
    let id: String
    let type: String
    let title: String
    let subtitle: String?
    let authors: [String]
    let language: String?
    let publisher: String?
    let publicationYear: Int?
    let identifiers: ExportIdentifiers
    let issue: ExportIssue?
    let metadata: ExportMetadata?
    let createdAt: Date
    let updatedAt: Date
}

struct ExportIdentifiers: Codable {
    let isbn13: String?
    let issn: String?
    let ean: String?
    let barcode: String?
}

struct ExportIssue: Codable {
    let number: String?
    let volume: String?
    let date: String?
}

struct ExportMetadata: Codable {
    let source: String
    let coverUrl: String?
    let coverSource: String?
}

struct ExportOwnedItem: Codable {
    let id: String
    let publicationId: String
    let locationId: String?
    let locationPath: [String]
    let status: String
    let notes: String?
    let addedAt: Date
    let updatedAt: Date
}

enum CollectionExporter {
    static func makeExport(
        items: [OwnedItem],
        collectionID: String,
        collectionName: String,
        exportedAt: Date = .now
    ) -> CollectionExport {
        let locationResult = makeLocations(for: items)
        var publicationsByID: [UUID: ExportPublication] = [:]

        let exportedItems = items.compactMap { item -> ExportOwnedItem? in
            guard let publication = item.publication else { return nil }
            publicationsByID[publication.id] = export(publication)
            let path = item.locationPath
            let key = canonicalPath(path)

            return ExportOwnedItem(
                id: item.exportID,
                publicationId: publication.exportID,
                locationId: locationResult.leafIDs[key],
                locationPath: path,
                status: item.status.rawValue,
                notes: nilIfEmpty(item.notes),
                addedAt: item.addedAt,
                updatedAt: item.updatedAt
            )
        }

        return CollectionExport(
            schemaVersion: 1,
            exportedAt: exportedAt,
            collection: ExportCollection(
                id: normalizedCollectionID(collectionID),
                name: collectionName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? "Moja biblioteka"
                    : collectionName.trimmingCharacters(in: .whitespacesAndNewlines)
            ),
            locations: locationResult.locations,
            publications: publicationsByID.values.sorted { $0.id < $1.id },
            ownedItems: exportedItems.sorted { $0.id < $1.id }
        )
    }

    static func encode(_ export: CollectionExport) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(export)
    }

    private static func export(_ publication: Publication) -> ExportPublication {
        let issue: ExportIssue? = publication.publicationType == .periodical
            ? ExportIssue(
                number: nilIfEmpty(publication.issueNumber),
                volume: nilIfEmpty(publication.issueVolume),
                date: nilIfEmpty(publication.issueDate)
            )
            : nil

        return ExportPublication(
            id: publication.exportID,
            type: publication.publicationType.rawValue,
            title: publication.title,
            subtitle: nilIfEmpty(publication.subtitle),
            authors: publication.authors,
            language: nilIfEmpty(publication.language),
            publisher: nilIfEmpty(publication.publisher),
            publicationYear: publication.publicationYear,
            identifiers: ExportIdentifiers(
                isbn13: nilIfEmpty(publication.isbn13),
                issn: nilIfEmpty(publication.issn),
                ean: nilIfEmpty(publication.ean),
                barcode: nilIfEmpty(publication.barcode)
            ),
            issue: issue,
            metadata: ExportMetadata(
                source: publication.metadataSource,
                coverUrl: publication.exportCoverURL?.absoluteString,
                coverSource: publication.exportCoverSource
            ),
            createdAt: publication.createdAt,
            updatedAt: publication.updatedAt
        )
    }

    private static func makeLocations(for items: [OwnedItem]) -> (
        locations: [ExportLocation],
        leafIDs: [String: String]
    ) {
        var locationsByPath: [String: ExportLocation] = [:]
        var leafIDs: [String: String] = [:]

        for item in items {
            let components = item.locationPath
            guard !components.isEmpty else { continue }
            var cumulative: [String] = []
            var parentID: String?

            for (index, name) in components.enumerated() {
                cumulative.append(name)
                let key = canonicalPath(cumulative)
                let id = stableUUID(for: "location:\(key)")
                if locationsByPath[key] == nil {
                    locationsByPath[key] = ExportLocation(
                        id: id,
                        name: name,
                        type: inferLocationType(name: name, index: index),
                        parentId: parentID
                    )
                }
                parentID = id
            }
            leafIDs[canonicalPath(components)] = parentID
        }

        let locations = locationsByPath
            .sorted { lhs, rhs in lhs.key < rhs.key }
            .map(\.value)
        return (locations, leafIDs)
    }

    private static func inferLocationType(name: String, index: Int) -> String {
        let normalized = name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        if index == 0 || normalized.contains("dom") || normalized.contains("mieszkanie") {
            return "home"
        }
        if normalized.contains("pokoj") || normalized.contains("gabinet") || normalized.contains("salon") {
            return "room"
        }
        if normalized.contains("regal") || normalized.contains("bibliotecz") {
            return "bookcase"
        }
        if normalized.contains("polk") {
            return "shelf"
        }
        if normalized.contains("pud") || normalized.contains("karton") || normalized.contains("box") {
            return "box"
        }
        return index == 1 ? "room" : "other"
    }

    private static func canonicalPath(_ components: [String]) -> String {
        LocationPath(segments: components).deduplicationKey
    }

    private static func stableUUID(for value: String) -> String {
        let digest = SHA256.hash(data: Data(value.utf8))
        var hexadecimal = digest.prefix(16).map { String(format: "%02x", $0) }.joined()
        // Ustawiamy wariant i wersję UUID, zachowując deterministyczność pozostałych bitów.
        let versionIndex = hexadecimal.index(hexadecimal.startIndex, offsetBy: 12)
        hexadecimal.replaceSubrange(versionIndex...versionIndex, with: "5")
        let variantIndex = hexadecimal.index(hexadecimal.startIndex, offsetBy: 16)
        let variantNibble = Int(String(hexadecimal[variantIndex]), radix: 16) ?? 0
        hexadecimal.replaceSubrange(variantIndex...variantIndex, with: String(format: "%x", (variantNibble & 0x3) | 0x8))

        let parts = [8, 4, 4, 4, 12]
        var cursor = hexadecimal.startIndex
        return parts.map { count in
            let end = hexadecimal.index(cursor, offsetBy: count)
            defer { cursor = end }
            return String(hexadecimal[cursor..<end])
        }.joined(separator: "-").uppercased()
    }

    private static func normalizedCollectionID(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? stableUUID(for: "collection:default") : trimmed
    }

    private static func nilIfEmpty(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

struct CollectionJSONDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }

    let data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        self.data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
