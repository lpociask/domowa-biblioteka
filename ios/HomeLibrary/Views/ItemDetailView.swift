import SwiftUI

struct ItemDetailView: View {
    let item: OwnedItem

    var body: some View {
        ZStack {
            PaperBackground()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: LibrarySpacing.large) {
                    publicationHeader

                    EditorialStatusBand(
                        title: "Lokalizacja",
                        message: item.locationDisplayName,
                        icon: "mappin.and.ellipse"
                    )

                    copyDetails

                    if let publication = item.publication {
                        publicationDetails(publication)
                    }

                    folio
                }
                .editorialPage(width: 820)
                .padding(.top, LibrarySpacing.medium)
                .padding(.bottom, LibrarySpacing.xLarge)
            }
            .scrollIndicators(.hidden)
        }
        .navigationTitle("Egzemplarz")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(LibraryPalette.paper, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarColorScheme(.light, for: .navigationBar)
        .libraryLightAppearance()
        .tint(LibraryPalette.ink)
    }

    @ViewBuilder
    private var publicationHeader: some View {
        if let publication = item.publication {
            LibraryMasthead(
                title: clean(publication.title) ?? "Bez tytułu",
                eyebrow: headerKicker(for: publication),
                subtitle: headerSubtitle(for: publication)
            )
        } else {
            LibraryMasthead(
                title: "Egzemplarz",
                eyebrow: "KARTA KOLEKCJI",
                subtitle: "Brak powiązanego opisu publikacji."
            )
        }
    }

    private var copyDetails: some View {
        detailSection(title: "Egzemplarz", value: item.status.label) {
            EditorialMetadataRow(label: "Status", value: item.status.label)
            EditorialMetadataRow(
                label: "Dodano",
                value: item.addedAt.formatted(date: .long, time: .shortened)
            )

            if let notes = clean(item.notes) {
                EditorialMetadataRow(label: "Notatki", value: notes)
            }
        }
    }

    @ViewBuilder
    private func publicationDetails(_ publication: Publication) -> some View {
        if hasEditionDetails(publication) {
            detailSection(title: "Wydanie") {
                if let publisher = clean(publication.publisher) {
                    EditorialMetadataRow(label: "Wydawca", value: publisher)
                }
                if let year = publication.publicationYear {
                    EditorialMetadataRow(label: "Rok", value: String(year))
                }
                if let language = clean(publication.language) {
                    EditorialMetadataRow(label: "Język", value: language)
                }
                if let source = metadataSourceLabel(publication.metadataSource) {
                    EditorialMetadataRow(label: "Źródło danych", value: source)
                }
            }
        }

        if publication.publicationType == .periodical, hasIssueDetails(publication) {
            detailSection(title: "Numer prasy") {
                if let issueNumber = clean(publication.issueNumber) {
                    EditorialMetadataRow(label: "Numer", value: issueNumber)
                }
                if let issueVolume = clean(publication.issueVolume) {
                    EditorialMetadataRow(label: "Rocznik / tom", value: issueVolume)
                }
                if let issueDate = clean(publication.issueDate) {
                    EditorialMetadataRow(label: "Data", value: issueDate)
                }
            }
        }

        if hasIdentifiers(publication) {
            detailSection(title: "Identyfikatory") {
                if let isbn = clean(publication.isbn13) {
                    EditorialMetadataRow(label: "ISBN-13", value: isbn, monospaced: true)
                }
                if let issn = clean(publication.issn) {
                    EditorialMetadataRow(label: "ISSN", value: issn, monospaced: true)
                }
                if let ean = clean(publication.ean) {
                    EditorialMetadataRow(label: "EAN", value: ean, monospaced: true)
                }
                if let barcode = clean(publication.barcode), barcode != clean(publication.ean) {
                    EditorialMetadataRow(label: "Kod źródłowy", value: barcode, monospaced: true)
                }
            }
        }
    }

    private func detailSection<Content: View>(
        title: String,
        value: String? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: LibrarySpacing.small) {
            EditorialSectionHeader(title: title, value: value)

            VStack(alignment: .leading, spacing: 0) {
                content()

                Rectangle()
                    .fill(LibraryPalette.rule)
                    .frame(height: 1)
                    .accessibilityHidden(true)
            }
        }
    }

    private var folio: some View {
        HStack(alignment: .firstTextBaseline, spacing: LibrarySpacing.small) {
            Text("DOMOWA BIBLIOTEKA")
                .font(.caption2.weight(.bold))
                .tracking(1.55)

            Spacer(minLength: LibrarySpacing.small)

            Text(item.addedAt.formatted(date: .numeric, time: .omitted))
                .font(.caption.monospacedDigit())
        }
        .foregroundStyle(LibraryPalette.mutedInk)
        .padding(.top, LibrarySpacing.medium)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(LibraryPalette.ink)
                .frame(height: 1)
        }
        .accessibilityElement(children: .combine)
    }

    private func headerKicker(for publication: Publication) -> String {
        let type = publication.publicationType.label.uppercased()
        guard let identifier = primaryIdentifier(for: publication) else {
            return type
        }
        return "\(type)  ·  \(identifier)"
    }

    private func headerSubtitle(for publication: Publication) -> String? {
        [clean(publication.authors.joined(separator: ", ")), clean(publication.subtitle)]
            .compactMap { $0 }
            .joined(separator: "\n")
            .nilIfEmpty
    }

    private func primaryIdentifier(for publication: Publication) -> String? {
        if let isbn = clean(publication.isbn13) {
            return "ISBN \(isbn)"
        }
        if let issn = clean(publication.issn) {
            return "ISSN \(issn)"
        }
        if let ean = clean(publication.ean) {
            return "EAN \(ean)"
        }
        if let barcode = clean(publication.barcode) {
            return barcode
        }
        return nil
    }

    private func hasEditionDetails(_ publication: Publication) -> Bool {
        clean(publication.publisher) != nil
            || publication.publicationYear != nil
            || clean(publication.language) != nil
            || metadataSourceLabel(publication.metadataSource) != nil
    }

    private func hasIssueDetails(_ publication: Publication) -> Bool {
        clean(publication.issueNumber) != nil
            || clean(publication.issueVolume) != nil
            || clean(publication.issueDate) != nil
    }

    private func hasIdentifiers(_ publication: Publication) -> Bool {
        clean(publication.isbn13) != nil
            || clean(publication.issn) != nil
            || clean(publication.ean) != nil
            || clean(publication.barcode) != nil
    }

    private func metadataSourceLabel(_ source: String) -> String? {
        switch clean(source)?.lowercased() {
        case "manual":
            "Wpis ręczny"
        case "scan":
            "Skan kodu"
        case BookMetadataSource.nationalLibrary.rawValue:
            "Biblioteka Narodowa"
        case BookMetadataSource.openLibrary.rawValue:
            "Open Library"
        case "import":
            "Import kolekcji"
        case .some:
            clean(source)
        case .none:
            nil
        }
    }

    private func clean(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

private struct EditorialMetadataRow: View {
    let label: String
    let value: String
    var monospaced = false

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: LibrarySpacing.medium) {
                rowLabel
                    .frame(minWidth: 112, alignment: .leading)

                Spacer(minLength: LibrarySpacing.small)

                rowValue
                    .multilineTextAlignment(.trailing)
            }

            VStack(alignment: .leading, spacing: 7) {
                rowLabel
                rowValue
            }
        }
        .foregroundStyle(LibraryPalette.ink)
        .padding(.vertical, 14)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(LibraryPalette.rule)
                .frame(height: 1)
                .accessibilityHidden(true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(label)
        .accessibilityValue(value)
    }

    private var rowLabel: some View {
        Text(label.uppercased())
            .font(.caption2.weight(.bold))
            .tracking(1.25)
            .foregroundStyle(LibraryPalette.mutedInk)
    }

    @ViewBuilder
    private var rowValue: some View {
        if monospaced {
            Text(value)
                .font(.body.monospacedDigit())
                .textSelection(.enabled)
        } else {
            Text(value)
                .font(.system(.body, design: .serif))
                .lineSpacing(3)
                .textSelection(.enabled)
        }
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
