import SwiftData
import SwiftUI

struct AddItemFlow: View {
    private enum Step {
        case scanner
        case form
        case saved
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
    @Query(sort: \OwnedItem.addedAt, order: .reverse) private var existingItems: [OwnedItem]

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
    @State private var catalogingSession = CatalogingSession()
    @State private var notes = ""
    @State private var metadataSource = "manual"
    @State private var validationMessage: String?
    @State private var metadataLookupState: MetadataLookupState = .idle
    @State private var metadataLookupTask: Task<Void, Never>?
    @State private var metadataLookupISBN: String?
    @State private var showsMoreData = false
    @State private var savedTitle = ""
    @State private var savedLocation = ""
    @State private var savedCopyCount = 1
    @State private var savedUsedExistingPublication = false

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
            ZStack {
                PaperBackground()

                switch step {
                case .scanner:
                    scanner
                case .form:
                    form
                case .saved:
                    savedConfirmation
                }
            }
            .foregroundStyle(LibraryPalette.ink)
            .toolbarBackground(LibraryPalette.paper, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(step == .saved ? "Gotowe" : "Anuluj") {
                        dismiss()
                    }
                    .foregroundStyle(LibraryPalette.ink)
                    .frame(minWidth: 44, minHeight: 44)
                }
            }
        }
        .libraryLightAppearance()
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

    private var scanner: some View {
        ScannerStep(currentLocation: currentLocationDisplay) { value, cameFromCamera in
            let scannedISBN = apply(identifier: value)
            metadataSource = cameFromCamera ? "scan" : "manual"
            step = .form
            if let scannedISBN {
                lookupMetadata(for: scannedISBN)
            }
        }
        .navigationTitle("Skanuj kod")
    }

    private var form: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: LibrarySpacing.xLarge) {
                LibraryMasthead(
                    title: metadataSource == "manual" ? "Nowa publikacja" : "Sprawdź publikację",
                    eyebrow: "KATALOGOWANIE · 02/03",
                    subtitle: "Najpierw opis, potem miejsce na półce. Dane z katalogu zawsze możesz poprawić.",
                    compact: true
                )

                metadataStatus

                if let duplicateMatch {
                    EditorialStatusBand(
                        title: "Kolejny egzemplarz",
                        message: duplicateMessage(for: duplicateMatch),
                        icon: "square.on.square",
                        accent: LibraryPalette.orangeText
                    )
                }

                if let duplicateMatch {
                    existingPublicationSection(duplicateMatch)
                } else {
                    mainDataSection
                }
                locationSection

                if duplicateMatch == nil, publicationType == .periodical {
                    periodicalSection
                }

                if duplicateMatch == nil {
                    moreDataSection
                }
            }
            .padding(.vertical, LibrarySpacing.medium)
            .editorialPage(width: 760)
        }
        .scrollDismissesKeyboard(.interactively)
        .safeAreaInset(edge: .bottom) {
            saveBar
        }
        .navigationTitle("Dodaj do kolekcji")
    }

    private var mainDataSection: some View {
        VStack(alignment: .leading, spacing: LibrarySpacing.medium) {
            EditorialSectionHeader(title: "Najważniejsze dane", value: "01")

            EditorialLabeledTextField(
                label: "Tytuł publikacji",
                text: $title,
                prompt: "Wpisz tytuł"
            )

            EditorialAxisField(
                label: "Autorzy",
                text: $authors,
                prompt: "Oddziel autorów średnikiem",
                lineLimit: 1...3
            )

            EditorialPublicationTypeSelector(
                label: "Rodzaj publikacji",
                selection: $publicationType,
                options: PublicationType.allCases.map {
                    EditorialSelectionOption(value: $0, title: $0.label, symbol: $0.symbolName)
                }
            )
        }
    }

    private func existingPublicationSection(_ match: ExistingPublicationMatch) -> some View {
        let publication = match.publication
        let identifier = [publication.isbn13, publication.issn, publication.ean]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }

        return VStack(alignment: .leading, spacing: LibrarySpacing.medium) {
            EditorialSectionHeader(title: "Wspólny opis wydania", value: "TYLKO ODCZYT")

            Text(publication.title)
                .font(.system(.title2, design: .serif, weight: .bold))
                .fixedSize(horizontal: false, vertical: true)

            if !publication.authorsText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(publication.authorsText)
                    .font(.system(.body, design: .serif))
                    .foregroundStyle(LibraryPalette.mutedInk)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let identifier {
                Text(identifier)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(LibraryPalette.mutedInk)
            }

            Text("Opis bibliograficzny jest wspólny dla wszystkich kopii, dlatego nie zmieniamy go przy dodawaniu kolejnego egzemplarza. Poniżej uzupełnij tylko miejsce i notatki tej kopii.")
                .font(.system(.footnote, design: .serif))
                .lineSpacing(3)
                .foregroundStyle(LibraryPalette.mutedInk)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(LibrarySpacing.medium)
        .background(LibraryPalette.ink.opacity(0.045))
        .overlay(alignment: .leading) {
            Rectangle().fill(LibraryPalette.orange).frame(width: 4)
        }
        .accessibilityElement(children: .contain)
    }

    private var locationSection: some View {
        VStack(alignment: .leading, spacing: LibrarySpacing.medium) {
            EditorialSectionHeader(title: "Miejsce egzemplarza", value: "02")

            Text("Zapisz drogę od pomieszczenia do półki. Ukośniki budują hierarchię lokalizacji.")
                .font(.system(.body, design: .serif))
                .lineSpacing(3)
                .foregroundStyle(LibraryPalette.mutedInk)

            EditorialLabeledTextField(
                label: "Lokalizacja",
                text: locationTextBinding,
                prompt: "Dom / Gabinet / Regał A / Półka 2"
            )
            .textInputAutocapitalization(.words)

            if !recentLocations.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    Text("OSTATNIE MIEJSCA")
                        .font(.caption2.weight(.bold))
                        .tracking(1.35)
                        .foregroundStyle(LibraryPalette.mutedInk)
                        .padding(.bottom, LibrarySpacing.xSmall)

                    ForEach(recentLocations, id: \.self) { location in
                        Button {
                            catalogingSession.updateLocationText(location)
                        } label: {
                            HStack(spacing: LibrarySpacing.small) {
                                Text(location.replacingOccurrences(of: "/", with: "›"))
                                    .font(.footnote)
                                    .multilineTextAlignment(.leading)
                                Spacer(minLength: LibrarySpacing.small)
                                Image(systemName: LocationPath(catalogingSession.locationText) == LocationPath(location) ? "checkmark" : "arrow.turn.down.left")
                                    .foregroundStyle(LibraryPalette.orangeText)
                                    .accessibilityHidden(true)
                            }
                            .foregroundStyle(LibraryPalette.ink)
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                            .overlay(alignment: .top) {
                                Rectangle().fill(LibraryPalette.rule).frame(height: 1)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Użyj lokalizacji: \(location)")
                    }
                }
            }

            EditorialAxisField(
                label: "Notatki o egzemplarzu",
                text: $notes,
                prompt: "Stan, dedykacja lub inne informacje",
                lineLimit: 2...5
            )
        }
    }

    private var periodicalSection: some View {
        VStack(alignment: .leading, spacing: LibrarySpacing.medium) {
            EditorialSectionHeader(title: "Konkretny numer", value: "PRASA")

            Text("ISSN opisuje cały tytuł prasowy. Numer lub data rozróżniają egzemplarz, który trzymasz w ręku.")
                .font(.system(.body, design: .serif))
                .lineSpacing(3)
                .foregroundStyle(LibraryPalette.mutedInk)

            EditorialLabeledTextField(
                label: "Numer",
                text: $issueNumber,
                prompt: "np. 8/2026"
            )
            EditorialLabeledTextField(
                label: "Rocznik / tom",
                text: $issueVolume,
                prompt: "np. XLII"
            )
            EditorialLabeledTextField(
                label: "Data numeru",
                text: $issueDate,
                prompt: "np. 2026-08"
            )
        }
    }

    private var moreDataSection: some View {
        VStack(alignment: .leading, spacing: LibrarySpacing.medium) {
            DisclosureGroup(isExpanded: $showsMoreData) {
                VStack(alignment: .leading, spacing: LibrarySpacing.medium) {
                    EditorialLabeledTextField(label: "Podtytuł", text: $subtitle, prompt: "Opcjonalnie")
                    EditorialLabeledTextField(label: "Wydawca", text: $publisher, prompt: "Opcjonalnie")

                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .top, spacing: LibrarySpacing.small) {
                            yearField
                            languageField
                        }
                        VStack(alignment: .leading, spacing: LibrarySpacing.medium) {
                            yearField
                            languageField
                        }
                    }

                    EditorialSectionHeader(title: "Identyfikatory", value: nil, accent: nil)

                    EditorialLabeledTextField(
                        label: "ISBN-13",
                        text: $isbn13,
                        prompt: "978… lub 979…",
                        keyboardType: .numbersAndPunctuation
                    )
                    .onChange(of: isbn13) { _, newValue in
                        handleISBNChange(newValue)
                    }

                    EditorialSecondaryButton(
                        title: metadataLookupState == .loading ? "Pobieranie danych…" : "Pobierz dane z katalogów",
                        icon: "text.magnifyingglass"
                    ) {
                        lookupMetadata(for: isbn13)
                    }
                    .disabled(normalizedISBN(isbn13) == nil || metadataLookupState == .loading)
                    .opacity(normalizedISBN(isbn13) == nil ? 0.5 : 1)

                    if publicationType == .periodical {
                        EditorialLabeledTextField(
                            label: "ISSN",
                            text: $issn,
                            prompt: "1234-5678",
                            keyboardType: .numbersAndPunctuation
                        )
                    }

                    EditorialLabeledTextField(
                        label: "EAN",
                        text: $ean,
                        prompt: "13 cyfr",
                        keyboardType: .numberPad
                    )

                    if !barcode.isEmpty {
                        HStack {
                            Text("ZESKANOWANY KOD")
                                .font(.caption2.weight(.bold))
                                .tracking(1.2)
                            Spacer()
                            Text(barcode)
                                .font(.caption.monospacedDigit())
                        }
                        .padding(.vertical, LibrarySpacing.small)
                        .overlay(alignment: .top) {
                            Rectangle().fill(LibraryPalette.rule).frame(height: 1)
                        }
                    }
                }
                .padding(.top, LibrarySpacing.medium)
            } label: {
                HStack {
                    Text("WIĘCEJ DANYCH")
                        .font(.caption.weight(.bold))
                        .tracking(1.6)
                    Spacer()
                    Text(showsMoreData ? "ZWIŃ" : "ROZWIŃ")
                        .font(.caption2.weight(.bold))
                        .tracking(1.1)
                        .foregroundStyle(LibraryPalette.orangeText)
                }
                .frame(minHeight: 44)
            }
            .tint(LibraryPalette.ink)
        }
        .padding(LibrarySpacing.medium)
        .background(LibraryPalette.ink.opacity(0.045))
        .overlay(alignment: .leading) {
            Rectangle().fill(LibraryPalette.orange).frame(width: 4)
        }
    }

    private var yearField: some View {
        EditorialLabeledTextField(
            label: "Rok wydania",
            text: $publicationYear,
            prompt: "np. 2026",
            keyboardType: .numberPad
        )
    }

    private var languageField: some View {
        EditorialLabeledTextField(
            label: "Język",
            text: $language,
            prompt: "np. pl"
        )
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
    }

    private var saveBar: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(LibraryPalette.rule)
                .frame(height: 1)

            EditorialPrimaryButton(title: duplicateMatch == nil ? "Zapisz egzemplarz" : "Dodaj kolejny egzemplarz") {
                save()
            }
            .disabled(!canSave)
            .opacity(canSave ? 1 : 0.5)
            .padding(.vertical, LibrarySpacing.small)
            .editorialPage(width: 760)
        }
        .background(LibraryPalette.paper)
    }

    private var savedConfirmation: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: LibrarySpacing.xLarge) {
                LibraryMasthead(
                    title: "Na półce",
                    eyebrow: "SESJA PÓŁKI · \(String(format: "%02d", catalogingSession.savedCount))",
                    subtitle: "\(savedTitle) jest już w Twojej kolekcji."
                )

                EditorialStatusBand(
                    title: savedUsedExistingPublication ? "Dodano kolejny egzemplarz" : "Nowa publikacja w katalogu",
                    message: savedLocation.isEmpty
                        ? "Nie przypisano lokalizacji. Możesz ją uzupełnić później."
                        : "Miejsce: \(LocationPath(savedLocation).display)",
                    icon: "checkmark",
                    accent: LibraryPalette.orangeText
                )

                EditorialMetricStrip(metrics: [
                    EditorialMetric(value: String(savedCopyCount), label: savedCopyCount == 1 ? "egzemplarz" : "egzemplarze"),
                    EditorialMetric(value: catalogingSession.canonicalLocation.isEmpty ? "—" : "✓", label: "lokalizacja")
                ])

                VStack(alignment: .leading, spacing: LibrarySpacing.small) {
                    EditorialSectionHeader(title: "Co dalej", value: nil)

                    EditorialPrimaryButton(title: "Skanuj następną", icon: "barcode.viewfinder") {
                        prepareNextPublication(startWithScanner: true)
                    }

                    EditorialSecondaryButton(title: "Dodaj ręcznie", icon: "square.and.pencil") {
                        prepareNextPublication(startWithScanner: false)
                    }

                    EditorialActionRow(
                        title: "Wróć do kolekcji",
                        detail: "Zakończ seryjne katalogowanie",
                        icon: "checkmark"
                    ) {
                        dismiss()
                    }
                }
            }
            .padding(.vertical, LibrarySpacing.large)
            .editorialPage(width: 720)
        }
        .navigationTitle("Zapisano")
    }

    @ViewBuilder
    private var metadataStatus: some View {
        VStack(alignment: .leading, spacing: LibrarySpacing.small) {
            switch metadataLookupState {
            case .idle:
                EditorialStatusBand(
                    title: barcode.isEmpty ? "Opis ręczny" : "Kod odczytany",
                    message: barcode.isEmpty
                        ? "Wpisz tytuł i miejsce albo wróć do skanera."
                        : "Sprawdź opis i wskaż miejsce przechowywania.",
                    icon: barcode.isEmpty ? "square.and.pencil" : "barcode"
                )
                EditorialActionRow(
                    title: barcode.isEmpty ? "Zeskanuj kod" : "Skanuj ponownie",
                    icon: "barcode.viewfinder",
                    accent: LibraryPalette.orangeText,
                    action: startRescan
                )

            case .loading:
                EditorialStatusBand(
                    title: "Szukam publikacji",
                    message: "Sprawdzam Bibliotekę Narodową i Open Library. Formularz działa w tym czasie normalnie.",
                    icon: "text.magnifyingglass"
                )
                ProgressView()
                    .tint(LibraryPalette.orangeText)
                    .accessibilityLabel("Pobieranie danych")
                EditorialActionRow(
                    title: "Skanuj ponownie",
                    icon: "barcode.viewfinder",
                    accent: LibraryPalette.orangeText,
                    action: startRescan
                )

            case .enriched(let source):
                EditorialStatusBand(
                    title: "Dane znalezione · \(source.displayName)",
                    message: "Uzupełniłem dostępny opis. Sprawdź go przed zapisem.",
                    icon: "checkmark"
                )
                EditorialActionRow(
                    title: "Skanuj ponownie",
                    icon: "barcode.viewfinder",
                    accent: LibraryPalette.orangeText,
                    action: startRescan
                )

            case .noMatch:
                EditorialStatusBand(
                    title: "Brak rekordu w katalogach",
                    message: "Połączenie działa, ale tego ISBN nie ma w BN ani Open Library. Uzupełnij opis ręcznie albo spróbuj jeszcze raz.",
                    icon: "questionmark"
                )
                retryAndRescanActions

            case .failed:
                EditorialStatusBand(
                    title: "Problem z połączeniem",
                    message: "Nie udało się pobrać danych. Formularz nadal działa ręcznie.",
                    icon: "wifi.exclamationmark"
                )
                retryAndRescanActions
            }
        }
    }

    private var retryAndRescanActions: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 0) {
                metadataAction(title: "Spróbuj ponownie", icon: "arrow.clockwise") {
                    lookupMetadata(for: isbn13)
                }
                .disabled(normalizedISBN(isbn13) == nil)

                Rectangle()
                    .fill(LibraryPalette.rule)
                    .frame(width: 1, height: 30)

                metadataAction(title: "Skanuj ponownie", icon: "barcode.viewfinder", action: startRescan)
            }

            VStack(spacing: 0) {
                metadataAction(title: "Spróbuj ponownie", icon: "arrow.clockwise") {
                    lookupMetadata(for: isbn13)
                }
                .disabled(normalizedISBN(isbn13) == nil)

                metadataAction(title: "Skanuj ponownie", icon: "barcode.viewfinder", action: startRescan)
            }
        }
    }

    private func metadataAction(
        title: String,
        icon: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Text(title.uppercased())
                    .font(.caption2.weight(.bold))
                    .tracking(1.05)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: LibrarySpacing.xSmall)
                Image(systemName: icon)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(LibraryPalette.orangeText)
                    .accessibilityHidden(true)
            }
            .foregroundStyle(LibraryPalette.ink)
            .padding(.horizontal, LibrarySpacing.small)
            .frame(maxWidth: .infinity, minHeight: 44)
            .overlay(alignment: .top) {
                Rectangle().fill(LibraryPalette.rule).frame(height: 1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }

    private var duplicateMatch: ExistingPublicationMatch? {
        ExistingPublicationMatcher.match(
            in: existingItems,
            type: publicationType,
            isbn13: isbn13,
            issn: issn,
            ean: ean,
            issueNumber: issueNumber,
            issueDate: issueDate
        )
    }

    private var canSave: Bool {
        duplicateMatch != nil || !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var locationTextBinding: Binding<String> {
        Binding(
            get: { catalogingSession.locationText },
            set: { catalogingSession.updateLocationText($0) }
        )
    }

    private var currentLocationDisplay: String? {
        let location = LocationPath(catalogingSession.locationText)
        return location.isEmpty ? nil : location.display
    }

    private var recentLocations: [String] {
        var seen = Set<LocationPath>()
        return existingItems.compactMap { item in
            let path = LocationPath(item.locationPathText)
            guard !path.isEmpty, seen.insert(path).inserted else { return nil }
            return path.canonical
        }
        .prefix(3)
        .map { $0 }
    }

    private func duplicateMessage(for match: ExistingPublicationMatch) -> String {
        let label = match.copyCount == 1 ? "egzemplarz" : "egzemplarze"
        return "W kolekcji są już \(match.copyCount) \(label) tego wydania. Zapis doda następną kopię i zachowa wspólny opis bibliograficzny."
    }

    private func startRescan() {
        clearPublicationFields(preserveCopyFields: true)
        step = .scanner
    }

    private func prepareNextPublication(startWithScanner: Bool) {
        clearPublicationFields(preserveCopyFields: false)
        step = startWithScanner ? .scanner : .form
    }

    private func clearPublicationFields(preserveCopyFields: Bool) {
        metadataLookupTask?.cancel()
        metadataLookupTask = nil
        metadataLookupISBN = nil
        metadataLookupState = .idle

        publicationType = .book
        title = ""
        subtitle = ""
        authors = ""
        language = "pl"
        publisher = ""
        publicationYear = ""
        isbn13 = ""
        issn = ""
        ean = ""
        barcode = ""
        issueNumber = ""
        issueVolume = ""
        issueDate = ""
        metadataSource = "manual"
        validationMessage = nil
        showsMoreData = false

        if !preserveCopyFields {
            // Lokalizacja zostaje: to najważniejsze przy seryjnym skanowaniu półki.
            notes = ""
        }
    }

    private var hasEnteredData: Bool {
        !title.isEmpty || !authors.isEmpty || !barcode.isEmpty || !catalogingSession.locationText.isEmpty
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

        let match = ExistingPublicationMatcher.match(
            in: existingItems,
            type: publicationType,
            isbn13: normalizedISBN,
            issn: issn,
            ean: normalizedEAN,
            issueNumber: issueNumber,
            issueDate: issueDate
        )

        guard match != nil || !cleanTitle.isEmpty else {
            validationMessage = "Tytuł jest wymagany."
            return
        }

        let cleanYear = publicationYear.trimmingCharacters(in: .whitespacesAndNewlines)
        let year: Int?
        if match != nil || cleanYear.isEmpty {
            year = nil
        } else if let value = Int(cleanYear), (1...9999).contains(value) {
            year = value
        } else {
            validationMessage = "Rok wydania powinien być liczbą od 1 do 9999."
            return
        }

        let now = Date.now
        let publication: Publication
        let insertedNewPublication: Bool

        if let match {
            publication = match.publication
            insertedNewPublication = false
        } else {
            publication = Publication(
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
            modelContext.insert(publication)
            insertedNewPublication = true
        }

        let cleanLocation = LocationPath(catalogingSession.locationText).canonical
        let item = OwnedItem(
            publication: publication,
            locationPathText: cleanLocation,
            notes: notes.trimmingCharacters(in: .whitespacesAndNewlines),
            addedAt: now,
            updatedAt: now
        )
        modelContext.insert(item)

        do {
            try modelContext.save()
            catalogingSession.recordSaved(itemID: item.id, savedAt: now)
            savedTitle = publication.title
            savedLocation = catalogingSession.canonicalLocation.canonical
            savedCopyCount = (match?.copyCount ?? 0) + 1
            savedUsedExistingPublication = match != nil
            step = .saved
        } catch {
            modelContext.delete(item)
            if insertedNewPublication {
                modelContext.delete(publication)
            }
            validationMessage = "Nie udało się zapisać publikacji: \(error.localizedDescription)"
        }
    }
}
