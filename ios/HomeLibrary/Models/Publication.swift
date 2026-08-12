import Foundation
import SwiftData

enum PublicationType: String, Codable, CaseIterable, Identifiable {
    case book
    case periodical

    var id: String { rawValue }

    var label: String {
        switch self {
        case .book: "Książka"
        case .periodical: "Prasa"
        }
    }

    var symbolName: String {
        switch self {
        case .book: "book.closed"
        case .periodical: "newspaper"
        }
    }
}

enum PublicationCoverAsset: Equatable, Sendable {
    case local(Data)
    case remote(URL)
}

@Model
final class Publication {
    var id: UUID
    /// Identyfikator z formatu wymiany. Może być UUID albo stabilnym tekstem
    /// nadanym przez innego klienta, np. stronę WWW.
    var externalID: String = ""
    var typeRawValue: String
    var title: String
    var subtitle: String
    /// Autorzy rozdzieleni średnikiem. W eksporcie stają się tablicą.
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
    /// Data numeru w postaci czytelnej dla człowieka, np. "2026-08".
    var issueDate: String
    var metadataSource: String
    /// Przenośna referencja do okładki. Sam plik obrazu pozostaje w lokalnym cache.
    var coverURLString: String = ""
    /// Pochodzenie okładki niezależne od źródła pozostałych metadanych.
    var coverSource: String = ""
    /// Sanitized local JPEG. External storage keeps the SwiftData row small and
    /// lets the persistent store manage the binary asset transactionally.
    @Attribute(.externalStorage) var coverImageData: Data? = nil
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        externalID: String? = nil,
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
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        let cleanExternalID = externalID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.externalID = cleanExternalID.isEmpty ? id.uuidString : cleanExternalID
        self.typeRawValue = type.rawValue
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
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    var publicationType: PublicationType {
        get { PublicationType(rawValue: typeRawValue) ?? .book }
        set { typeRawValue = newValue.rawValue }
    }

    var authors: [String] {
        authorsText
            .split(whereSeparator: { $0 == ";" || $0 == "\n" })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    var exportID: String {
        let clean = externalID.trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty ? id.uuidString : clean
    }

    var resolvedCoverImageData: Data? {
        coverImageData.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Local data always wins for on-device presentation. A remote reference
    /// remains available as a fallback after the local image is removed.
    var resolvedCoverAsset: PublicationCoverAsset? {
        if let data = resolvedCoverImageData {
            return .local(data)
        }
        if let url = resolvedCoverURL {
            return .remote(url)
        }
        return nil
    }

    var hasResolvedCover: Bool {
        resolvedCoverAsset != nil
    }

    /// Uses an explicitly accepted URL first. Older records with only an ISBN
    /// still gain a deterministic Open Library cover without mutating the model.
    var resolvedCoverURL: URL? {
        if let explicitURL = RemoteCoverURLPolicy.validatedReference(coverURLString),
           RemoteCoverURLPolicy.canLoadAutomatically(explicitURL) {
            return explicitURL
        }
        return OpenLibraryCoverURL.url(forISBN: isbn13)
    }

    var resolvedCoverSource: String? {
        if let explicitURL = RemoteCoverURLPolicy.validatedReference(coverURLString),
           RemoteCoverURLPolicy.canLoadAutomatically(explicitURL) {
            let clean = coverSource.trimmingCharacters(in: .whitespacesAndNewlines)
            return clean.isEmpty ? nil : clean
        }
        return resolvedCoverURL == nil ? nil : BookMetadataSource.openLibrary.rawValue
    }

    var exportCoverURL: URL? {
        RemoteCoverURLPolicy.validatedReference(coverURLString)
            ?? OpenLibraryCoverURL.url(forISBN: isbn13)
    }

    var exportCoverSource: String? {
        if RemoteCoverURLPolicy.validatedReference(coverURLString) != nil {
            let clean = coverSource.trimmingCharacters(in: .whitespacesAndNewlines)
            return clean.isEmpty ? nil : clean
        }
        return exportCoverURL == nil ? nil : BookMetadataSource.openLibrary.rawValue
    }
}
