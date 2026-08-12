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
    let coverURLString: String
    let coverSource: String
    let coverImageData: Data?
    let locationPathText: String
    let notes: String
    let savedAt: Date
    let forceNewPublication: Bool

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
        coverURLString: String = "",
        coverSource: String = "",
        coverImageData: Data? = nil,
        locationPathText: String = "",
        notes: String = "",
        savedAt: Date = .now,
        forceNewPublication: Bool = false
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
        self.coverURLString = coverURLString
        self.coverSource = coverSource
        self.coverImageData = coverImageData.flatMap { $0.isEmpty ? nil : $0 }
        self.locationPathText = locationPathText
        self.notes = notes
        self.savedAt = savedAt
        self.forceNewPublication = forceNewPublication
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
        let match = request.forceNewPublication
            ? nil
            : ExistingPublicationMatcher.match(
                in: existingItems,
                type: request.type,
                isbn13: request.isbn13,
                issn: request.issn,
                ean: request.ean,
                barcode: request.barcode,
                issueNumber: request.issueNumber,
                issueDate: request.issueDate,
                locationPath: locationPath
            )

        let publication: Publication

        if let match {
            publication = match.publication
            var updatedSharedDescription = false

            // When a later scan adds the previously missing EAN-2/EAN-5,
            // retain that stronger raw observation on the shared issue record.
            // The matcher has already rejected conflicting explicit main EANs.
            if request.type == .periodical,
               PeriodicalCompositeIdentifier(
                   ean: publication.ean,
                   barcode: publication.barcode
               ) == nil,
               let incomingComposite = PeriodicalCompositeIdentifier(
                   ean: request.ean,
                   barcode: request.barcode
               ) {
                publication.ean = incomingComposite.ean13
                publication.barcode = incomingComposite.canonical
                updatedSharedDescription = true
            }

            if request.type == .periodical {
                if publication.issueNumber.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    let value = request.issueNumber.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !value.isEmpty {
                        publication.issueNumber = value
                        updatedSharedDescription = true
                    }
                }
                if publication.issueVolume.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    let value = request.issueVolume.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !value.isEmpty {
                        publication.issueVolume = value
                        updatedSharedDescription = true
                    }
                }
                if publication.issueDate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    let value = request.issueDate.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !value.isEmpty {
                        publication.issueDate = value
                        updatedSharedDescription = true
                    }
                }
            }

            if publication.coverURLString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               !request.coverURLString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                publication.coverURLString = request.coverURLString
                publication.coverSource = request.coverSource
                updatedSharedDescription = true
            }
            if publication.resolvedCoverImageData == nil,
               let coverImageData = request.coverImageData {
                publication.coverImageData = coverImageData
                updatedSharedDescription = true
            }
            if updatedSharedDescription {
                publication.updatedAt = request.savedAt
            }
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
                coverURLString: request.coverURLString,
                coverSource: request.coverSource,
                coverImageData: request.coverImageData,
                createdAt: request.savedAt,
                updatedAt: request.savedAt
            )
            modelContext.insert(newPublication)
            publication = newPublication
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
            modelContext.rollback()
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
