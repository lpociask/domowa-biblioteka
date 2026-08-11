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
    @State private var showsMoreData = false

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

            Section("Najważniejsze dane") {
                TextField("Tytuł publikacji", text: $title)
                    .submitLabel(.next)
                TextField("Autorzy (oddziel średnikiem)", text: $authors, axis: .vertical)
                    .lineLimit(1...3)

                Picker("Rodzaj publikacji", selection: $publicationType) {
                    ForEach(PublicationType.allCases) { type in
                        Label(type.label, systemImage: type.symbolName).tag(type)
                    }
                }
                .pickerStyle(.segmented)
            }

            Section {
                TextField("Dom / Pokój / Regał / Półka", text: $locationPath)
                    .textInputAutocapitalization(.words)
                TextField("Notatki", text: $notes, axis: .vertical)
                    .lineLimit(2...5)
            } header: {
                Label("Gdzie ją odkładasz?", systemImage: "mappin.and.ellipse")
            } footer: {
                Text("Ukośniki tworzą hierarchię, np. Dom / Gabinet / Regał A / Półka 2.")
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
                DisclosureGroup(isExpanded: $showsMoreData) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Opis bibliograficzny")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .accessibilityAddTraits(.isHeader)

                        TextField("Podtytuł", text: $subtitle)
                        TextField("Wydawca", text: $publisher)
                        HStack {
                            TextField("Rok wydania", text: $publicationYear)
                                .keyboardType(.numberPad)
                            TextField("Język, np. pl", text: $language)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                        }

                        Divider()

                        Text("Identyfikatory")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .accessibilityAddTraits(.isHeader)

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
                    .padding(.top, 10)
                    .textFieldStyle(.roundedBorder)
                } label: {
                    Label("Więcej danych", systemImage: "slider.horizontal.3")
                        .font(.headline)
                }
            } footer: {
                Text("Podtytuł, wydawca, rok, język oraz identyfikatory są opcjonalne.")
            }
        }
    }

    @ViewBuilder
    private var metadataStatusSection: some View {
        Section {
            switch metadataLookupState {
            case .idle:
                metadataStatusCard(
                    title: barcode.isEmpty ? "Dodajesz ręcznie" : "Kod zeskanowany",
                    message: barcode.isEmpty
                        ? "Wpisz tytuł i miejsce przechowywania albo zeskanuj kod."
                        : "Sprawdź najważniejsze dane i uzupełnij lokalizację.",
                    systemImage: barcode.isEmpty ? "square.and.pencil" : "barcode",
                    tint: .blue
                ) {
                    rescanButton(title: barcode.isEmpty ? "Skanuj kod" : "Skanuj ponownie")
                }

            case .loading:
                metadataStatusCard(
                    title: "Szukam publikacji",
                    message: "Sprawdzam Bibliotekę Narodową i Open Library. W tym czasie możesz już uzupełniać formularz.",
                    systemImage: "text.magnifyingglass",
                    tint: .blue,
                    showsProgress: true
                ) {
                    rescanButton(title: "Skanuj ponownie")
                }

            case .enriched(let source):
                metadataStatusCard(
                    title: "Dane znalezione",
                    message: "Uzupełniono dostępne informacje z \(source.displayName). Sprawdź je przed zapisem.",
                    systemImage: "checkmark.circle.fill",
                    tint: .green
                ) {
                    rescanButton(title: "Skanuj ponownie")
                }

            case .noMatch:
                metadataStatusCard(
                    title: "Brak rekordu w katalogach",
                    message: "Połączenie działa, ale tego ISBN nie ma w BN ani Open Library. Wpisz dane ręcznie lub zeskanuj kod ponownie.",
                    systemImage: "questionmark.circle.fill",
                    tint: .orange
                ) {
                    metadataRetryAndRescanButtons
                }

            case .failed:
                metadataStatusCard(
                    title: "Problem z połączeniem",
                    message: "Nie udało się pobrać danych z katalogów. Sprawdź internet i spróbuj ponownie — formularz nadal działa ręcznie.",
                    systemImage: "wifi.exclamationmark",
                    tint: .red
                ) {
                    metadataRetryAndRescanButtons
                }
            }
        }
        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }

    private func metadataStatusCard<Actions: View>(
        title: String,
        message: String,
        systemImage: String,
        tint: Color,
        showsProgress: Bool = false,
        @ViewBuilder actions: () -> Actions
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Group {
                    if showsProgress {
                        ProgressView()
                            .tint(tint)
                            .accessibilityLabel("Pobieranie danych")
                    } else {
                        Image(systemName: systemImage)
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(tint)
                            .accessibilityHidden(true)
                    }
                }
                .frame(width: 28, height: 28)

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.headline)
                    Text(message)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            actions()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 16))
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .stroke(tint.opacity(0.24), lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
    }

    private func rescanButton(title: String) -> some View {
        Button {
            startRescan()
        } label: {
            Label(title, systemImage: "barcode.viewfinder")
        }
        .buttonStyle(.bordered)
    }

    private var metadataRetryAndRescanButtons: some View {
        HStack(spacing: 10) {
            Button("Spróbuj ponownie") {
                lookupMetadata(for: isbn13)
            }
            .buttonStyle(.borderedProminent)
            .disabled(normalizedISBN(isbn13) == nil)

            rescanButton(title: "Skanuj ponownie")
        }
    }

    private func startRescan() {
        metadataLookupTask?.cancel()
        metadataLookupTask = nil
        metadataLookupISBN = nil
        metadataLookupState = .idle

        let hadCatalogMetadata = metadataSource == BookMetadataSource.nationalLibrary.rawValue ||
            metadataSource == BookMetadataSource.openLibrary.rawValue
        if hadCatalogMetadata {
            title = ""
            subtitle = ""
            authors = ""
            publisher = ""
            publicationYear = ""
            language = "pl"
        }

        publicationType = .book
        isbn13 = ""
        issn = ""
        ean = ""
        barcode = ""
        issueNumber = ""
        issueVolume = ""
        issueDate = ""
        metadataSource = "manual"
        step = .scanner
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
