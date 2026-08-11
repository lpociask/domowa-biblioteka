import Foundation
import SwiftData

/// Editable bibliographic values shared by every copy of one publication.
/// Stable identity and creation dates deliberately stay outside the draft.
struct PublicationEditDraft: Equatable {
    var type: PublicationType
    var title: String
    var subtitle: String
    var authorsText: String
    var language: String
    var publisher: String
    var publicationYear: Int?
    var isbn13: String
    var issn: String
    var ean: String
    var barcode: String
    var issueNumber: String
    var issueVolume: String
    var issueDate: String
    var metadataSource: String
}

/// Editable values belonging to one physical copy only.
struct OwnedItemEditDraft: Equatable {
    var locationPathText: String
    var status: OwnedItemStatus
    var notes: String
}

/// Value form model. Editing it never mutates SwiftData before an explicit save.
struct CatalogItemEditDraft: Equatable {
    var publication: PublicationEditDraft
    var item: OwnedItemEditDraft
}

/// Complete persisted state used for optimistic concurrency and one-level undo.
struct CatalogItemEditSnapshot: Equatable {
    let itemID: UUID
    let itemExternalID: String
    let itemAddedAt: Date
    let itemUpdatedAt: Date
    let publicationID: UUID
    let publicationExternalID: String
    let publicationCreatedAt: Date
    let publicationUpdatedAt: Date
    let draft: CatalogItemEditDraft
}

/// An editor must keep this baseline until commit. A bare draft is intentionally
/// insufficient, so a stale screen cannot silently overwrite newer data.
struct CatalogItemPreparedEdit: Equatable {
    let baseline: CatalogItemEditSnapshot
    var draft: CatalogItemEditDraft
    let sharedCopyCount: Int
}

struct CatalogItemEditResult: Equatable {
    let before: CatalogItemEditSnapshot
    let after: CatalogItemEditSnapshot
    /// Copies whose visible data changed: all copies for bibliography, one for copy-only edits.
    let affectedCopyCount: Int

    var didChange: Bool { before != after }
}

enum CatalogItemEditingError: Error, Equatable, LocalizedError {
    case itemNotFound(UUID)
    case publicationMissing(UUID)
    case editConflict(UUID)
    case undoConflict(UUID)
    case invalidTitle
    case invalidPublicationYear
    case invalidISBN
    case invalidISSN
    case invalidEAN
    case publicationIdentityConflict(UUID)

    var errorDescription: String? {
        switch self {
        case .itemNotFound:
            "Nie znaleziono egzemplarza do edycji."
        case .publicationMissing:
            "Egzemplarz nie ma powiązanego opisu publikacji."
        case .editConflict:
            "Dane zmieniły się po otwarciu formularza. Otwórz edycję ponownie."
        case .undoConflict:
            "Nie można cofnąć edycji, ponieważ dane zostały później zmienione."
        case .invalidTitle:
            "Tytuł publikacji nie może być pusty."
        case .invalidPublicationYear:
            "Rok wydania powinien być liczbą od 1 do 9999."
        case .invalidISBN:
            "ISBN ma nieprawidłową długość lub cyfrę kontrolną."
        case .invalidISSN:
            "ISSN ma nieprawidłową długość lub cyfrę kontrolną."
        case .invalidEAN:
            "EAN-13 ma nieprawidłową cyfrę kontrolną."
        case .publicationIdentityConflict:
            "Inny opis publikacji ma już ten sam identyfikator lub numer wydania."
        }
    }
}

/// Transactional persistence boundary for editing and moving existing copies.
/// It applies only the component changed by the user, so an independent newer
/// publication edit does not get overwritten by a move (and vice versa).
@MainActor
struct CatalogItemEditingService {
    private let modelContext: ModelContext
    private let saveChanges: (ModelContext) throws -> Void
    private let countCopies: (ModelContext, Publication) throws -> Int

    init(
        modelContext: ModelContext,
        saveChanges: @escaping (ModelContext) throws -> Void = { context in
            try context.save()
        },
        countCopies: @escaping (ModelContext, Publication) throws -> Int = { context, publication in
            let identity = publication.persistentModelID
            return try context.fetch(FetchDescriptor<OwnedItem>())
                .count { $0.publication?.persistentModelID == identity }
        }
    ) {
        self.modelContext = modelContext
        self.saveChanges = saveChanges
        self.countCopies = countCopies
    }

    func prepare(itemID: UUID) throws -> CatalogItemPreparedEdit {
        let item = try requiredItem(id: itemID)
        let publication = try requiredPublication(for: item)
        let baseline = Self.snapshot(item: item, publication: publication)
        return CatalogItemPreparedEdit(
            baseline: baseline,
            draft: baseline.draft,
            sharedCopyCount: try copyCount(for: publication)
        )
    }

    @discardableResult
    func edit(
        _ prepared: CatalogItemPreparedEdit,
        draft rawDraft: CatalogItemEditDraft,
        editedAt: Date = .now
    ) throws -> CatalogItemEditResult {
        let itemID = prepared.baseline.itemID
        let item = try requiredItem(id: itemID)
        let publication = try requiredPublication(for: item)
        let current = Self.snapshot(item: item, publication: publication)

        guard Self.hasStableIdentity(current, matching: prepared.baseline) else {
            throw CatalogItemEditingError.editConflict(itemID)
        }

        let requestedPublicationChange = rawDraft.publication != prepared.baseline.draft.publication
        let requestedItemChange = rawDraft.item != prepared.baseline.draft.item
        var normalizedDraft = rawDraft

        if requestedPublicationChange {
            normalizedDraft.publication = try Self.normalized(
                rawDraft.publication,
                relativeTo: prepared.baseline.draft.publication
            )
        } else {
            normalizedDraft.publication = prepared.baseline.draft.publication
        }
        if requestedItemChange {
            normalizedDraft.item = Self.normalized(rawDraft.item)
        } else {
            normalizedDraft.item = prepared.baseline.draft.item
        }

        let publicationChanged = normalizedDraft.publication != prepared.baseline.draft.publication
        let itemChanged = normalizedDraft.item != prepared.baseline.draft.item

        if publicationChanged {
            guard Self.publicationRevisionMatches(current, prepared.baseline) else {
                throw CatalogItemEditingError.editConflict(itemID)
            }
            try ensureNoIdentityConflict(
                for: normalizedDraft.publication,
                currentPublication: publication,
                baseline: prepared.baseline.draft.publication
            )
        }
        if itemChanged {
            guard Self.itemRevisionMatches(current, prepared.baseline) else {
                throw CatalogItemEditingError.editConflict(itemID)
            }
        }

        guard publicationChanged || itemChanged else {
            return CatalogItemEditResult(before: current, after: current, affectedCopyCount: 0)
        }

        let affectedCopyCount = publicationChanged ? try copyCount(for: publication) : 1

        do {
            if publicationChanged {
                Self.apply(normalizedDraft.publication, to: publication)
                publication.updatedAt = editedAt
            }
            if itemChanged {
                Self.apply(normalizedDraft.item, to: item)
                item.updatedAt = editedAt
            }
            try saveChanges(modelContext)
        } catch {
            modelContext.rollback()
            throw error
        }

        return CatalogItemEditResult(
            before: current,
            after: Self.snapshot(item: item, publication: publication),
            affectedCopyCount: affectedCopyCount
        )
    }

    @discardableResult
    func move(
        _ prepared: CatalogItemPreparedEdit,
        to locationPathText: String,
        movedAt: Date = .now
    ) throws -> CatalogItemEditResult {
        var draft = prepared.baseline.draft
        draft.item.locationPathText = locationPathText
        return try edit(prepared, draft: draft, editedAt: movedAt)
    }

    /// Reverses only the components changed by the supplied edit. Independent
    /// later changes to the other component remain intact.
    @discardableResult
    func undo(_ result: CatalogItemEditResult) throws -> CatalogItemEditResult {
        let itemID = result.after.itemID
        guard Self.hasStableIdentity(result.before, matching: result.after) else {
            throw CatalogItemEditingError.undoConflict(itemID)
        }
        let item = try requiredItem(id: itemID)
        let publication = try requiredPublication(for: item)
        let current = Self.snapshot(item: item, publication: publication)

        guard Self.hasStableIdentity(current, matching: result.after) else {
            throw CatalogItemEditingError.undoConflict(itemID)
        }

        let publicationChanged = result.before.draft.publication != result.after.draft.publication
        let itemChanged = result.before.draft.item != result.after.draft.item

        if publicationChanged,
           !Self.publicationRevisionMatches(current, result.after) {
            throw CatalogItemEditingError.undoConflict(itemID)
        }
        if itemChanged,
           !Self.itemRevisionMatches(current, result.after) {
            throw CatalogItemEditingError.undoConflict(itemID)
        }

        if publicationChanged {
            do {
                try ensureNoIdentityConflict(
                    for: result.before.draft.publication,
                    currentPublication: publication,
                    baseline: result.after.draft.publication
                )
            } catch is CatalogItemEditingError {
                throw CatalogItemEditingError.undoConflict(itemID)
            }
        }

        guard publicationChanged || itemChanged else {
            return CatalogItemEditResult(before: current, after: current, affectedCopyCount: 0)
        }

        let affectedCopyCount = publicationChanged ? try copyCount(for: publication) : 1

        do {
            if publicationChanged {
                Self.apply(result.before.draft.publication, to: publication)
                publication.updatedAt = result.before.publicationUpdatedAt
            }
            if itemChanged {
                Self.apply(result.before.draft.item, to: item)
                item.updatedAt = result.before.itemUpdatedAt
            }
            try saveChanges(modelContext)
        } catch {
            modelContext.rollback()
            throw error
        }

        return CatalogItemEditResult(
            before: current,
            after: Self.snapshot(item: item, publication: publication),
            affectedCopyCount: affectedCopyCount
        )
    }

    private func requiredItem(id: UUID) throws -> OwnedItem {
        let requestedID = id
        var descriptor = FetchDescriptor<OwnedItem>(
            predicate: #Predicate<OwnedItem> { item in item.id == requestedID }
        )
        descriptor.fetchLimit = 2
        let matches = try modelContext.fetch(descriptor)
        guard matches.count == 1, let item = matches.first else {
            if matches.isEmpty {
                throw CatalogItemEditingError.itemNotFound(id)
            }
            throw CatalogItemEditingError.editConflict(id)
        }
        return item
    }

    private func requiredPublication(for item: OwnedItem) throws -> Publication {
        guard let publication = item.publication else {
            throw CatalogItemEditingError.publicationMissing(item.id)
        }
        let requestedID = publication.id
        var descriptor = FetchDescriptor<Publication>(
            predicate: #Predicate<Publication> { candidate in candidate.id == requestedID }
        )
        descriptor.fetchLimit = 2
        let matches = try modelContext.fetch(descriptor)
        guard matches.count == 1,
              matches.first?.persistentModelID == publication.persistentModelID else {
            throw CatalogItemEditingError.editConflict(item.id)
        }
        return publication
    }

    private func copyCount(for publication: Publication) throws -> Int {
        try countCopies(modelContext, publication)
    }

    private func ensureNoIdentityConflict(
        for draft: PublicationEditDraft,
        currentPublication: Publication,
        baseline: PublicationEditDraft
    ) throws {
        guard Self.identityChanged(from: baseline, to: draft) else { return }

        let candidates = try modelContext.fetch(FetchDescriptor<Publication>())
            .sorted { $0.id.uuidString < $1.id.uuidString }
        for candidate in candidates {
            guard candidate.persistentModelID != currentPublication.persistentModelID else { continue }
            if Self.representsSameEdition(draft, Self.makeDraft(publication: candidate)) {
                throw CatalogItemEditingError.publicationIdentityConflict(candidate.id)
            }
        }
    }

    private static func normalized(_ draft: OwnedItemEditDraft) -> OwnedItemEditDraft {
        var normalized = draft
        normalized.locationPathText = LocationPath(draft.locationPathText).canonical
        normalized.notes = clean(draft.notes)
        return normalized
    }

    private static func normalized(
        _ draft: PublicationEditDraft,
        relativeTo baseline: PublicationEditDraft
    ) throws -> PublicationEditDraft {
        var normalized = baseline
        normalized.type = draft.type

        if draft.title != baseline.title {
            normalized.title = clean(draft.title)
            guard !normalized.title.isEmpty else { throw CatalogItemEditingError.invalidTitle }
        }
        if draft.subtitle != baseline.subtitle { normalized.subtitle = clean(draft.subtitle) }
        if draft.authorsText != baseline.authorsText { normalized.authorsText = clean(draft.authorsText) }
        if draft.language != baseline.language { normalized.language = clean(draft.language) }
        if draft.publisher != baseline.publisher { normalized.publisher = clean(draft.publisher) }
        if draft.barcode != baseline.barcode { normalized.barcode = clean(draft.barcode) }
        if draft.issueNumber != baseline.issueNumber { normalized.issueNumber = clean(draft.issueNumber) }
        if draft.issueVolume != baseline.issueVolume { normalized.issueVolume = clean(draft.issueVolume) }
        if draft.issueDate != baseline.issueDate { normalized.issueDate = clean(draft.issueDate) }
        if draft.metadataSource != baseline.metadataSource { normalized.metadataSource = clean(draft.metadataSource) }

        if draft.publicationYear != baseline.publicationYear {
            if let year = draft.publicationYear, !(1...9999).contains(year) {
                throw CatalogItemEditingError.invalidPublicationYear
            }
            normalized.publicationYear = draft.publicationYear
        }

        if draft.isbn13 != baseline.isbn13 {
            let isbn = clean(draft.isbn13)
            if isbn.isEmpty {
                normalized.isbn13 = ""
            } else {
                let parsed = PublicationIdentifierParser.parse(isbn)
                guard parsed.isValid, parsed.kind == .isbn10 || parsed.kind == .isbn13 else {
                    throw CatalogItemEditingError.invalidISBN
                }
                normalized.isbn13 = parsed.isbn13 ?? parsed.normalized
            }
        }

        if draft.ean != baseline.ean {
            let ean = clean(draft.ean)
            if ean.isEmpty {
                normalized.ean = ""
            } else {
                let parsed = PublicationIdentifierParser.parse(ean)
                guard parsed.isValid, parsed.kind == .ean13 || parsed.kind == .isbn13 else {
                    throw CatalogItemEditingError.invalidEAN
                }
                normalized.ean = parsed.normalized
            }
        }

        if draft.issn != baseline.issn {
            let issn = clean(draft.issn)
            if issn.isEmpty {
                normalized.issn = ""
            } else if let normalizedISSN = Self.normalizedISSN(issn) {
                normalized.issn = normalizedISSN
            } else {
                throw CatalogItemEditingError.invalidISSN
            }
        }
        return normalized
    }

    private static func normalizedISSN(_ value: String) -> String? {
        let compact = value.uppercased().filter { $0.isNumber || $0 == "X" }
        guard compact.count == 8 else { return nil }
        let characters = Array(compact)
        var sum = 0
        for index in 0..<8 {
            let digit: Int
            if index == 7, characters[index] == "X" {
                digit = 10
            } else if let value = characters[index].wholeNumberValue {
                digit = value
            } else {
                return nil
            }
            sum += digit * (8 - index)
        }
        guard sum.isMultiple(of: 11) else { return nil }
        return "\(compact.prefix(4))-\(compact.dropFirst(4))"
    }

    private static func identityChanged(
        from baseline: PublicationEditDraft,
        to draft: PublicationEditDraft
    ) -> Bool {
        baseline.type != draft.type ||
            cleanIdentifier(baseline.isbn13) != cleanIdentifier(draft.isbn13) ||
            cleanIdentifier(baseline.issn) != cleanIdentifier(draft.issn) ||
            cleanIdentifier(baseline.ean) != cleanIdentifier(draft.ean) ||
            normalizedText(baseline.issueNumber) != normalizedText(draft.issueNumber) ||
            normalizedText(baseline.issueDate) != normalizedText(draft.issueDate)
    }

    private static func representsSameEdition(
        _ lhs: PublicationEditDraft,
        _ rhs: PublicationEditDraft
    ) -> Bool {
        guard lhs.type == rhs.type else { return false }
        switch lhs.type {
        case .book:
            let leftKeys = bookIdentityKeys(lhs)
            let rightKeys = bookIdentityKeys(rhs)
            return !leftKeys.isDisjoint(with: rightKeys)
        case .periodical:
            let leftEAN = cleanIdentifier(lhs.ean)
            let rightEAN = cleanIdentifier(rhs.ean)
            if !leftEAN.isEmpty, leftEAN == rightEAN { return true }

            let leftISSN = cleanIdentifier(lhs.issn)
            let rightISSN = cleanIdentifier(rhs.issn)
            guard !leftISSN.isEmpty, leftISSN == rightISSN else { return false }

            let leftNumber = normalizedText(lhs.issueNumber)
            let rightNumber = normalizedText(rhs.issueNumber)
            let leftDate = normalizedText(lhs.issueDate)
            let rightDate = normalizedText(rhs.issueDate)
            let matchingNumber = !leftNumber.isEmpty && leftNumber == rightNumber
            let matchingDate = !leftDate.isEmpty && leftDate == rightDate
            let conflictingNumber = !leftNumber.isEmpty && !rightNumber.isEmpty && leftNumber != rightNumber
            let conflictingDate = !leftDate.isEmpty && !rightDate.isEmpty && leftDate != rightDate
            return (matchingNumber && !conflictingDate) || (matchingDate && !conflictingNumber)
        }
    }

    private static func bookIdentityKeys(_ draft: PublicationEditDraft) -> Set<String> {
        var keys = Set<String>()
        let isbn = canonicalISBN(draft.isbn13)
        if !isbn.isEmpty { keys.insert(isbn) }

        let ean = cleanIdentifier(draft.ean)
        if !ean.isEmpty {
            keys.insert(ean)
            let parsed = PublicationIdentifierParser.parse(ean)
            if parsed.isValid, parsed.kind == .isbn13, let isbn13 = parsed.isbn13 {
                keys.insert(isbn13)
            }
        }
        return keys
    }

    private static func canonicalISBN(_ value: String) -> String {
        let cleaned = cleanIdentifier(value)
        guard !cleaned.isEmpty else { return "" }
        let parsed = PublicationIdentifierParser.parse(cleaned)
        guard parsed.isValid, parsed.kind == .isbn10 || parsed.kind == .isbn13 else {
            return cleaned
        }
        return parsed.isbn13 ?? parsed.normalized
    }

    private static func hasStableIdentity(
        _ current: CatalogItemEditSnapshot,
        matching expected: CatalogItemEditSnapshot
    ) -> Bool {
        current.itemID == expected.itemID &&
            current.itemExternalID == expected.itemExternalID &&
            current.itemAddedAt == expected.itemAddedAt &&
            current.publicationID == expected.publicationID &&
            current.publicationExternalID == expected.publicationExternalID &&
            current.publicationCreatedAt == expected.publicationCreatedAt
    }

    private static func itemRevisionMatches(
        _ current: CatalogItemEditSnapshot,
        _ expected: CatalogItemEditSnapshot
    ) -> Bool {
        current.itemUpdatedAt == expected.itemUpdatedAt &&
            current.draft.item == expected.draft.item
    }

    private static func publicationRevisionMatches(
        _ current: CatalogItemEditSnapshot,
        _ expected: CatalogItemEditSnapshot
    ) -> Bool {
        current.publicationUpdatedAt == expected.publicationUpdatedAt &&
            current.draft.publication == expected.draft.publication
    }

    private static func snapshot(
        item: OwnedItem,
        publication: Publication
    ) -> CatalogItemEditSnapshot {
        CatalogItemEditSnapshot(
            itemID: item.id,
            itemExternalID: item.externalID,
            itemAddedAt: item.addedAt,
            itemUpdatedAt: item.updatedAt,
            publicationID: publication.id,
            publicationExternalID: publication.externalID,
            publicationCreatedAt: publication.createdAt,
            publicationUpdatedAt: publication.updatedAt,
            draft: CatalogItemEditDraft(
                publication: makeDraft(publication: publication),
                item: OwnedItemEditDraft(
                    locationPathText: item.locationPathText,
                    status: item.status,
                    notes: item.notes
                )
            )
        )
    }

    private static func makeDraft(publication: Publication) -> PublicationEditDraft {
        PublicationEditDraft(
            type: publication.publicationType,
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
            metadataSource: publication.metadataSource
        )
    }

    private static func apply(_ draft: PublicationEditDraft, to publication: Publication) {
        publication.publicationType = draft.type
        publication.title = draft.title
        publication.subtitle = draft.subtitle
        publication.authorsText = draft.authorsText
        publication.language = draft.language
        publication.publisher = draft.publisher
        publication.publicationYear = draft.publicationYear
        publication.isbn13 = draft.isbn13
        publication.issn = draft.issn
        publication.ean = draft.ean
        publication.barcode = draft.barcode
        publication.issueNumber = draft.issueNumber
        publication.issueVolume = draft.issueVolume
        publication.issueDate = draft.issueDate
        publication.metadataSource = draft.metadataSource
    }

    private static func apply(_ draft: OwnedItemEditDraft, to item: OwnedItem) {
        item.locationPathText = draft.locationPathText
        item.status = draft.status
        item.notes = draft.notes
    }

    private static func clean(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func cleanIdentifier(_ value: String) -> String {
        value.uppercased().filter { $0.isNumber || $0 == "X" }
    }

    private static func normalizedText(_ value: String) -> String {
        clean(value).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }
}
