import Foundation
import SwiftData

enum OwnedItemStatus: String, Codable, CaseIterable, Identifiable {
    case owned
    case loaned
    case missing
    case archived

    var id: String { rawValue }

    var label: String {
        switch self {
        case .owned: "W kolekcji"
        case .loaned: "Wypożyczone"
        case .missing: "Brak"
        case .archived: "Archiwum"
        }
    }
}

@Model
final class OwnedItem {
    var id: UUID
    /// Identyfikator z formatu wymiany, zachowywany przez pełny round-trip.
    var externalID: String = ""
    var publication: Publication?
    /// Ścieżka rozdzielona ukośnikami, np. "Dom / Gabinet / Regał A / Półka 2".
    var locationPathText: String
    var statusRawValue: String
    var notes: String
    var addedAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        externalID: String? = nil,
        publication: Publication,
        locationPathText: String,
        status: OwnedItemStatus = .owned,
        notes: String = "",
        addedAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        let cleanExternalID = externalID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.externalID = cleanExternalID.isEmpty ? id.uuidString : cleanExternalID
        self.publication = publication
        self.locationPathText = locationPathText
        self.statusRawValue = status.rawValue
        self.notes = notes
        self.addedAt = addedAt
        self.updatedAt = updatedAt
    }

    var status: OwnedItemStatus {
        get { OwnedItemStatus(rawValue: statusRawValue) ?? .owned }
        set { statusRawValue = newValue.rawValue }
    }

    var locationPath: [String] {
        locationPathText
            .split(separator: "/")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    var locationDisplayName: String {
        let components = locationPath
        return components.isEmpty ? "Bez lokalizacji" : components.joined(separator: " › ")
    }

    var exportID: String {
        let clean = externalID.trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty ? id.uuidString : clean
    }
}
