import CryptoKit
import Foundation
import SwiftData

struct CollectionImportReport: Equatable, Sendable {
    let collectionID: String
    let collectionName: String
    let addedPublications: Int
    let skippedPublications: Int
    let addedItems: Int
    let skippedItems: Int

    var summary: String {
        let added = "Dodano \(addedPublications) \(publicationLabel(addedPublications)) i \(addedItems) \(itemLabel(addedItems))."
        let skippedCount = skippedPublications + skippedItems
        guard skippedCount > 0 else { return added }
        return "\(added) Pominięto istniejące: \(skippedPublications) publikacji i \(skippedItems) egzemplarzy."
    }

    private func publicationLabel(_ count: Int) -> String {
        count == 1 ? "publikację" : "publikacji"
    }

    private func itemLabel(_ count: Int) -> String {
        count == 1 ? "egzemplarz" : "egzemplarzy"
    }
}

enum CollectionImportError: LocalizedError, Equatable {
    case fileTooLarge(maximumBytes: Int)
    case invalidJSON(String)
    case unsupportedSchema(Int)
    case tooManyRecords(section: String, maximum: Int)
    case invalidCollection(String)
    case invalidLocation(String)
    case duplicateLocationID(String)
    case missingLocationParent(locationID: String, parentID: String)
    case cyclicLocation(String)
    case invalidPublication(String)
    case duplicatePublicationID(String)
    case invalidOwnedItem(String)
    case duplicateOwnedItemID(String)
    case missingLocation(itemID: String, locationID: String)
    case missingPublication(itemID: String, publicationID: String)
    case conflictingOwnedItem(
        itemID: String,
        existingPublicationID: String?,
        importedPublicationID: String
    )
    case persistence(String)

    var errorDescription: String? {
        switch self {
        case .fileTooLarge(let maximumBytes):
            return "Plik jest za duży. Maksymalny rozmiar importu to \(maximumBytes / 1_048_576) MB."
        case .invalidJSON(let reason):
            return "Plik nie jest prawidłowym eksportem kolekcji. \(reason)"
        case .unsupportedSchema(let version):
            return "Nieobsługiwana wersja formatu: \(version). Aplikacja obsługuje schemaVersion 1."
        case .tooManyRecords(let section, let maximum):
            return "Sekcja „\(section)” przekracza limit \(maximum) rekordów."
        case .invalidCollection(let reason):
            return "Nieprawidłowe dane kolekcji: \(reason)"
        case .invalidLocation(let reason):
            return "Nieprawidłowa lokalizacja: \(reason)"
        case .duplicateLocationID(let id):
            return "Plik zawiera więcej niż jedną lokalizację o identyfikatorze „\(id)”."
        case .missingLocationParent(let locationID, let parentID):
            return "Lokalizacja „\(locationID)” wskazuje nieistniejącą lokalizację nadrzędną „\(parentID)”."
        case .cyclicLocation(let id):
            return "Hierarchia lokalizacji zawiera cykl obejmujący „\(id)”."
        case .invalidPublication(let reason):
            return "Nieprawidłowa publikacja: \(reason)"
        case .duplicatePublicationID(let id):
            return "Plik zawiera więcej niż jedną publikację o identyfikatorze „\(id)”."
        case .invalidOwnedItem(let reason):
            return "Nieprawidłowy egzemplarz: \(reason)"
        case .duplicateOwnedItemID(let id):
            return "Plik zawiera więcej niż jeden egzemplarz o identyfikatorze „\(id)”."
        case .missingLocation(let itemID, let locationID):
            return "Egzemplarz „\(itemID)” wskazuje nieistniejącą lokalizację „\(locationID)”."
        case .missingPublication(let itemID, let publicationID):
            return "Egzemplarz „\(itemID)” wskazuje nieistniejącą publikację „\(publicationID)”."
        case .conflictingOwnedItem(let itemID, let existingPublicationID, let importedPublicationID):
            let existing = existingPublicationID.map { "„\($0)”" } ?? "brak publikacji"
            return "Egzemplarz „\(itemID)” już istnieje i wskazuje \(existing), a import wskazuje „\(importedPublicationID)”."
        case .persistence(let reason):
            return "Nie udało się zapisać importu. \(reason)"
        }
    }
}

struct PreparedCollectionImport: Sendable {
    let collectionID: String
    let collectionName: String
    fileprivate let validated: ValidatedImport
}

enum CollectionImporter {
    static let maximumFileSizeBytes = 25 * 1_048_576
    static let maximumPublications = 50_000
    static let maximumOwnedItems = 100_000
    static let maximumLocations = 50_000

    /// Czyta plik i przygotowuje import bez dotykania SwiftData. Funkcja może być
    /// bezpiecznie uruchomiona poza MainActor.
    static func prepare(fileAt url: URL) throws -> PreparedCollectionImport {
        try Task.checkCancellation()
        let hasSecurityScope = url.startAccessingSecurityScopedResource()
        defer {
            if hasSecurityScope {
                url.stopAccessingSecurityScopedResource()
            }
        }

        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        if let fileSize = values.fileSize, fileSize > maximumFileSizeBytes {
            throw CollectionImportError.fileTooLarge(maximumBytes: maximumFileSizeBytes)
        }

        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        try Task.checkCancellation()
        return try prepare(data: data)
    }

    /// Dekodowanie i pełna walidacja są celowo oddzielone od zapisu do modelu.
    static func prepare(data: Data) throws -> PreparedCollectionImport {
        guard data.count <= maximumFileSizeBytes else {
            throw CollectionImportError.fileTooLarge(maximumBytes: maximumFileSizeBytes)
        }

        let payload = try decode(data)
        let validated = try validate(payload)
        return PreparedCollectionImport(
            collectionID: validated.collectionID,
            collectionName: validated.collectionName,
            validated: validated
        )
    }

    @MainActor
    static func importCollection(
        data: Data,
        into modelContext: ModelContext
    ) throws -> CollectionImportReport {
        try apply(prepare(data: data), into: modelContext)
    }

    /// Zapis jest wykonywany dopiero po przygotowaniu całego planu i sprawdzeniu
    /// konfliktów z istniejącymi egzemplarzami.
    @MainActor
    static func apply(
        _ prepared: PreparedCollectionImport,
        into modelContext: ModelContext
    ) throws -> CollectionImportReport {
        let validated = prepared.validated
        let existingPublications: [Publication]
        let existingItems: [OwnedItem]
        do {
            existingPublications = try modelContext.fetch(FetchDescriptor<Publication>())
            existingItems = try modelContext.fetch(FetchDescriptor<OwnedItem>())
        } catch {
            throw CollectionImportError.persistence(error.localizedDescription)
        }

        var publicationsByID: [UUID: Publication] = [:]
        for publication in existingPublications {
            publicationsByID[publication.id] = publication
        }

        var existingItemsByID: [UUID: OwnedItem] = [:]
        for item in existingItems {
            existingItemsByID[item.id] = item
        }

        var publicationsToInsert: [ImportPublication] = []
        var skippedPublications = 0
        for source in validated.publications {
            let id = publicationUUID(for: source.id)
            if publicationsByID[id] == nil {
                publicationsToInsert.append(source)
            } else {
                skippedPublications += 1
            }
        }

        var itemsToInsert: [ImportOwnedItem] = []
        var skippedItems = 0
        for source in validated.ownedItems {
            let itemID = ownedItemUUID(for: source.id)
            let publicationID = publicationUUID(for: source.publicationId)
            if let existingItem = existingItemsByID[itemID] {
                guard existingItem.publication?.id == publicationID else {
                    throw CollectionImportError.conflictingOwnedItem(
                        itemID: source.id.trimmed,
                        existingPublicationID: existingItem.publication?.exportID,
                        importedPublicationID: source.publicationId.trimmed
                    )
                }
                skippedItems += 1
            } else {
                itemsToInsert.append(source)
            }
        }

        // Wszystkie konflikty są już sprawdzone. Dopiero teraz zaczynamy mutować kontekst.
        for source in publicationsToInsert {
            let id = publicationUUID(for: source.id)
            let importedCoverURL = source.metadata?.coverUrl
                .flatMap { RemoteCoverURLPolicy.validatedReference($0)?.absoluteString }
            let publication = Publication(
                id: id,
                externalID: source.id.trimmed,
                type: PublicationType(rawValue: source.type)!,
                title: source.title.trimmed,
                subtitle: source.subtitle?.trimmed ?? "",
                authorsText: source.authors
                    .map(\.trimmed)
                    .filter { !$0.isEmpty }
                    .joined(separator: "; "),
                language: source.language?.trimmed ?? "",
                publisher: source.publisher?.trimmed ?? "",
                publicationYear: source.publicationYear,
                isbn13: source.identifiers.isbn13?.trimmed ?? "",
                issn: source.identifiers.issn?.trimmed ?? "",
                ean: source.identifiers.ean?.trimmed ?? "",
                barcode: source.identifiers.barcode?.trimmed ?? "",
                issueNumber: source.issue?.number?.trimmed ?? "",
                issueVolume: source.issue?.volume?.trimmed ?? "",
                issueDate: source.issue?.date?.trimmed ?? "",
                metadataSource: source.metadata?.source?.trimmed.nilIfBlank ?? "import",
                coverURLString: importedCoverURL ?? "",
                coverSource: importedCoverURL == nil
                    ? ""
                    : (source.metadata?.coverSource?.trimmed ?? ""),
                createdAt: source.createdAt,
                updatedAt: source.updatedAt
            )
            modelContext.insert(publication)
            publicationsByID[id] = publication
        }

        for source in itemsToInsert {
            let publicationID = publicationUUID(for: source.publicationId)
            guard let publication = publicationsByID[publicationID] else {
                // Walidacja pliku i plan importu powinny ten stan wykluczać.
                modelContext.rollback()
                throw CollectionImportError.missingPublication(
                    itemID: source.id.trimmed,
                    publicationID: source.publicationId.trimmed
                )
            }

            let path = resolvedLocationPath(
                explicitPath: source.locationPath,
                locationID: source.locationId,
                locationsByID: validated.locationsByID
            )
            let item = OwnedItem(
                id: ownedItemUUID(for: source.id),
                externalID: source.id.trimmed,
                publication: publication,
                locationPathText: path.joined(separator: " / "),
                status: OwnedItemStatus(rawValue: source.status)!,
                notes: source.notes?.trimmed ?? "",
                addedAt: source.addedAt,
                updatedAt: source.updatedAt
            )
            modelContext.insert(item)
        }

        if !publicationsToInsert.isEmpty || !itemsToInsert.isEmpty {
            do {
                try modelContext.save()
            } catch {
                modelContext.rollback()
                throw CollectionImportError.persistence(error.localizedDescription)
            }
        }

        return CollectionImportReport(
            collectionID: validated.collectionID,
            collectionName: validated.collectionName,
            addedPublications: publicationsToInsert.count,
            skippedPublications: skippedPublications,
            addedItems: itemsToInsert.count,
            skippedItems: skippedItems
        )
    }

    static func publicationUUID(for externalID: String) -> UUID {
        mappedUUID(for: externalID, namespace: "publication")
    }

    static func ownedItemUUID(for externalID: String) -> UUID {
        mappedUUID(for: externalID, namespace: "owned-item")
    }

    private static func decode(_ data: Data) throws -> ImportCollection {
        do {
            let envelope = try JSONDecoder().decode(ImportEnvelope.self, from: data)
            guard envelope.schemaVersion == 1 else {
                throw CollectionImportError.unsupportedSchema(envelope.schemaVersion)
            }
        } catch let error as CollectionImportError {
            throw error
        } catch let error as DecodingError {
            throw CollectionImportError.invalidJSON(decodingDescription(error))
        } catch {
            throw CollectionImportError.invalidJSON(error.localizedDescription)
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            guard let date = strictISO8601Date(from: value) else {
                throw CollectionImportError.invalidJSON(
                    "Nieprawidłowa data ISO 8601 w \(pathDescription(decoder.codingPath)): „\(value)”."
                )
            }
            return date
        }

        do {
            return try decoder.decode(ImportCollection.self, from: data)
        } catch let error as CollectionImportError {
            throw error
        } catch let error as DecodingError {
            throw CollectionImportError.invalidJSON(decodingDescription(error))
        } catch {
            throw CollectionImportError.invalidJSON(error.localizedDescription)
        }
    }

    /// Waliduje dokładnie ten sam wariant daty co klient WWW:
    /// YYYY-MM-DDTHH:mm:ss[.ułamek](Z|±HH:mm). Składniki są sprawdzane przed
    /// zbudowaniem `Date`, dzięki czemu Foundation nie może znormalizować np.
    /// 29 lutego w roku nieprzestępnym do 1 marca.
    private static func strictISO8601Date(from value: String) -> Date? {
        let bytes = Array(value.utf8)
        guard bytes.count >= 20 else { return nil }

        let digitRanges = [0..<4, 5..<7, 8..<10, 11..<13, 14..<16, 17..<19]
        guard digitRanges.allSatisfy({ range in
            range.allSatisfy { isASCIIDigit(bytes[$0]) }
        }),
        bytes[4] == 45,  // -
        bytes[7] == 45,  // -
        bytes[10] == 84, // T
        bytes[13] == 58, // :
        bytes[16] == 58  // :
        else {
            return nil
        }

        let year = asciiInteger(bytes, range: 0..<4)
        let month = asciiInteger(bytes, range: 5..<7)
        let day = asciiInteger(bytes, range: 8..<10)
        let hour = asciiInteger(bytes, range: 11..<13)
        let minute = asciiInteger(bytes, range: 14..<16)
        let second = asciiInteger(bytes, range: 17..<19)

        guard (1...9999).contains(year),
              (1...12).contains(month),
              (0...23).contains(hour),
              (0...59).contains(minute),
              (0...59).contains(second) else {
            return nil
        }

        let leapYear = year.isMultiple(of: 4)
            && (!year.isMultiple(of: 100) || year.isMultiple(of: 400))
        let daysInMonth = [31, leapYear ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
        guard (1...daysInMonth[month - 1]).contains(day) else { return nil }

        var cursor = 19
        var fractionalSeconds = 0.0
        if bytes[cursor] == 46 { // .
            cursor += 1
            let fractionStart = cursor
            var fractionDigitCount = 0
            var scale = 0.1
            while cursor < bytes.count, isASCIIDigit(bytes[cursor]) {
                // Klient WWW (`Date.parse`) przechowuje milisekundy. Dalsze
                // cyfry są poprawne składniowo, ale nie mogą powodować
                // przepełnień ani różnicy semantycznej między klientami.
                if fractionDigitCount < 3 {
                    fractionalSeconds += Double(bytes[cursor] - 48) * scale
                    scale /= 10
                }
                fractionDigitCount += 1
                cursor += 1
            }
            guard cursor > fractionStart else { return nil }
        }

        guard cursor < bytes.count else { return nil }
        let offsetSeconds: Int
        if bytes[cursor] == 90 { // Z
            guard cursor + 1 == bytes.count else { return nil }
            offsetSeconds = 0
        } else {
            guard (bytes[cursor] == 43 || bytes[cursor] == 45), // + lub -
                  cursor + 6 == bytes.count,
                  isASCIIDigit(bytes[cursor + 1]),
                  isASCIIDigit(bytes[cursor + 2]),
                  bytes[cursor + 3] == 58,
                  isASCIIDigit(bytes[cursor + 4]),
                  isASCIIDigit(bytes[cursor + 5]) else {
                return nil
            }

            let offsetHour = asciiInteger(bytes, range: (cursor + 1)..<(cursor + 3))
            let offsetMinute = asciiInteger(bytes, range: (cursor + 4)..<(cursor + 6))
            guard (0...23).contains(offsetHour), (0...59).contains(offsetMinute) else {
                return nil
            }
            let sign = bytes[cursor] == 43 ? 1 : -1
            offsetSeconds = sign * (offsetHour * 3_600 + offsetMinute * 60)
        }

        let utc = TimeZone(secondsFromGMT: 0)!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        let components = DateComponents(
            calendar: calendar,
            timeZone: utc,
            year: year,
            month: month,
            day: day,
            hour: hour,
            minute: minute,
            second: second
        )
        guard let localDate = calendar.date(from: components) else { return nil }

        let resolved = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: localDate
        )
        guard resolved.year == year,
              resolved.month == month,
              resolved.day == day,
              resolved.hour == hour,
              resolved.minute == minute,
              resolved.second == second else {
            return nil
        }

        return localDate.addingTimeInterval(fractionalSeconds - Double(offsetSeconds))
    }

    private static func isASCIIDigit(_ byte: UInt8) -> Bool {
        (48...57).contains(byte)
    }

    private static func asciiInteger(_ bytes: [UInt8], range: Range<Int>) -> Int {
        range.reduce(into: 0) { result, index in
            result = result * 10 + Int(bytes[index] - 48)
        }
    }

    private static func validate(_ payload: ImportCollection) throws -> ValidatedImport {
        guard payload.publications.count <= maximumPublications else {
            throw CollectionImportError.tooManyRecords(
                section: "publications",
                maximum: maximumPublications
            )
        }
        guard payload.ownedItems.count <= maximumOwnedItems else {
            throw CollectionImportError.tooManyRecords(
                section: "ownedItems",
                maximum: maximumOwnedItems
            )
        }
        guard payload.locations.count <= maximumLocations else {
            throw CollectionImportError.tooManyRecords(
                section: "locations",
                maximum: maximumLocations
            )
        }

        let collectionID = payload.collection.id.trimmed
        let collectionName = payload.collection.name.trimmed
        guard !collectionID.isEmpty else {
            throw CollectionImportError.invalidCollection("brak identyfikatora.")
        }
        guard !collectionName.isEmpty else {
            throw CollectionImportError.invalidCollection("brak nazwy.")
        }

        var sourcePublicationIDs = Set<String>()
        var mappedPublicationIDs = Set<UUID>()
        for publication in payload.publications {
            let id = publication.id.trimmed
            guard !id.isEmpty else {
                throw CollectionImportError.invalidPublication("brak identyfikatora.")
            }
            guard sourcePublicationIDs.insert(id).inserted,
                  mappedPublicationIDs.insert(publicationUUID(for: id)).inserted else {
                throw CollectionImportError.duplicatePublicationID(id)
            }
            guard PublicationType(rawValue: publication.type) != nil else {
                throw CollectionImportError.invalidPublication(
                    "„\(id)” ma nieobsługiwany typ „\(publication.type)”."
                )
            }
            guard !publication.title.trimmed.isEmpty else {
                throw CollectionImportError.invalidPublication("„\(id)” nie ma tytułu.")
            }
            if let year = publication.publicationYear, !(1...9999).contains(year) {
                throw CollectionImportError.invalidPublication(
                    "„\(id)” ma nieprawidłowy rok wydania."
                )
            }
            if let rawEAN = publication.identifiers.ean?.trimmed.nilIfBlank {
                if rawEAN.count != 13 || !rawEAN.allSatisfy(\.isNumber) {
                    throw CollectionImportError.invalidPublication(
                        "„\(id)” ma nieprawidłowe pole ean. " +
                            "Pole ean może zawierać wyłącznie 13 cyfr; pełny kod z dodatkiem zapisz w barcode."
                    )
                }

                if let rawBarcode = publication.identifiers.barcode?.trimmed.nilIfBlank,
                   let barcodeMainEAN = periodicalCompositeMainEAN(from: rawBarcode),
                   normalizedEANForComparison(rawEAN) != barcodeMainEAN {
                    throw CollectionImportError.invalidPublication(
                        "„\(id)” ma niespójne identyfikatory: EAN „\(rawEAN)” nie zgadza się " +
                            "z głównym kodem „\(barcodeMainEAN)” zapisanym w barcode."
                    )
                }
            }
        }

        let validLocationTypes = Set(["home", "room", "bookcase", "shelf", "box", "other"])
        var locationsByID: [String: ImportLocation] = [:]
        for location in payload.locations {
            let id = location.id.trimmed
            guard !id.isEmpty else {
                throw CollectionImportError.invalidLocation("brak identyfikatora.")
            }
            guard locationsByID[id] == nil else {
                throw CollectionImportError.duplicateLocationID(id)
            }
            guard !location.name.trimmed.isEmpty else {
                throw CollectionImportError.invalidLocation("„\(id)” nie ma nazwy.")
            }
            guard validLocationTypes.contains(location.type) else {
                throw CollectionImportError.invalidLocation(
                    "„\(id)” ma nieobsługiwany typ „\(location.type)”."
                )
            }
            if let parentID = location.parentId, parentID.trimmed.isEmpty {
                throw CollectionImportError.invalidLocation(
                    "„\(id)” ma pusty identyfikator lokalizacji nadrzędnej."
                )
            }
            locationsByID[id] = location
        }

        for (id, location) in locationsByID {
            guard let parentID = location.parentId?.trimmed.nilIfBlank else { continue }
            guard locationsByID[parentID] != nil else {
                throw CollectionImportError.missingLocationParent(
                    locationID: id,
                    parentID: parentID
                )
            }
        }
        try validateLocationCycles(locationsByID)

        var sourceItemIDs = Set<String>()
        var mappedItemIDs = Set<UUID>()
        var referencedPublicationIDs = Set<String>()
        for item in payload.ownedItems {
            let id = item.id.trimmed
            let publicationID = item.publicationId.trimmed
            guard !id.isEmpty else {
                throw CollectionImportError.invalidOwnedItem("brak identyfikatora.")
            }
            guard sourceItemIDs.insert(id).inserted,
                  mappedItemIDs.insert(ownedItemUUID(for: id)).inserted else {
                throw CollectionImportError.duplicateOwnedItemID(id)
            }
            guard !publicationID.isEmpty else {
                throw CollectionImportError.invalidOwnedItem("„\(id)” nie wskazuje publikacji.")
            }
            guard sourcePublicationIDs.contains(publicationID) else {
                throw CollectionImportError.missingPublication(
                    itemID: id,
                    publicationID: publicationID
                )
            }
            referencedPublicationIDs.insert(publicationID)
            guard OwnedItemStatus(rawValue: item.status) != nil else {
                throw CollectionImportError.invalidOwnedItem(
                    "„\(id)” ma nieobsługiwany status „\(item.status)”."
                )
            }
            if item.locationPath.contains(where: { $0.trimmed.isEmpty }) {
                throw CollectionImportError.invalidOwnedItem(
                    "„\(id)” ma pusty element ścieżki lokalizacji."
                )
            }
            if let rawLocationID = item.locationId {
                let locationID = rawLocationID.trimmed
                guard !locationID.isEmpty else {
                    throw CollectionImportError.invalidOwnedItem(
                        "„\(id)” ma pusty identyfikator lokalizacji."
                    )
                }
                guard locationsByID[locationID] != nil else {
                    throw CollectionImportError.missingLocation(
                        itemID: id,
                        locationID: locationID
                    )
                }
            }
        }

        if let orphanID = sourcePublicationIDs
            .subtracting(referencedPublicationIDs)
            .sorted()
            .first {
            throw CollectionImportError.invalidPublication(
                "„\(orphanID)” nie ma żadnego egzemplarza; taki rekord nie może zostać zachowany w eksporcie iOS."
            )
        }

        return ValidatedImport(
            collectionID: collectionID,
            collectionName: collectionName,
            publications: payload.publications,
            ownedItems: payload.ownedItems,
            locationsByID: locationsByID
        )
    }

    /// In canonical v1 a full periodical barcode is one atomic observation:
    /// `ean` stores its 13-digit main code and `barcode` stores `main+addon`.
    /// Arbitrary legacy raw barcodes remain tolerated because they do not parse
    /// as a valid EAN-977 composite.
    private static func periodicalCompositeMainEAN(from rawBarcode: String) -> String? {
        let parsed = PublicationIdentifierParser.parse(rawBarcode)
        guard parsed.isValid,
              parsed.kind == .ean13,
              parsed.normalized.hasPrefix("977"),
              let supplement = parsed.eanSupplement,
              supplement.count == 2 || supplement.count == 5 else {
            return nil
        }
        return parsed.normalized
    }

    private static func normalizedEANForComparison(_ rawEAN: String) -> String {
        let parsed = PublicationIdentifierParser.parse(rawEAN)
        guard parsed.isValid, parsed.kind == .ean13 else {
            return rawEAN.trimmed
        }
        return parsed.normalized
    }

    private static func validateLocationCycles(
        _ locationsByID: [String: ImportLocation]
    ) throws {
        enum VisitState {
            case visited
        }

        var states: [String: VisitState] = [:]

        for startID in locationsByID.keys.sorted() where states[startID] == nil {
            var chain: [String] = []
            var positionByID: [String: Int] = [:]
            var currentID: String? = startID

            while let id = currentID, states[id] == nil {
                if positionByID[id] != nil {
                    throw CollectionImportError.cyclicLocation(id)
                }
                positionByID[id] = chain.count
                chain.append(id)
                currentID = locationsByID[id]?.parentId?.trimmed.nilIfBlank
            }

            for id in chain {
                states[id] = .visited
            }
        }
    }

    private static func resolvedLocationPath(
        explicitPath: [String],
        locationID: String?,
        locationsByID: [String: ImportLocation]
    ) -> [String] {
        let cleanedPath = explicitPath.map(\.trimmed)
        if !cleanedPath.isEmpty {
            return cleanedPath
        }

        guard var currentID = locationID?.trimmed.nilIfBlank else { return [] }
        var reversedPath: [String] = []

        while let location = locationsByID[currentID] {
            reversedPath.append(location.name.trimmed)
            guard let parentID = location.parentId?.trimmed.nilIfBlank else { break }
            currentID = parentID
        }
        return reversedPath.reversed()
    }

    private static func mappedUUID(for externalID: String, namespace: String) -> UUID {
        let normalized = externalID.trimmed
        if let uuid = UUID(uuidString: normalized) {
            return uuid
        }

        let digest = SHA256.hash(data: Data("\(namespace):\(normalized)".utf8))
        var bytes = Array(digest.prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    private static func decodingDescription(_ error: DecodingError) -> String {
        switch error {
        case .keyNotFound(let key, let context):
            return "Brakuje pola „\(key.stringValue)” w \(pathDescription(context.codingPath))."
        case .typeMismatch(_, let context), .valueNotFound(_, let context), .dataCorrupted(let context):
            return "Nieprawidłowa wartość w \(pathDescription(context.codingPath)): \(context.debugDescription)"
        @unknown default:
            return "Nieznany błąd formatu JSON."
        }
    }

    private static func pathDescription(_ path: [CodingKey]) -> String {
        let value = path.map(\.stringValue).joined(separator: ".")
        return value.isEmpty ? "głównym obiekcie" : "polu „\(value)”"
    }
}

fileprivate struct ValidatedImport: Sendable {
    let collectionID: String
    let collectionName: String
    let publications: [ImportPublication]
    let ownedItems: [ImportOwnedItem]
    let locationsByID: [String: ImportLocation]
}

private struct ImportEnvelope: Decodable {
    let schemaVersion: Int
}

private struct ImportCollection: Decodable, Sendable {
    let schemaVersion: Int
    let exportedAt: Date
    let collection: ImportCollectionMetadata
    let locations: [ImportLocation]
    let publications: [ImportPublication]
    let ownedItems: [ImportOwnedItem]
}

private struct ImportCollectionMetadata: Decodable, Sendable {
    let id: String
    let name: String
}

fileprivate struct ImportLocation: Decodable, Sendable {
    let id: String
    let name: String
    let type: String
    let parentId: String?
}

fileprivate struct ImportPublication: Decodable, Sendable {
    let id: String
    let type: String
    let title: String
    let subtitle: String?
    let authors: [String]
    let language: String?
    let publisher: String?
    let publicationYear: Int?
    let identifiers: ImportIdentifiers
    let issue: ImportIssue?
    let metadata: ImportMetadata?
    let createdAt: Date
    let updatedAt: Date
}

private struct ImportIdentifiers: Decodable, Sendable {
    let isbn13: String?
    let issn: String?
    let ean: String?
    let barcode: String?
}

private struct ImportIssue: Decodable, Sendable {
    let number: String?
    let volume: String?
    let date: String?
}

private struct ImportMetadata: Decodable, Sendable {
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

fileprivate struct ImportOwnedItem: Decodable, Sendable {
    let id: String
    let publicationId: String
    let locationId: String?
    let locationPath: [String]
    let status: String
    let notes: String?
    let addedAt: Date
    let updatedAt: Date
}

private extension String {
    var trimmed: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var nilIfBlank: String? {
        trimmed.isEmpty ? nil : trimmed
    }
}
