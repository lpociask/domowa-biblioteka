import Foundation
import SwiftData

/// Value snapshot of every persisted `Publication` field needed to restore a
/// deletion without generating a new identity or changing historical dates.
struct CatalogItemLifecyclePublicationSnapshot: Equatable {
    let id: UUID
    let externalID: String
    let typeRawValue: String
    let title: String
    let subtitle: String
    let authorsText: String
    let language: String
    let publisher: String
    let publicationYear: Int?
    let isbn13: String
    let issn: String
    let ean: String
    let barcode: String
    let issueNumber: String
    let issueVolume: String
    let issueDate: String
    let metadataSource: String
    let createdAt: Date
    let updatedAt: Date
}

/// Value snapshot of every persisted `OwnedItem` field. `publicationID` makes
/// the relationship explicit and lets restore reject a malformed receipt.
struct CatalogItemLifecycleOwnedItemSnapshot: Equatable {
    let id: UUID
    let externalID: String
    let publicationID: UUID?
    let locationPathText: String
    let statusRawValue: String
    let notes: String
    let addedAt: Date
    let updatedAt: Date
}

struct CatalogItemDeletionReceipt: Equatable {
    let item: CatalogItemLifecycleOwnedItemSnapshot
    let publication: CatalogItemLifecyclePublicationSnapshot?

    /// `true` when deletion removed the last physical copy and therefore also
    /// removed its now-orphaned publication record.
    let publicationWasDeleted: Bool
}

struct CatalogItemRestoreResult {
    let item: OwnedItem
    let publication: Publication?
    let recreatedPublication: Bool
}

enum CatalogItemLifecycleError: Error, Equatable, LocalizedError {
    case itemNotFound(UUID)
    case itemIdentityConflict(UUID)
    case publicationMissing(itemID: UUID)
    case expectedPublicationMissing(UUID)
    case publicationIdentityConflict(UUID)
    case invalidReceipt

    var errorDescription: String? {
        switch self {
        case .itemNotFound:
            "Nie znaleziono egzemplarza do usunięcia."
        case .itemIdentityConflict:
            "Nie można przywrócić egzemplarza, ponieważ jego identyfikator jest już używany."
        case .publicationMissing:
            "Egzemplarz nie ma powiązanego opisu publikacji."
        case .expectedPublicationMissing:
            "Nie można przywrócić egzemplarza, ponieważ jego wspólny opis publikacji już nie istnieje."
        case .publicationIdentityConflict:
            "Nie można przywrócić publikacji, ponieważ jej identyfikator został ponownie użyty."
        case .invalidReceipt:
            "Nie można przywrócić egzemplarza z niezgodnego zapisu cofania."
        }
    }
}

/// Persistence boundary for deleting and restoring one exact physical copy.
///
/// A publication is shared metadata. It is deleted only together with its last
/// related copy. Restore never merges by title or bibliographic identifier: it
/// uses the stable record identities captured in the receipt.
@MainActor
struct CatalogItemLifecycleService {
    private let modelContext: ModelContext
    private let saveChanges: (ModelContext) throws -> Void

    init(
        modelContext: ModelContext,
        saveChanges: @escaping (ModelContext) throws -> Void = { context in
            try context.save()
        }
    ) {
        self.modelContext = modelContext
        self.saveChanges = saveChanges
    }

    @discardableResult
    func delete(itemID: UUID) throws -> CatalogItemDeletionReceipt {
        let item = try requiredUniqueItem(id: itemID)
        let publication = item.publication
        let publicationWasDeleted = try publication.map {
            try !hasAnotherCopy(of: $0, excluding: item)
        } ?? false

        let receipt = CatalogItemDeletionReceipt(
            item: Self.snapshot(item: item),
            publication: publication.map { Self.snapshot(publication: $0) },
            publicationWasDeleted: publicationWasDeleted
        )

        do {
            modelContext.delete(item)
            if receipt.publicationWasDeleted, let publication {
                modelContext.delete(publication)
            }
            try saveChanges(modelContext)
            return receipt
        } catch {
            modelContext.rollback()
            throw error
        }
    }

    @discardableResult
    func restore(
        _ receipt: CatalogItemDeletionReceipt
    ) throws -> CatalogItemRestoreResult {
        guard receipt.item.publicationID == receipt.publication?.id,
              receipt.publication != nil || !receipt.publicationWasDeleted else {
            throw CatalogItemLifecycleError.invalidReceipt
        }

        try ensureItemIdentityIsAvailable(receipt.item)

        guard let publicationSnapshot = receipt.publication else {
            let item = Self.makeItem(from: receipt.item, publication: nil)
            do {
                modelContext.insert(item)
                try saveChanges(modelContext)
                return CatalogItemRestoreResult(
                    item: item,
                    publication: nil,
                    recreatedPublication: false
                )
            } catch {
                modelContext.rollback()
                throw error
            }
        }

        let publication: Publication
        let recreatedPublication: Bool

        if receipt.publicationWasDeleted {
            // Any matching record means that the identity was reused after the
            // deletion. Even identical visible metadata is not proof that it is
            // the original SwiftData record.
            let externalID = publicationSnapshot.externalID.trimmingCharacters(in: .whitespacesAndNewlines)
            let hasExternalCollision: Bool
            if externalID.isEmpty {
                hasExternalCollision = false
            } else {
                hasExternalCollision = !(try publications(
                    withExternalID: publicationSnapshot.externalID
                )).isEmpty
            }
            guard try publications(withID: publicationSnapshot.id).isEmpty,
                  !hasExternalCollision else {
                throw CatalogItemLifecycleError.publicationIdentityConflict(publicationSnapshot.id)
            }

            publication = Self.makePublication(from: publicationSnapshot)
            recreatedPublication = true
        } else {
            let matches = try publications(withID: publicationSnapshot.id)
            guard matches.count == 1, let existing = matches.first else {
                if matches.isEmpty {
                    throw CatalogItemLifecycleError.expectedPublicationMissing(publicationSnapshot.id)
                }
                throw CatalogItemLifecycleError.publicationIdentityConflict(publicationSnapshot.id)
            }
            guard Self.hasStableIdentity(existing, matching: publicationSnapshot),
                  try hasNoExternalIdentityCollision(
                    for: existing,
                    expectedExternalID: publicationSnapshot.externalID
                  ) else {
                throw CatalogItemLifecycleError.publicationIdentityConflict(publicationSnapshot.id)
            }

            publication = existing
            recreatedPublication = false
        }

        let item = Self.makeItem(from: receipt.item, publication: publication)

        do {
            if recreatedPublication {
                modelContext.insert(publication)
            }
            modelContext.insert(item)
            try saveChanges(modelContext)
            return CatalogItemRestoreResult(
                item: item,
                publication: publication,
                recreatedPublication: recreatedPublication
            )
        } catch {
            modelContext.rollback()
            throw error
        }
    }

    private func requiredUniqueItem(id: UUID) throws -> OwnedItem {
        let matches = try items(withID: id)
        guard matches.count == 1, let item = matches.first else {
            if matches.isEmpty {
                throw CatalogItemLifecycleError.itemNotFound(id)
            }
            throw CatalogItemLifecycleError.itemIdentityConflict(id)
        }
        return item
    }

    private func ensureItemIdentityIsAvailable(
        _ snapshot: CatalogItemLifecycleOwnedItemSnapshot
    ) throws {
        guard try items(withID: snapshot.id).isEmpty else {
            throw CatalogItemLifecycleError.itemIdentityConflict(snapshot.id)
        }
        let externalID = snapshot.externalID.trimmingCharacters(in: .whitespacesAndNewlines)
        if !externalID.isEmpty,
           !(try items(withExternalID: snapshot.externalID)).isEmpty {
            throw CatalogItemLifecycleError.itemIdentityConflict(snapshot.id)
        }
    }

    private func hasAnotherCopy(
        of publication: Publication,
        excluding item: OwnedItem
    ) throws -> Bool {
        let publicationIdentity = publication.persistentModelID
        let itemIdentity = item.persistentModelID

        return try modelContext.fetch(FetchDescriptor<OwnedItem>()).contains { candidate in
            candidate.persistentModelID != itemIdentity &&
                candidate.publication?.persistentModelID == publicationIdentity
        }
    }

    private func hasNoExternalIdentityCollision(
        for publication: Publication,
        expectedExternalID: String
    ) throws -> Bool {
        guard !expectedExternalID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return true
        }
        return try publications(withExternalID: expectedExternalID).allSatisfy { candidate in
            candidate.persistentModelID == publication.persistentModelID
        }
    }

    private func items(withID id: UUID) throws -> [OwnedItem] {
        let requestedID = id
        var descriptor = FetchDescriptor<OwnedItem>(
            predicate: #Predicate<OwnedItem> { item in
                item.id == requestedID
            }
        )
        descriptor.fetchLimit = 2
        return try modelContext.fetch(descriptor)
    }

    private func items(withExternalID externalID: String) throws -> [OwnedItem] {
        let requestedExternalID = externalID
        var descriptor = FetchDescriptor<OwnedItem>(
            predicate: #Predicate<OwnedItem> { item in
                item.externalID == requestedExternalID
            }
        )
        descriptor.fetchLimit = 2
        return try modelContext.fetch(descriptor)
    }

    private func publications(withID id: UUID) throws -> [Publication] {
        let requestedID = id
        var descriptor = FetchDescriptor<Publication>(
            predicate: #Predicate<Publication> { publication in
                publication.id == requestedID
            }
        )
        descriptor.fetchLimit = 2
        return try modelContext.fetch(descriptor)
    }

    private func publications(withExternalID externalID: String) throws -> [Publication] {
        let requestedExternalID = externalID
        var descriptor = FetchDescriptor<Publication>(
            predicate: #Predicate<Publication> { publication in
                publication.externalID == requestedExternalID
            }
        )
        descriptor.fetchLimit = 2
        return try modelContext.fetch(descriptor)
    }

    private static func snapshot(
        item: OwnedItem
    ) -> CatalogItemLifecycleOwnedItemSnapshot {
        CatalogItemLifecycleOwnedItemSnapshot(
            id: item.id,
            externalID: item.externalID,
            publicationID: item.publication?.id,
            locationPathText: item.locationPathText,
            statusRawValue: item.statusRawValue,
            notes: item.notes,
            addedAt: item.addedAt,
            updatedAt: item.updatedAt
        )
    }

    private static func snapshot(
        publication: Publication
    ) -> CatalogItemLifecyclePublicationSnapshot {
        CatalogItemLifecyclePublicationSnapshot(
            id: publication.id,
            externalID: publication.externalID,
            typeRawValue: publication.typeRawValue,
            title: publication.title,
            subtitle: publication.subtitle,
            authorsText: publication.authorsText,
            language: publication.language,
            publisher: publication.publisher,
            publicationYear: publication.publicationYear,
            isbn13: publication.isbn13,
            issn: publication.issn,
            ean: publication.ean,
            barcode: publication.barcode,
            issueNumber: publication.issueNumber,
            issueVolume: publication.issueVolume,
            issueDate: publication.issueDate,
            metadataSource: publication.metadataSource,
            createdAt: publication.createdAt,
            updatedAt: publication.updatedAt
        )
    }

    private static func hasStableIdentity(
        _ publication: Publication,
        matching snapshot: CatalogItemLifecyclePublicationSnapshot
    ) -> Bool {
        publication.id == snapshot.id &&
            publication.externalID == snapshot.externalID &&
            publication.createdAt == snapshot.createdAt
    }

    private static func makePublication(
        from snapshot: CatalogItemLifecyclePublicationSnapshot
    ) -> Publication {
        let publication = Publication(
            id: snapshot.id,
            externalID: snapshot.externalID,
            type: PublicationType(rawValue: snapshot.typeRawValue) ?? .book,
            title: snapshot.title,
            subtitle: snapshot.subtitle,
            authorsText: snapshot.authorsText,
            language: snapshot.language,
            publisher: snapshot.publisher,
            publicationYear: snapshot.publicationYear,
            isbn13: snapshot.isbn13,
            issn: snapshot.issn,
            ean: snapshot.ean,
            barcode: snapshot.barcode,
            issueNumber: snapshot.issueNumber,
            issueVolume: snapshot.issueVolume,
            issueDate: snapshot.issueDate,
            metadataSource: snapshot.metadataSource,
            createdAt: snapshot.createdAt,
            updatedAt: snapshot.updatedAt
        )

        // Initializers normalize selected values. A lifecycle undo restores the
        // persisted state exactly, including any legacy raw values.
        publication.externalID = snapshot.externalID
        publication.typeRawValue = snapshot.typeRawValue
        return publication
    }

    private static func makeItem(
        from snapshot: CatalogItemLifecycleOwnedItemSnapshot,
        publication: Publication?
    ) -> OwnedItem {
        let item = OwnedItem(
            id: snapshot.id,
            externalID: snapshot.externalID,
            publication: publication,
            locationPathText: snapshot.locationPathText,
            status: OwnedItemStatus(rawValue: snapshot.statusRawValue) ?? .owned,
            notes: snapshot.notes,
            addedAt: snapshot.addedAt,
            updatedAt: snapshot.updatedAt
        )

        item.externalID = snapshot.externalID
        item.statusRawValue = snapshot.statusRawValue
        return item
    }
}
