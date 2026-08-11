import SwiftData
import SwiftUI

struct AddItemFlow: View {
    private enum Step {
        case scanner
        case form
    }

    private enum MetadataLookupState: Equatable {
        case idle
        case loading
        case enriched(BookMetadataSource)
        case noMatch
        case failed
    }

    private struct FormSnapshot {
        let title: String
        let subtitle: String
        let authors: String
        let publisher: String
        let publicationYear: String
        let language: String
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    @State private var step: Step
    @State private var publicationType: PublicationType = .book
    @State private var title = ""
    @State private var subtitle = ""
    @State private var authors = ""
    @State private var language = "pl"
    @State private var publisher = ""
    @State private var publicationYear = ""
    @State private var isbn13 = ""
    @State private var issn = ""
    @State private var ean = ""
    @State private var barcode = ""
    @State private var issueNumber = ""
    @State private var issueVolume = ""
    @State private var issueDate = ""
    @State private var locationPath = ""
    @State private var notes = ""
    @State private var metadataSource = "manual"
    @State private var validationMessage: String?
    @State private var metadataLookupState: MetadataLookupState = .idle
    @State private var metadataLookupTask: Task<Void, Never>?
    @State private var metadataLookupISBN: String?

    private let metadataProvider: any BookMetadataProviding

    init(
        startWithScanner: Bool,
        metadataProvider: any BookMetadataProviding = CascadingBookMetadataProvider()
    ) {
        _step = State(initialValue: startWithScanner ? .scanner : .form)
        self.metadataProvider = metadataProvider
    }

    var body: some View {
        NavigationStack {
            switch step {
            case .scanner:
                ScannerStep { value, cameFromCamera in
                    let scannedISBN = apply(identifier: value)
                    metadataSource = cameFromCamera ? "scan" : "manual"
                    step = .form
                    if let scannedISBN {
                        lookupMetadata(for: scannedISBN)
                    }
                }
                .navigationTitle("Skanuj kod")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Anuluj") { dismiss() }
                    }
                }

            case .form:
                form
                    .navigationTitle(metadataSource == "manual" ? "Nowa publikacja" : "Sprawdź publikację")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Anuluj") { dismiss() }
                        }
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Zapisz", action: save)
                                .fontWeight(.semibold)
                                .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    }
            }
        }
        .interactiveDismissDisabled(step == .form && hasEnteredData)
        .onDisappear {
            metadataLookupTask?.cancel()
        }
        .alert("Sprawdź dane", isPresented: Binding(
            get: { validationMessage != nil },
            set: { if !$0 { validationMessage = nil } }
        )) {
            Button("OK", role: .cancel) { validationMessage = nil }
        } message: {
            Text(validationMessage ?? "")
        }
    }

    private var form: some View {
        Form {
            metadataStatusSection

            Section("Rodzaj") {
                Picker("Rodzaj publikacji", selection: $publicationType) {
                    ForEach(PublicationType.allCases) { type in
                        Label(type.label, systemImage: type.symbolName).tag(type)
                    }
                }
                .pickerStyle(.segmented)
            }

            Section("Opis") {
                TextField("Tytuł", text: $title)
                TextField("Podtytuł", text: $subtitle)
                TextField("Autorzy (oddziel średnikiem)", text: $authors, axis: .vertical)
                TextField("Wydawca", text: $publisher)
                HStack {
                    TextField("Rok wydania", text: $publicationYear)
                        .keyboardType(.numberPad)
                    TextField("Język, np. pl", text: $language)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
            }

            Section("Identyfikatory") {
                TextField("ISBN-13", text: $isbn13)
                    .keyboardType(.numbersAndPunctuation)
                    .onChange(of: isbn13) { _, newValue in
                        handleISBNChange(newValue)
                    }
                Button {
                    lookupMetadata(for: isbn13)
                } label: {
                    Label(
                        metadataLookupState == .loading ? "Pobieranie danych…" : "Pobierz dane z katalogów",
                        systemImage: "text.magnifyingglass"
                    )
                }
                .disabled(normalizedISBN(isbn13) == nil || metadataLookupState == .loading)
                if publicationType == .periodical {
                    TextField("ISSN", text: $issn)
                        .keyboardType(.numbersAndPunctuation)
                }
                TextField("EAN", text: $ean)
                    .keyboardType(.numberPad)
                if !barcode.isEmpty {
                    LabeledContent("Zeskanowany kod", value: barcode)
                        .font(.caption)
                }
            }

            if publicationType == .periodical {
                Section {
                    TextField("Numer, np. 8/2026", text: $issueNumber)
                    TextField("Rocznik / tom", text: $issueVolume)
                    TextField("Data, np. 2026-08", text: $issueDate)
                } header: {
                    Text("Konkretny numer")
                } footer: {
                    Text("ISSN opisuje tytuł ciągły, dlatego numer lub datę egzemplarza zapisujemy osobno.")
                }
            }

            Section {
                TextField("Dom / Pokój / Regał / Półka", text: $locationPath)
                    .textInputAutocapitalization(.words)
                TextField("Notatki", text: $notes, axis: .vertical)
                    .lineLimit(2...5)
            } header: {
                Text("Fizyczny egzemplarz")
            } footer: {
                Text("Ukośniki tworzą hierarchię lokalizacji, np. Dom / Gabinet / Regał A / Półka 2.")
            }
        }
    }

    @ViewBuilder
    private var metadataStatusSection: some View {
        switch metadataLookupState {
        case .idle:
            EmptyView()
        case .loading:
            Section {
                HStack(spacing: 12) {
                    ProgressView()
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Pobieram opis z katalogów bibliograficznych…")
                        Text("Najpierw sprawdzam BN, a potem Open Library. Możesz już poprawiać dane ręcznie.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        case .enriched(let source):
            Section {
                Label("Uzupełniono dostępne dane z \(source.displayName).", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
        case .noMatch:
            Section {
                metadataFallbackMessage(
                    "Nie znaleziono tego ISBN w BN ani Open Library. Możesz kontynuować ręcznie."
                )
            }
        case .failed:
            Section {
                metadataFallbackMessage(
                    "Nie udało się teraz pobrać danych. Możesz kontynuować ręcznie."
                )
            }
        }
    }

    private func metadataFallbackMessage(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(message, systemImage: "info.circle")
                .foregroundStyle(.secondary)
            Button("Spróbuj ponownie") {
                lookupMetadata(for: isbn13)
            }
            .disabled(isbn13.isEmpty)
        }
    }

    private var hasEnteredData: Bool {
        !title.isEmpty || !authors.isEmpty || !barcode.isEmpty || !locationPath.isEmpty
    }

    @discardableResult
    private func apply(identifier rawValue: String) -> String? {
        let parsed = PublicationIdentifierParser.parse(rawValue)
        barcode = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)

        switch parsed.kind {
        case .isbn10 where parsed.isValid,
             .isbn13 where parsed.isValid:
            let normalizedISBN = parsed.isbn13 ?? parsed.normalized
            isbn13 = normalizedISBN
            ean = normalizedISBN
            return normalizedISBN
        case .ean13 where parsed.isValid:
            ean = parsed.normalized
            if let parsedISSN = parsed.issn {
                publicationType = .periodical
                issn = parsedISSN
            }
        case .upce:
            ean = parsed.normalized
        default:
            break
        }
        return nil
    }

    private func lookupMetadata(for isbn: String) {
        metadataLookupTask?.cancel()
        guard let requestedISBN = normalizedISBN(isbn) else {
            metadataLookupISBN = nil
            metadataLookupState = .failed
            return
        }
        metadataLookupISBN = requestedISBN
        metadataLookupState = .loading
        let snapshot = FormSnapshot(
            title: title,
            subtitle: subtitle,
            authors: authors,
            publisher: publisher,
            publicationYear: publicationYear,
            language: language
        )

        metadataLookupTask = Task {
            do {
                let metadata = try await metadataProvider.lookup(isbn: requestedISBN)
                try Task.checkCancellation()
                guard metadataLookupISBN == requestedISBN,
                      normalizedISBN(isbn13) == requestedISBN else {
                    return
                }
                guard let metadata else {
                    metadataLookupState = .noMatch
                    return
                }

                apply(metadata: metadata, preservingChangesSince: snapshot)
                metadataSource = metadata.source.rawValue
                metadataLookupState = .enriched(metadata.source)
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled,
                      metadataLookupISBN == requestedISBN,
                      normalizedISBN(isbn13) == requestedISBN else {
                    return
                }
                metadataLookupState = .failed
            }
        }
    }

    private func handleISBNChange(_ value: String) {
        guard let lookupISBN = metadataLookupISBN,
              normalizedISBN(value) != lookupISBN else {
            return
        }

        metadataLookupTask?.cancel()
        metadataLookupTask = nil
        metadataLookupISBN = nil
        metadataLookupState = .idle
        if metadataSource == BookMetadataSource.nationalLibrary.rawValue ||
            metadataSource == BookMetadataSource.openLibrary.rawValue {
            metadataSource = "manual"
        }
    }

    private func normalizedISBN(_ value: String) -> String? {
        let parsed = PublicationIdentifierParser.parse(value)
        guard parsed.isValid,
              parsed.kind == .isbn10 || parsed.kind == .isbn13 else {
            return nil
        }
        return parsed.isbn13 ?? parsed.normalized
    }

    private func apply(metadata: BookMetadata, preservingChangesSince snapshot: FormSnapshot) {
        if title == snapshot.title, let value = metadata.title {
            title = value
        }
        if subtitle == snapshot.subtitle, let value = metadata.subtitle {
            subtitle = value
        }
        if authors == snapshot.authors, !metadata.authors.isEmpty {
            authors = metadata.authors.joined(separator: "; ")
        }
        if publisher == snapshot.publisher, let value = metadata.publisher {
            publisher = value
        }
        if publicationYear == snapshot.publicationYear, let value = metadata.publicationYear {
            publicationYear = String(value)
        }
        if language == snapshot.language, let value = metadata.language {
            language = value
        }
    }

    private func save() {
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanTitle.isEmpty else {
            validationMessage = "Tytuł jest wymagany."
            return
        }

        let cleanYear = publicationYear.trimmingCharacters(in: .whitespacesAndNewlines)
        let year: Int?
        if cleanYear.isEmpty {
            year = nil
        } else if let value = Int(cleanYear), (1...9999).contains(value) {
            year = value
        } else {
            validationMessage = "Rok wydania powinien być liczbą od 1 do 9999."
            return
        }

        var normalizedISBN = isbn13.trimmingCharacters(in: .whitespacesAndNewlines)
        if !normalizedISBN.isEmpty {
            let parsed = PublicationIdentifierParser.parse(normalizedISBN)
            guard parsed.isValid, parsed.kind == .isbn10 || parsed.kind == .isbn13 else {
                validationMessage = "ISBN ma nieprawidłową długość lub cyfrę kontrolną."
                return
            }
            normalizedISBN = parsed.isbn13 ?? parsed.normalized
        }

        var normalizedEAN = ean.trimmingCharacters(in: .whitespacesAndNewlines)
        if !normalizedEAN.isEmpty {
            let parsed = PublicationIdentifierParser.parse(normalizedEAN)
            if parsed.kind == .ean13 || parsed.kind == .isbn13 {
                guard parsed.isValid else {
                    validationMessage = "EAN-13 ma nieprawidłową cyfrę kontrolną."
                    return
                }
                normalizedEAN = parsed.normalized
            }
        }

        let now = Date.now
        let publication = Publication(
            type: publicationType,
            title: cleanTitle,
            subtitle: subtitle.trimmingCharacters(in: .whitespacesAndNewlines),
            authorsText: authors.trimmingCharacters(in: .whitespacesAndNewlines),
            language: language.trimmingCharacters(in: .whitespacesAndNewlines),
            publisher: publisher.trimmingCharacters(in: .whitespacesAndNewlines),
            publicationYear: year,
            isbn13: normalizedISBN,
            issn: issn.trimmingCharacters(in: .whitespacesAndNewlines),
            ean: normalizedEAN,
            barcode: barcode,
            issueNumber: issueNumber.trimmingCharacters(in: .whitespacesAndNewlines),
            issueVolume: issueVolume.trimmingCharacters(in: .whitespacesAndNewlines),
            issueDate: issueDate.trimmingCharacters(in: .whitespacesAndNewlines),
            metadataSource: metadataSource,
            createdAt: now,
            updatedAt: now
        )
        let item = OwnedItem(
            publication: publication,
            locationPathText: locationPath.trimmingCharacters(in: .whitespacesAndNewlines),
            notes: notes.trimmingCharacters(in: .whitespacesAndNewlines),
            addedAt: now,
            updatedAt: now
        )

        modelContext.insert(publication)
        modelContext.insert(item)
        do {
            try modelContext.save()
            dismiss()
        } catch {
            validationMessage = "Nie udało się zapisać publikacji: \(error.localizedDescription)"
        }
    }
}
