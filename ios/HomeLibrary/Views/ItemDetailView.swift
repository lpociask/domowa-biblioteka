import SwiftUI

struct ItemDetailView: View {
    let item: OwnedItem

    var body: some View {
        List {
            if let publication = item.publication {
                Section("Publikacja") {
                    LabeledContent("Rodzaj", value: publication.publicationType.label)
                    LabeledContent("Tytuł", value: publication.title)
                    optionalRow("Podtytuł", publication.subtitle)
                    optionalRow("Autorzy", publication.authorsText)
                    optionalRow("Wydawca", publication.publisher)
                    if let year = publication.publicationYear {
                        LabeledContent("Rok", value: String(year))
                    }
                    optionalRow("Język", publication.language)
                }

                if publication.publicationType == .periodical {
                    Section("Numer prasy") {
                        optionalRow("Numer", publication.issueNumber)
                        optionalRow("Rocznik / tom", publication.issueVolume)
                        optionalRow("Data", publication.issueDate)
                    }
                }

                Section("Identyfikatory") {
                    optionalRow("ISBN-13", publication.isbn13)
                    optionalRow("ISSN", publication.issn)
                    optionalRow("EAN", publication.ean)
                    optionalRow("Kod źródłowy", publication.barcode)
                }
            }

            Section("Egzemplarz") {
                LabeledContent("Lokalizacja", value: item.locationDisplayName)
                LabeledContent("Status", value: item.status.label)
                if !item.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    LabeledContent("Notatki", value: item.notes)
                }
                LabeledContent("Dodano", value: item.addedAt.formatted(date: .abbreviated, time: .shortened))
            }
        }
        .navigationTitle(item.publication?.title ?? "Egzemplarz")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private func optionalRow(_ label: String, _ value: String) -> some View {
        if !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            LabeledContent(label, value: value)
        }
    }
}
