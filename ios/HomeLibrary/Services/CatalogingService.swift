import Foundation
import SwiftData

/// Complete input needed to persist one physical copy in the collection.
///
/// Validation and identifier parsing remain the responsibility of the caller.
/// This value deliberately mirrors `Publication` so the save operation can be
/// exercised without constructing UI state.
struct CatalogingSaveRequest {
    let type: PublicationType
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
    let locationPathText: String
    let notes: String
    let savedAt: Date

    init(
        type: PublicationType,
        title: String,
        subtitle: String = "",
        authorsText: String = "",
        language: String = "",
        publisher: String = "",
        publicationYear: Int? = nil,
        isbn13: String = "",
        issn: String = "",
        ean: String = "",
        barcode: String = "",
        issueNumber: String = "",
        issueVolume: String = "",
        issueDate: String = "",
        metadataSource: String = "manual",
        locationPathText: String = "",
        notes: String = "",
        savedAt: Date = .now
    ) {
        self.type = type
        self.title = title
        self.subtitle = subtitle
        self.authorsText = authorsText
        self.language = language
        self.publisher = publisher
        self.publicationYear = publicationYear
        self.isbn13 = isbn13
        self.issn = issn
        self.ean = ean
        self.barcode = barcode
        self.issueNumber = issueNumber
        self.issueVolume = issueVolume
        self.issueDate = issueDate
        self.metadataSource = metadataSource
        self.locationPathText = locationPathText
        self.notes = notes
        self.savedAt = savedAt
    }
}

struct CatalogingSaveResult {
    let item: OwnedItem
    let publication: Publication
    let usedExisting: Bool
    let duplicateKind: ExistingPublicationMatch.Kind?
    /// Copies already present at the requested location before this save.
    let previousCopiesAtCurrentLocation: Int
    /// Number of owned copies after this save succeeds.
    let copyCount: Int
}

/// The single persistence boundary used when adding a physical copy.
@MainActor
struct CatalogingService {
    private let modelContext: ModelContext

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    func save(_ request: CatalogingSaveRequest) throws -> CatalogingSaveResult {
        let locationPath = LocationPath(request.locationPathText)
        let existingItems = try modelContext.fetch(FetchDescriptor<OwnedItem>())
        let match = ExistingPublicationMatcher.match(
            in: existingItems,
            type: request.type,
            isbn13: request.isbn13,
            issn: request.issn,
            ean: request.ean,
            issueNumber: request.issueNumber,
            issueDate: request.issueDate,
            locationPath: locationPath
        )

        let publication: Publication
        let insertedPublication: Publication?

        if let match {
            publication = match.publication
            insertedPublication = nil
        } else {
            let newPublication = Publication(
                type: request.type,
                title: request.title,
                subtitle: request.subtitle,
                authorsText: request.authorsText,
                language: request.language,
                publisher: request.publisher,
                publicationYear: request.publicationYear,
                isbn13: request.isbn13,
                issn: request.issn,
                ean: request.ean,
                barcode: request.barcode,
                issueNumber: request.issueNumber,
                issueVolume: request.issueVolume,
                issueDate: request.issueDate,
                metadataSource: request.metadataSource,
                createdAt: request.savedAt,
                updatedAt: request.savedAt
            )
            modelContext.insert(newPublication)
            publication = newPublication
            insertedPublication = newPublication
        }

        let item = OwnedItem(
            publication: publication,
            locationPathText: locationPath.canonical,
            notes: request.notes,
            addedAt: request.savedAt,
            updatedAt: request.savedAt
        )
        modelContext.insert(item)

        do {
            try modelContext.save()
        } catch {
            modelContext.delete(item)
            if let insertedPublication {
                modelContext.delete(insertedPublication)
            }
            throw error
        }

        return CatalogingSaveResult(
            item: item,
            publication: publication,
            usedExisting: match != nil,
            duplicateKind: match?.kind,
            previousCopiesAtCurrentLocation: match?.copyCountAtCurrentLocation ?? 0,
            copyCount: (match?.copyCount ?? 0) + 1
        )
    }
}
