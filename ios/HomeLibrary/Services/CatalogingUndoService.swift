import Foundation
import SwiftData

struct CatalogingUndoResult: Equatable {
    let didUndo: Bool
    let title: String?
    let location: String?

    static let itemNotFound = CatalogingUndoResult(
        didUndo: false,
        title: nil,
        location: nil
    )
}

/// Removes one exact physical copy previously added to the collection.
///
/// The related publication is removed only when no other `OwnedItem` still
/// points at that same SwiftData record.
@MainActor
enum CatalogingUndoService {
    @discardableResult
    static func undo(
        itemID: UUID,
        in modelContext: ModelContext
    ) throws -> CatalogingUndoResult {
        do {
            let requestedID = itemID
            var targetDescriptor = FetchDescriptor<OwnedItem>(
                predicate: #Predicate<OwnedItem> { item in
                    item.id == requestedID
                }
            )
            targetDescriptor.fetchLimit = 1

            guard let item = try modelContext.fetch(targetDescriptor).first else {
                return .itemNotFound
            }

            let title = item.publication?.title
            let location = item.locationPathText
            let publication = item.publication

            if let publication {
                let targetItemIdentity = item.persistentModelID
                let publicationIdentity = publication.persistentModelID
                let allItems = try modelContext.fetch(FetchDescriptor<OwnedItem>())
                let hasAnotherCopy = allItems.contains { candidate in
                    candidate.persistentModelID != targetItemIdentity &&
                        candidate.publication?.persistentModelID == publicationIdentity
                }

                modelContext.delete(item)
                if !hasAnotherCopy {
                    modelContext.delete(publication)
                }
            } else {
                modelContext.delete(item)
            }

            try modelContext.save()

            return CatalogingUndoResult(
                didUndo: true,
                title: title,
                location: location
            )
        } catch {
            modelContext.rollback()
            throw error
        }
    }
}
