import SwiftData
import SwiftUI

struct ItemEditFlow: View {
    enum Mode: Equatable {
        case full
        case moveOnly
    }

    private enum PendingConfirmation {
        case discard
        case sharedPublication
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \OwnedItem.updatedAt, order: .reverse) private var collectionItems: [OwnedItem]

    private let prepared: CatalogItemPreparedEdit
    private let mode: Mode
    private let onSaved: (CatalogItemEditResult) -> Void
    private let initialYearText: String

    @State private var draft: CatalogItemEditDraft
    @State private var publicationYearText: String
    @State private var showsMoreBibliography = false
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var pendingConfirmation: PendingConfirmation?

    init(
        prepared: CatalogItemPreparedEdit,
        mode: Mode,
        onSaved: @escaping (CatalogItemEditResult) -> Void
    ) {
        self.prepared = prepared
        self.mode = mode
        self.onSaved = onSaved

        let yearText = prepared.draft.publication.publicationYear.map(String.init) ?? ""
        initialYearText = yearText
        _draft = State(initialValue: prepared.draft)
        _publicationYearText = State(initialValue: yearText)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                PaperBackground()
                content
            }
            .foregroundStyle(LibraryPalette.ink)
            .navigationTitle(mode == .full ? "Edytuj egzemplarz" : "Przenieś egzemplarz")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { editorToolbar }
            .toolbarBackground(LibraryPalette.paper, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(.light, for: .navigationBar)
        }
        .libraryLightAppearance()
        .interactiveDismissDisabled(isDirty || isSaving)
        .confirmationDialog(
            confirmationTitle,
            isPresented: confirmationBinding,
            titleVisibility: .visible
        ) {
            confirmationActions
        } message: {
            Text(confirmationMessage)
        }
        .alert("Nie udało się zapisać", isPresented: errorBinding) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "Spróbuj ponownie.")
        }
    }

    @ViewBuilder
    private var content: some View {
        switch mode {
        case .full:
            fullEditor
        case .moveOnly:
            moveEditor
        }
    }

    private var fullEditor: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: LibrarySpacing.xLarge) {
                LibraryMasthead(
                    title: "Edytuj egzemplarz",
                    eyebrow: "KARTA KOLEKCJI · EDYCJA",
                    subtitle: prepared.baseline.draft.publication.title,
                    compact: true
                )

                copySection
                publicationSection
            }
            .padding(.vertical, LibrarySpacing.medium)
            .editorialPage(width: 760)
        }
        .scrollDismissesKeyboard(.interactively)
        .scrollIndicators(.hidden)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            saveBar
        }
    }

    private var moveEditor: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: LibrarySpacing.large) {
                LibraryMasthead(
                    title: "Przenieś egzemplarz",
                    eyebrow: "KARTA KOLEKCJI · LOKALIZACJA",
                    subtitle: prepared.baseline.draft.publication.title,
                    compact: true
                )

                EditorialStatusBand(
                    title: "Obecne miejsce",
                    message: baselineLocationDisplay,
                    icon: "mappin.and.ellipse"
                )
                .accessibilityIdentifier("itemMove.currentLocation")

                VStack(alignment: .leading, spacing: LibrarySpacing.medium) {
                    EditorialSectionHeader(title: "Nowe miejsce", value: "01")

                    Text("Wpisz drogę od pomieszczenia do półki. Ukośniki budują hierarchię lokalizacji.")
                        .font(.system(.body, design: .serif))
                        .lineSpacing(3)
                        .foregroundStyle(LibraryPalette.mutedInk)

                    EditorialLabeledTextField(
                        label: "Lokalizacja docelowa",
                        text: $draft.item.locationPathText,
                        prompt: "Dom / Gabinet / Regał A / Półka 2",
                        accessibilityIdentifier: "itemMove.destination"
                    )
                    .textInputAutocapitalization(.words)

                    recentLocationsSection
                }
            }
            .padding(.vertical, LibrarySpacing.medium)
            .editorialPage(width: 720)
        }
        .scrollDismissesKeyboard(.interactively)
        .scrollIndicators(.hidden)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            saveBar
        }
    }

    private var copySection: some View {
        VStack(alignment: .leading, spacing: LibrarySpacing.medium) {
            EditorialSectionHeader(title: "Ten egzemplarz", value: "TYLKO TA SZTUKA")

            OwnedItemStatusSelector(selection: $draft.item.status)

            EditorialLabeledTextField(
                label: "Lokalizacja",
                text: $draft.item.locationPathText,
                prompt: "Dom / Gabinet / Regał A / Półka 2",
                accessibilityIdentifier: "itemEdit.location"
            )
            .textInputAutocapitalization(.words)

            EditorialAxisField(
                label: "Notatki o egzemplarzu",
                text: $draft.item.notes,
                prompt: "Stan, dedykacja lub inne informacje",
                lineLimit: 2...5,
                accessibilityIdentifier: "itemEdit.notes"
            )
        }
    }

    private var publicationSection: some View {
        VStack(alignment: .leading, spacing: LibrarySpacing.medium) {
            EditorialSectionHeader(
                title: "Wspólny opis wydania",
                value: "\(prepared.sharedCopyCount) \(prepared.sharedCopyCount == 1 ? "KOPIA" : "KOPII")"
            )

            if prepared.sharedCopyCount > 1 {
                EditorialStatusBand(
                    title: "Opis używany przez kilka egzemplarzy",
                    message: "Zmiana tytułu, autora, wydania lub identyfikatora będzie widoczna przy wszystkich \(prepared.sharedCopyCount) egzemplarzach.",
                    icon: "square.on.square"
                )
                .accessibilityIdentifier("itemEdit.sharedPublicationWarning")
            }

            EditorialLabeledTextField(
                label: "Tytuł publikacji",
                text: $draft.publication.title,
                prompt: "Wpisz tytuł",
                accessibilityIdentifier: "itemEdit.title"
            )

            EditorialAxisField(
                label: "Autorzy",
                text: $draft.publication.authorsText,
                prompt: "Oddziel autorów średnikiem",
                lineLimit: 1...3,
                accessibilityIdentifier: "itemEdit.authors"
            )

            EditorialPublicationTypeSelector(
                label: "Rodzaj publikacji",
                selection: $draft.publication.type,
                options: PublicationType.allCases.map {
                    EditorialSelectionOption(value: $0, title: $0.label, symbol: $0.symbolName)
                }
            )
            .accessibilityIdentifier("itemEdit.type")

            if draft.publication.type == .periodical {
                periodicalFields
            }

            CoverPhotoCaptureView(existingImageData: draft.publication.coverImageData) { newData in
                draft.publication.coverImageData = newData
            }

            Text("Zdjęcie okładki należy do wspólnego opisu wydania i jest przechowywane lokalnie. Obecny eksport JSON nie zawiera pliku zdjęcia.")
                .font(.system(.footnote, design: .serif))
                .lineSpacing(3)
                .foregroundStyle(LibraryPalette.mutedInk)
                .fixedSize(horizontal: false, vertical: true)

            moreBibliography
        }
    }

    private var periodicalFields: some View {
        VStack(alignment: .leading, spacing: LibrarySpacing.medium) {
            EditorialSectionHeader(title: "Konkretny numer", value: "PRASA", accent: nil)

            EditorialLabeledTextField(
                label: "Numer",
                text: $draft.publication.issueNumber,
                prompt: "np. 8/2026",
                accessibilityIdentifier: "itemEdit.issueNumber"
            )
            EditorialLabeledTextField(
                label: "Rocznik / tom",
                text: $draft.publication.issueVolume,
                prompt: "np. XLII",
                accessibilityIdentifier: "itemEdit.issueVolume"
            )
            EditorialLabeledTextField(
                label: "Data numeru",
                text: $draft.publication.issueDate,
                prompt: "np. 2026-08",
                accessibilityIdentifier: "itemEdit.issueDate"
            )
        }
    }

    private var moreBibliography: some View {
        DisclosureGroup(isExpanded: $showsMoreBibliography) {
            VStack(alignment: .leading, spacing: LibrarySpacing.medium) {
                EditorialLabeledTextField(
                    label: "Podtytuł",
                    text: $draft.publication.subtitle,
                    prompt: "Opcjonalnie",
                    accessibilityIdentifier: "itemEdit.subtitle"
                )
                EditorialLabeledTextField(
                    label: "Wydawca",
                    text: $draft.publication.publisher,
                    prompt: "Opcjonalnie",
                    accessibilityIdentifier: "itemEdit.publisher"
                )

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

                if draft.publication.type == .book {
                    EditorialLabeledTextField(
                        label: "ISBN-13",
                        text: $draft.publication.isbn13,
                        prompt: "978… lub 979…",
                        keyboardType: .numbersAndPunctuation,
                        accessibilityIdentifier: "itemEdit.isbn13"
                    )
                } else {
                    EditorialLabeledTextField(
                        label: "ISSN",
                        text: $draft.publication.issn,
                        prompt: "1234-5678",
                        keyboardType: .numbersAndPunctuation,
                        accessibilityIdentifier: "itemEdit.issn"
                    )
                }

                EditorialLabeledTextField(
                    label: "EAN",
                    text: $draft.publication.ean,
                    prompt: "13 cyfr",
                    keyboardType: .numberPad,
                    accessibilityIdentifier: "itemEdit.ean"
                )
                EditorialLabeledTextField(
                    label: "Kod źródłowy",
                    text: $draft.publication.barcode,
                    prompt: "Kod zapisany podczas skanowania",
                    keyboardType: .numbersAndPunctuation,
                    accessibilityIdentifier: "itemEdit.barcode"
                )
            }
            .padding(.top, LibrarySpacing.medium)
        } label: {
            HStack {
                Text("WIĘCEJ DANYCH")
                    .font(.caption.weight(.bold))
                    .tracking(1.6)
                Spacer(minLength: LibrarySpacing.small)
                Text(showsMoreBibliography ? "ZWIŃ" : "ROZWIŃ")
                    .font(.caption2.weight(.bold))
                    .tracking(1.1)
                    .foregroundStyle(LibraryPalette.orangeText)
            }
            .frame(minHeight: 44)
        }
        .tint(LibraryPalette.ink)
        .padding(LibrarySpacing.medium)
        .background(LibraryPalette.ink.opacity(0.045))
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(LibraryPalette.orange)
                .frame(width: 4)
                .accessibilityHidden(true)
        }
    }

    private var yearField: some View {
        EditorialLabeledTextField(
            label: "Rok wydania",
            text: $publicationYearText,
            prompt: "np. 2020",
            keyboardType: .numberPad,
            accessibilityIdentifier: "itemEdit.publicationYear"
        )
        .frame(maxWidth: .infinity)
    }

    private var languageField: some View {
        EditorialLabeledTextField(
            label: "Język",
            text: $draft.publication.language,
            prompt: "np. pl",
            accessibilityIdentifier: "itemEdit.language"
        )
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var recentLocationsSection: some View {
        let locations = recentLocations
        if !locations.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                Text("OSTATNIE MIEJSCA")
                    .font(.caption2.weight(.bold))
                    .tracking(1.35)
                    .foregroundStyle(LibraryPalette.mutedInk)
                    .padding(.bottom, LibrarySpacing.xSmall)

                ForEach(Array(locations.enumerated()), id: \.offset) { index, location in
                    Button {
                        draft.item.locationPathText = location.canonical
                    } label: {
                        HStack(spacing: LibrarySpacing.small) {
                            Text(location.display)
                                .font(.system(.footnote, design: .serif))
                                .multilineTextAlignment(.leading)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: LibrarySpacing.small)
                            Image(systemName: "arrow.turn.down.left")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(LibraryPalette.orangeText)
                                .accessibilityHidden(true)
                        }
                        .foregroundStyle(LibraryPalette.ink)
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        .contentShape(Rectangle())
                        .overlay(alignment: .top) {
                            Rectangle()
                                .fill(LibraryPalette.rule)
                                .frame(height: 1)
                                .accessibilityHidden(true)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Użyj lokalizacji: \(location.display)")
                    .accessibilityIdentifier("itemMove.recent.\(index)")
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("itemMove.recent")
        }
    }

    private var saveBar: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(LibraryPalette.rule)
                .frame(height: 1)
                .accessibilityHidden(true)

            EditorialPrimaryButton(
                title: mode == .full ? "Zapisz zmiany" : "Przenieś egzemplarz",
                icon: mode == .full ? "checkmark" : "arrow.right",
                isLoading: isSaving,
                action: requestSave
            )
            .disabled(!isDirty || isSaving)
            .opacity(!isDirty && !isSaving ? 0.56 : 1)
            .accessibilityIdentifier(mode == .full ? "itemEdit.save" : "itemMove.save")
            .padding(.horizontal, LibrarySpacing.page)
            .padding(.vertical, LibrarySpacing.small)
        }
        .background(LibraryPalette.paper)
    }

    @ToolbarContentBuilder
    private var editorToolbar: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button("Anuluj", action: requestDismiss)
                .foregroundStyle(LibraryPalette.ink)
                .frame(minWidth: 44, minHeight: 44)
                .disabled(isSaving)
                .accessibilityIdentifier("itemEdit.cancel")
        }
    }

    private var recentLocations: [LocationPath] {
        let current = LocationPath(prepared.baseline.draft.item.locationPathText)
        var seen = Set<LocationPath>()
        var result: [LocationPath] = []

        for item in collectionItems {
            let path = LocationPath(item.locationPathText)
            guard !path.isEmpty, path != current, seen.insert(path).inserted else { continue }
            result.append(path)
            if result.count == 3 { break }
        }
        return result
    }

    private var baselineLocationDisplay: String {
        let path = LocationPath(prepared.baseline.draft.item.locationPathText)
        return path.isEmpty ? "Bez lokalizacji" : path.display
    }

    private var isDirty: Bool {
        switch mode {
        case .full:
            draft != prepared.draft || publicationYearText != initialYearText
        case .moveOnly:
            draft.item.locationPathText != prepared.draft.item.locationPathText
        }
    }

    private var publicationChanged: Bool {
        draft.publication != prepared.baseline.draft.publication
    }

    private var confirmationBinding: Binding<Bool> {
        Binding(
            get: { pendingConfirmation != nil },
            set: { if !$0 { pendingConfirmation = nil } }
        )
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )
    }

    private var confirmationTitle: String {
        switch pendingConfirmation {
        case .discard:
            "Odrzucić zmiany?"
        case .sharedPublication:
            "Zmienić wspólny opis wydania?"
        case .none:
            "Potwierdź"
        }
    }

    private var confirmationMessage: String {
        switch pendingConfirmation {
        case .discard:
            "Wprowadzone dane nie zostaną zapisane."
        case .sharedPublication:
            "Zmiana bibliografii będzie widoczna przy wszystkich \(prepared.sharedCopyCount) egzemplarzach korzystających z tego opisu."
        case .none:
            ""
        }
    }

    @ViewBuilder
    private var confirmationActions: some View {
        switch pendingConfirmation {
        case .discard:
            Button("Odrzuć zmiany", role: .destructive) {
                pendingConfirmation = nil
                dismiss()
            }
        case .sharedPublication:
            Button("Zapisz dla \(prepared.sharedCopyCount) egzemplarzy") {
                pendingConfirmation = nil
                performFullSave()
            }
        case .none:
            EmptyView()
        }

        Button("Anuluj", role: .cancel) {
            pendingConfirmation = nil
        }
    }

    private func requestDismiss() {
        if isDirty {
            pendingConfirmation = .discard
        } else {
            dismiss()
        }
    }

    private func requestSave() {
        guard !isSaving else { return }

        switch mode {
        case .full:
            guard applyPublicationYear() else { return }
            if publicationChanged, prepared.sharedCopyCount > 1 {
                pendingConfirmation = .sharedPublication
            } else {
                performFullSave()
            }
        case .moveOnly:
            performMove()
        }
    }

    private func applyPublicationYear() -> Bool {
        guard publicationYearText != initialYearText else { return true }
        let cleanYear = publicationYearText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanYear.isEmpty else {
            draft.publication.publicationYear = nil
            return true
        }

        guard let year = Int(cleanYear), (1...9999).contains(year) else {
            errorMessage = CatalogItemEditingError.invalidPublicationYear.localizedDescription
            return false
        }
        draft.publication.publicationYear = year
        return true
    }

    private func performFullSave() {
        guard !isSaving else { return }
        isSaving = true
        do {
            let result = try CatalogItemEditingService(modelContext: modelContext).edit(
                prepared,
                draft: draft
            )
            finish(with: result)
        } catch {
            isSaving = false
            errorMessage = error.localizedDescription
        }
    }

    private func performMove() {
        guard !isSaving else { return }
        isSaving = true
        do {
            let result = try CatalogItemEditingService(modelContext: modelContext).move(
                prepared,
                to: draft.item.locationPathText
            )
            finish(with: result)
        } catch {
            isSaving = false
            errorMessage = error.localizedDescription
        }
    }

    private func finish(with result: CatalogItemEditResult) {
        onSaved(result)
        dismiss()
    }
}

private struct OwnedItemStatusSelector: View {
    @Binding var selection: OwnedItemStatus

    var body: some View {
        EditorialPublicationTypeSelector(
            label: "Status",
            selection: $selection,
            options: OwnedItemStatus.allCases.map {
                EditorialSelectionOption(value: $0, title: $0.label)
            }
        )
        .accessibilityIdentifier("itemEdit.status")
    }
}
