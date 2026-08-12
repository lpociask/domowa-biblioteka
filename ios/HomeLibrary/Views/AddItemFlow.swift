import SwiftData
import SwiftUI
import UIKit

struct AddItemFlow: View {
    private enum Step {
        case shelfSetup
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
        let coverURLString: String
        let coverSource: String
    }

    private struct RecentSaveNotice: Equatable {
        let itemID: UUID
        let title: String
        let suppressedCode: String?
    }

    /// Values filled automatically during this attempt. They live only in
    /// memory and are reduced to a count before a pilot metric is recorded.
    private enum PilotTrackedField: Hashable, Sendable {
        case title, subtitle, authors, language, publisher, publicationYear
        case isbn, issn, ean, barcode
        case issueNumber, issueVolume, issueDate
    }

    private static let pilotIdentifierFields: [PilotTrackedField] = [
        .isbn, .issn, .ean, .barcode
    ]
    private static let pilotMetadataFields: [PilotTrackedField] = [
        .title, .subtitle, .authors, .language, .publisher, .publicationYear
    ]
    private static let pilotPeriodicalFields: [PilotTrackedField] = [
        .issueNumber, .issueVolume, .issueDate
    ]

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.scenePhase) private var scenePhase
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
    @State private var eanSupplement = ""
    @State private var issueNumber = ""
    @State private var issueVolume = ""
    @State private var issueDate = ""
    @State private var catalogingSession = CatalogingSession()
    @State private var notes = ""
    @State private var metadataSource = "manual"
    @State private var coverURLString = ""
    @State private var coverSource = ""
    @State private var validationMessage: String?
    @State private var metadataLookupState: MetadataLookupState = .idle
    @State private var metadataLookupTask: Task<Void, Never>?
    @State private var metadataLookupISBN: String?
    @State private var showsMoreData = false
    @State private var savedTitle = ""
    @State private var savedLocation = ""
    @State private var savedCopyCount = 1
    @State private var savedUsedExistingPublication = false
    @State private var isSaving = false
    @State private var recentSaveNotice: RecentSaveNotice?
    @State private var serialModeEnabled: Bool
    @State private var forceNewPeriodicalPublication = false
    @State private var showsPeriodicalCoverOCR = false
    @State private var pilotAttemptTracker = PilotAttemptTracker(publicationKind: .book)
    @State private var pilotAttemptMetricRecorded = false
    @State private var pilotAttemptStartingLocation = ""
    @State private var pilotAutofillCorrections = PilotAutofillCorrectionTracker<PilotTrackedField>()
    @State private var didStartInitialPilotAttempt = false
    @State private var pilotDuplicateDecisionRecorded = false

    private let metadataProvider: any BookMetadataProviding
    private let pilotMetricsStore: PilotMetricsStore?
    private let onMutation: (() -> Void)?

    init(
        startWithScanner: Bool,
        metadataProvider: (any BookMetadataProviding)? = nil,
        pilotMetricsStore: PilotMetricsStore? = nil,
        onMutation: (() -> Void)? = nil
    ) {
        _step = State(initialValue: startWithScanner ? .shelfSetup : .form)
        _serialModeEnabled = State(initialValue: startWithScanner)
#if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-ui-periodical-fixture") {
            _step = State(initialValue: .form)
            _serialModeEnabled = State(initialValue: true)
            _publicationType = State(initialValue: .periodical)
            _title = State(initialValue: "Monocle")
            _language = State(initialValue: "en")
            _issn = State(initialValue: "1753-2434")
            _ean = State(initialValue: "9771753243008")
            _barcode = State(initialValue: "9771753243008+05")
            _eanSupplement = State(initialValue: "05")
            _catalogingSession = State(initialValue: CatalogingSession(
                locationText: "Dom / Salon / Stolik"
            ))
            _metadataSource = State(initialValue: "collection")
        }
#endif
        let lookupObserver: BookMetadataLookupObserver
        if let pilotMetricsStore {
            lookupObserver = .recording(in: pilotMetricsStore)
        } else {
            lookupObserver = .disabled
        }
        self.metadataProvider = metadataProvider ?? DefaultBookMetadataProvider(
            observer: lookupObserver
        )
        self.pilotMetricsStore = pilotMetricsStore
        self.onMutation = onMutation
    }

    var body: some View {
        NavigationStack {
            ZStack {
                PaperBackground()

                switch step {
                case .shelfSetup:
                    shelfSetup
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
                    Button {
                        finishPilotAttempt(cancelled: true)
                        dismiss()
                    } label: {
                        if dynamicTypeSize.isAccessibilitySize {
                            Image(systemName: "xmark")
                                .font(.headline)
                        } else {
                            Text(step == .saved ? "Gotowe" : "Anuluj")
                        }
                    }
                    .foregroundStyle(LibraryPalette.ink)
                    .frame(minWidth: 44, minHeight: 44)
                    .accessibilityLabel(step == .saved ? "Gotowe" : "Anuluj")
                }
            }
        }
        .libraryLightAppearance()
        .interactiveDismissDisabled(step == .form && hasEnteredData)
        .onAppear {
            guard !didStartInitialPilotAttempt else { return }
            didStartInitialPilotAttempt = true
            if step != .shelfSetup {
                startPilotAttemptIfNeeded()
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                _ = pilotAttemptTracker.resume()
            } else {
                _ = pilotAttemptTracker.pause()
            }
        }
        .onDisappear {
            metadataLookupTask?.cancel()
            finishPilotAttempt(cancelled: true)
        }
        .alert("Sprawdź dane", isPresented: Binding(
            get: { validationMessage != nil },
            set: { if !$0 { validationMessage = nil } }
        )) {
            Button("OK", role: .cancel) { validationMessage = nil }
        } message: {
            Text(validationMessage ?? "")
        }
        .sheet(isPresented: $showsPeriodicalCoverOCR) {
            PeriodicalCoverOCRView(
                existingIssueNumber: issueNumber,
                existingIssueVolume: issueVolume,
                existingIssueDate: issueDate,
                pilotMetricsStore: pilotMetricsStore,
                onApply: applyPeriodicalOCRSelection
            )
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
        }
    }

    private var shelfSetup: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: LibrarySpacing.xLarge) {
                LibraryMasthead(
                    title: dynamicTypeSize.isAccessibilitySize ? "Półka" : "Wybierz półkę",
                    eyebrow: dynamicTypeSize.isAccessibilitySize ? "SESJA · 01" : "SESJA PÓŁKI · 01/03",
                    subtitle: dynamicTypeSize.isAccessibilitySize
                        ? nil
                        : "Każda kolejna publikacja trafi w to miejsce, dopóki go nie zmienisz.",
                    compact: true,
                    constrainAccessibilityHeight: true
                )

                if !dynamicTypeSize.isAccessibilitySize {
                    EditorialStatusBand(
                        title: "Najpierw miejsce, potem skan",
                        message: "Wpisz drogę od pomieszczenia do półki. Dzięki temu nie trzeba uzupełniać lokalizacji przy każdej książce ani gazecie.",
                        icon: "books.vertical"
                    )
                }

                VStack(alignment: .leading, spacing: LibrarySpacing.medium) {
                    if !dynamicTypeSize.isAccessibilitySize {
                        EditorialSectionHeader(title: "Bieżąca lokalizacja", value: "WYMAGANA")
                    }

                    EditorialLabeledTextField(
                        label: "Półka dla tej sesji",
                        text: locationTextBinding,
                        prompt: "Gabinet / Regał 2 / Półka 3",
                        submitLabel: .continue,
                        accessibilityIdentifier: "addItem.shelfLocation"
                    )
                    .textInputAutocapitalization(.words)
                    .onSubmit(confirmShelfAndScan)
                    .accessibilityHint("Ta lokalizacja zostanie zachowana dla kolejnych publikacji w sesji.")
                }

                shelfStartButton
                recentLocationChoices

                Text(dynamicTypeSize.isAccessibilitySize
                    ? "Półkę zmienisz później na skanerze."
                    : "Lokalizację można zmienić bezpośrednio z ekranu skanera. Zmiana dotyczy następnych zapisów w tej sesji.")
                    .font(.system(.footnote, design: .serif))
                    .lineSpacing(3)
                    .foregroundStyle(LibraryPalette.mutedInk)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, LibrarySpacing.large)
            .editorialPage(width: 720)
        }
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle("Bieżąca półka")
        .accessibilityIdentifier("addItem.shelfSetup")
    }

    private var shelfStartButton: some View {
        EditorialPrimaryButton(
            title: dynamicTypeSize.isAccessibilitySize ? "Dalej" : "Rozpocznij skanowanie",
            icon: "barcode.viewfinder",
            action: confirmShelfAndScan
        )
        .disabled(!CatalogingReadiness.canStartShelfSession(
            locationText: catalogingSession.locationText
        ))
        .opacity(CatalogingReadiness.canStartShelfSession(
            locationText: catalogingSession.locationText
        ) ? 1 : 0.5)
        .accessibilityIdentifier("addItem.shelfStart")
        .accessibilityLabel("Rozpocznij skanowanie")
    }

    private var scanner: some View {
        ScannerStep(
            currentLocation: currentLocationDisplay,
            recentSaveTitle: recentSaveNotice?.title,
            initiallySuppressedCode: recentSaveNotice?.suppressedCode,
            onUndoRecentSave: recentSaveNotice == nil ? nil : undoRecentSave,
            onChangeLocation: presentShelfSetupFromScanner
        ) { value, cameFromCamera in
            startPilotAttemptIfNeeded()
            pilotDuplicateDecisionRecorded = false
            isSaving = false
            let pilotValuesBeforeApply = currentPilotValues(for: Self.pilotIdentifierFields)
            let pilotSeriesValuesBeforeApply = currentPilotValues(for: Self.pilotMetadataFields)
            let scannedISBN = apply(identifier: value)
            let filledKnownPeriodicalSeries = applyKnownPeriodicalSeriesPrefill()
            _ = pilotAttemptTracker.markRecognition()
            capturePilotAutomaticChanges(
                in: Self.pilotIdentifierFields,
                from: pilotValuesBeforeApply
            )
            capturePilotAutomaticChanges(
                in: Self.pilotMetadataFields,
                from: pilotSeriesValuesBeforeApply
            )
            metadataSource = filledKnownPeriodicalSeries
                ? "collection"
                : (cameFromCamera ? "scan" : "manual")
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
                    subtitle: isManualEntryIdle ? nil : "Sprawdź opis, potem zapisz miejsce na półce.",
                    compact: true
                )

                if isManualEntryIdle {
                    EditorialActionRow(
                        title: "Zeskanuj kod zamiast wpisywać",
                        detail: "Kod ISBN z tylnej okładki przyspieszy uzupełnianie opisu.",
                        icon: "barcode.viewfinder",
                        accent: LibraryPalette.orangeText,
                        action: startRescan
                    )
                } else {
                    metadataStatus
                }

                if publicationType == .periodical, duplicateMatch == nil {
                    periodicalCaptureStatus
                    periodicalOCRAction
                }

                if let duplicateMatch {
                    EditorialStatusBand(
                        title: duplicateTitle(for: duplicateMatch),
                        message: duplicateMessage(for: duplicateMatch),
                        icon: duplicateMatch.kind == .possibleRepeatScan
                            ? "exclamationmark.triangle"
                            : "square.on.square",
                        accent: LibraryPalette.orangeText
                    )
                }

                if forceNewPeriodicalPublication, publicationType == .periodical {
                    EditorialStatusBand(
                        title: "Nowy numer pisma",
                        message: "Podobny kod pozostaje wskazówką, ale zapis utworzy osobny numer. Uzupełnij numer lub datę z okładki.",
                        icon: "newspaper",
                        accent: LibraryPalette.orangeText
                    )
                }

                if let duplicateMatch {
                    existingPublicationSection(duplicateMatch)
                } else {
                    mainDataSection
                }

                if publicationType == .periodical, duplicateMatch == nil {
                    periodicalSection
                }

                coverPreviewSection

                locationSection

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
            EditorialSectionHeader(title: "Opis publikacji", value: "01")

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

    private var periodicalCaptureStatus: some View {
        let titleIsEmpty = title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let statusTitle = titleIsEmpty
            ? (hasValidPeriodicalEAN ? "Rozpoznano prasę — wpisz tytuł" : "Wpisz tytuł prasy")
            : "Rozpoznano prasę"
        let statusMessage: String
        if titleIsEmpty, hasValidPeriodicalEAN {
            statusMessage = "Kod 977 wskazuje serię, ale katalogi ISBN nie uzupełniają tytułów prasy. Wpisz tytuł, a potem potwierdź numer lub datę z okładki."
        } else if titleIsEmpty {
            statusMessage = "Wpisz tytuł, a potem potwierdź konkretny numer lub datę z okładki."
        } else if metadataSource == "collection" {
            statusMessage = "Tytuł uzupełniono z Twojej kolekcji. Potwierdź konkretny numer lub datę z okładki przed zapisem."
        } else {
            statusMessage = "Tytuł jest gotowy. Potwierdź konkretny numer lub datę z okładki przed zapisem."
        }

        return EditorialStatusBand(
            title: statusTitle,
            message: statusMessage,
            icon: "newspaper",
            accent: LibraryPalette.orangeText
        )
    }

    private var periodicalOCRAction: some View {
        EditorialActionRow(
            title: "Odczytaj numer z okładki",
            detail: "Zrób zdjęcie; OCR lokalnie zaproponuje numer, tom i datę.",
            icon: "text.viewfinder",
            accent: LibraryPalette.orangeText
        ) {
            showsPeriodicalCoverOCR = true
        }
        .accessibilityIdentifier("addItem.periodicalCoverOCR")
    }

    private var isManualEntryIdle: Bool {
        metadataLookupState == .idle &&
            barcode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            isbn13.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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

            if publication.publicationType == .periodical {
                EditorialActionRow(
                    title: "To jest inny numer",
                    detail: "Zachowaj dane tytułu, ale utwórz osobny numer prasy.",
                    icon: "plus.rectangle.on.rectangle",
                    accent: LibraryPalette.orangeText
                ) {
                    prepareSeparatePeriodicalIssue(from: publication)
                }
            }
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

            if serialModeEnabled, LocationPath(catalogingSession.locationText).isEmpty {
                EditorialStatusBand(
                    title: "Wybierz półkę",
                    message: CatalogingReadinessFailure.missingShelf.message,
                    icon: "exclamationmark.triangle"
                )
            }

            recentLocationChoices

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
            EditorialSectionHeader(title: "Konkretny numer", value: "WYMAGANY")

            Text("ISSN opisuje cały tytuł prasowy. Numer lub data rozróżniają egzemplarz, który trzymasz w ręku.")
                .font(.system(.body, design: .serif))
                .lineSpacing(3)
                .foregroundStyle(LibraryPalette.mutedInk)

            EditorialLabeledTextField(
                label: "Dodatek EAN (2 lub 5 cyfr)",
                text: $eanSupplement,
                prompt: "np. 05 albo 00123",
                keyboardType: .numberPad
            )

            if !cleanEANSupplement.isEmpty, !isValidEANSupplement {
                EditorialStatusBand(
                    title: "Sprawdź dodatek EAN",
                    message: "Dodatek musi zawierać dokładnie 2 albo 5 cyfr i występować razem z prawidłowym kodem prasy 977.",
                    icon: "exclamationmark.triangle"
                )
            }

            if isValidEANSupplement {
                EditorialStatusBand(
                    title: "Dodatek EAN odczytany",
                    message: "Wartość \(cleanEANSupplement) pomaga rozróżnić numer, ale jej znaczenie zależy od wydawcy. Sprawdź okładkę przed użyciem jej jako numeru.",
                    icon: "barcode"
                )

                if issueNumber.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    EditorialActionRow(
                        title: "Użyj dodatku jako numeru",
                        detail: "Skopiuj \(cleanEANSupplement) do pola numeru i potwierdź z okładką.",
                        icon: "arrow.down.doc",
                        accent: LibraryPalette.orangeText
                    ) {
                        issueNumber = cleanEANSupplement
                        UIAccessibility.post(
                            notification: .announcement,
                            argument: "Wpisano numer \(cleanEANSupplement). Sprawdź go z okładką."
                        )
                    }
                }
            }

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

            Group {
                if dynamicTypeSize.isAccessibilitySize {
                    accessibilitySaveButton
                } else {
                    EditorialPrimaryButton(
                        title: saveButtonTitle,
                        isLoading: isSaving
                    ) {
                        save()
                    }
                }
            }
            .disabled(!canSave || isSaving)
            .opacity(canSave && !isSaving ? 1 : 0.5)
            .padding(.vertical, LibrarySpacing.small)
            .editorialPage(width: 760)
        }
        .background(LibraryPalette.paper)
    }

    private var accessibilitySaveButton: some View {
        Button(action: save) {
            HStack(spacing: LibrarySpacing.small) {
                Text(isSaving ? "Zapisywanie…" : "Zapisz")
                    .font(.headline.weight(.bold))
                    .lineLimit(1)

                Spacer(minLength: LibrarySpacing.small)

                if isSaving {
                    ProgressView()
                        .tint(.white)
                        .accessibilityHidden(true)
                } else {
                    Image(systemName: "checkmark")
                        .font(.headline)
                        .accessibilityHidden(true)
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, LibrarySpacing.medium)
            .frame(maxWidth: .infinity, minHeight: 56)
            .background(LibraryPalette.orangeAction)
            .clipShape(RoundedRectangle(cornerRadius: LibraryRadius.small))
            .contentShape(RoundedRectangle(cornerRadius: LibraryRadius.small))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(saveButtonTitle)
        .accessibilityValue(isSaving ? "Trwa" : "")
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

    @ViewBuilder
    private var coverPreviewSection: some View {
        if let coverURL = previewCoverURL {
            VStack(alignment: .leading, spacing: LibrarySpacing.medium) {
                EditorialSectionHeader(title: "Okładka", value: "PODGLĄD")

                PublicationCoverView(
                    url: coverURL,
                    title: previewCoverTitle,
                    source: previewCoverSource,
                    mode: .lookup
                )
                .frame(maxWidth: .infinity, alignment: .center)
            }
        }
    }

    private var previewCoverURL: URL? {
        if let publication = duplicateMatch?.publication {
            return publication.resolvedCoverURL
        }

        if let explicitURL = RemoteCoverURLPolicy.validatedReference(coverURLString),
           RemoteCoverURLPolicy.canLoadAutomatically(explicitURL) {
            return explicitURL
        }
        return OpenLibraryCoverURL.url(forISBN: isbn13)
    }

    private var previewCoverTitle: String {
        if let publication = duplicateMatch?.publication {
            return publication.title
        }
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty ? "publikacja bez tytułu" : clean
    }

    private var previewCoverSource: String? {
        if let publication = duplicateMatch?.publication {
            return publication.resolvedCoverSource
        }
        return previewCoverURL == nil
            ? nil
            : (coverSource.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? BookMetadataSource.openLibrary.rawValue
                : coverSource)
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
        guard !(forceNewPeriodicalPublication && publicationType == .periodical) else {
            return nil
        }
        return detectedDuplicateMatch
    }

    private var detectedDuplicateMatch: ExistingPublicationMatch? {
        guard cleanEANSupplement.isEmpty || isValidEANSupplement else {
            return nil
        }
        return ExistingPublicationMatcher.match(
            in: existingItems,
            type: publicationType,
            isbn13: isbn13,
            issn: issn,
            ean: ean,
            barcode: canonicalBarcode(ean: ean, supplement: cleanEANSupplement),
            issueNumber: issueNumber,
            issueDate: issueDate,
            locationPath: LocationPath(catalogingSession.locationText)
        )
    }

    private var cleanEANSupplement: String {
        eanSupplement.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var hasValidPeriodicalEAN: Bool {
        let parsed = PublicationIdentifierParser.parse(ean)
        return parsed.isValid && parsed.kind == .ean13 && parsed.normalized.hasPrefix("977")
    }

    private var isValidEANSupplement: Bool {
        let supplement = cleanEANSupplement
        guard supplement.count == 2 || supplement.count == 5,
              supplement.allSatisfy(\.isNumber) else {
            return false
        }
        let parsed = PublicationIdentifierParser.parse(ean)
        let primary = String(parsed.normalized.prefix(13))
        return parsed.isValid
            && parsed.kind == .ean13
            && primary.hasPrefix("977")
            && PublicationIdentifierParser.isValidEAN13(primary)
    }

    private func canonicalBarcode(ean: String, supplement: String) -> String {
        guard publicationType == .periodical else {
            return barcode.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let parsed = PublicationIdentifierParser.parse(ean)
        let primary = String(parsed.normalized.prefix(13))
        guard parsed.isValid,
              parsed.kind == .ean13,
              primary.hasPrefix("977"),
              PublicationIdentifierParser.isValidEAN13(primary) else {
            return barcode.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let cleanSupplement = supplement.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (cleanSupplement.count == 2 || cleanSupplement.count == 5),
              cleanSupplement.allSatisfy(\.isNumber) else {
            return primary
        }
        return "\(primary)+\(cleanSupplement)"
    }

    private var canSave: Bool {
        CatalogingReadiness.failure(
            serialMode: serialModeEnabled,
            locationText: catalogingSession.locationText,
            publicationType: publicationType,
            title: title,
            hasExistingPublicationMatch: duplicateMatch != nil,
            issueNumber: issueNumber,
            issueDate: issueDate,
            eanSupplement: isValidEANSupplement ? cleanEANSupplement : ""
        ) == nil
    }

    private var saveButtonTitle: String {
        guard let duplicateMatch else { return "Zapisz egzemplarz" }
        return duplicateMatch.kind == .possibleRepeatScan
            ? "Dodaj mimo ostrzeżenia"
            : "Dodaj kolejny egzemplarz"
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

    @ViewBuilder
    private var recentLocationChoices: some View {
        if !recentLocations.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                Text("OSTATNIE MIEJSCA")
                    .font(.caption2.weight(.bold))
                    .tracking(1.35)
                    .foregroundStyle(LibraryPalette.mutedInk)
                    .padding(.bottom, LibrarySpacing.xSmall)

                ForEach(recentLocations, id: \.self) { location in
                    let isSelected = LocationPath(catalogingSession.locationText) == LocationPath(location)
                    Button {
                        catalogingSession.updateLocationText(location)
                    } label: {
                        HStack(spacing: LibrarySpacing.small) {
                            Text(LocationPath(location).display)
                                .font(.footnote)
                                .multilineTextAlignment(.leading)
                            Spacer(minLength: LibrarySpacing.small)
                            Image(systemName: isSelected ? "checkmark" : "arrow.turn.down.left")
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
                    .accessibilityLabel("Użyj lokalizacji: \(LocationPath(location).display)")
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                }
            }
        }
    }

    private func confirmShelfAndScan() {
        let previousLocation = catalogingSession.canonicalLocation.canonical
        let location = catalogingSession.commitLocation()
        guard !location.isEmpty else {
            validationMessage = CatalogingReadinessFailure.missingShelf.message
            return
        }
        validationMessage = nil
        startPilotAttemptIfNeeded()
        // The pilot distinguishes a shelf selected for the first item from a
        // location retained by the serial session. Starting the timer after
        // this setup screen must not turn a fresh/changed shelf into "reused".
        pilotAttemptStartingLocation = previousLocation
        step = .scanner
        UIAccessibility.post(
            notification: .announcement,
            argument: "Bieżąca półka: \(location.display). Możesz skanować."
        )
    }

    private func presentShelfSetupFromScanner() {
        // If a scan/edit attempt is already running, changing its shelf is part
        // of that same attempt. A ready serial slot remains unstarted until the
        // user confirms the new shelf and returns to the camera.
        step = .shelfSetup
    }

    private func duplicateMessage(for match: ExistingPublicationMatch) -> String {
        if match.publication.publicationType == .periodical {
            if match.kind == .possibleRepeatScan {
                return "Na tej półce jest już podobny numer. Dodatek EAN jest wskazówką, nie dowodem: sprawdź numer i datę na okładce. Możesz dodać kopię albo wybrać „To jest inny numer”."
            }
            return "W kolekcji jest podobny numer pisma. Sprawdź numer i datę na okładce; jeśli to inne wydanie, wybierz „To jest inny numer”."
        }

        if match.kind == .possibleRepeatScan {
            let label = match.copyCountAtCurrentLocation == 1 ? "egzemplarz" : "egzemplarze"
            return "Na tej półce są już \(match.copyCountAtCurrentLocation) \(label) tego wydania. Sprawdź, czy nie skanujesz ponownie tej samej sztuki. Zapis mimo to utworzy kolejną kopię."
        }

        let label = match.copyCount == 1 ? "egzemplarz" : "egzemplarze"
        return "W kolekcji są już \(match.copyCount) \(label) tego wydania. Zapis doda następną kopię i zachowa wspólny opis bibliograficzny."
    }

    private func duplicateTitle(for match: ExistingPublicationMatch) -> String {
        if match.publication.publicationType == .periodical {
            return match.kind == .possibleRepeatScan
                ? "Możliwy ponowny skan numeru"
                : "Możliwy kolejny egzemplarz"
        }
        return match.kind == .possibleRepeatScan
            ? "Możliwy ponowny skan"
            : "Kolejny egzemplarz"
    }

    private func prepareSeparatePeriodicalIssue(from publication: Publication) {
        forceNewPeriodicalPublication = true
        if title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            title = publication.title
        }
        if subtitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            subtitle = publication.subtitle
        }
        if authors.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            authors = publication.authorsText
        }
        if publisher.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            publisher = publication.publisher
        }
        if language.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            language = publication.language
        }
        if publicationYear.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let year = publication.publicationYear {
            publicationYear = String(year)
        }
        if issn.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issn = publication.issn
        }
        // The previous match identified a concrete issue. Reusing its
        // discriminator while forcing a new Publication would create a second
        // record of the same issue, so the user must confirm fresh issue data.
        let clearedIdentity = PeriodicalIssueDraftReset.clearedIdentity(
            retainingSeriesEAN: ean
        )
        eanSupplement = clearedIdentity.eanSupplement
        issueNumber = clearedIdentity.issueNumber
        issueVolume = clearedIdentity.issueVolume
        issueDate = clearedIdentity.issueDate
        barcode = clearedIdentity.barcode
        // A new issue may have a different cover even when the series is the same.
        coverURLString = ""
        coverSource = ""
        metadataSource = "manual"
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        UIAccessibility.post(
            notification: .announcement,
            argument: "Nowy numer pisma. Uzupełnij numer lub datę z okładki."
        )
    }

    private func applyPeriodicalOCRSelection(_ selection: PeriodicalCoverOCRSelection) {
        let pilotValuesBeforeApply = currentPilotValues(for: Self.pilotPeriodicalFields)
        var appliedFields: [String] = []
        if issueNumber.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let value = selection.issueNumber {
            issueNumber = value
            appliedFields.append("numer")
        }
        if issueVolume.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let value = selection.issueVolume {
            issueVolume = value
            appliedFields.append("tom")
        }
        if issueDate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let value = selection.issueDate {
            issueDate = value
            appliedFields.append("data")
        }
        guard !appliedFields.isEmpty else { return }
        _ = pilotAttemptTracker.markRecognition()
        capturePilotAutomaticChanges(
            in: Self.pilotPeriodicalFields,
            from: pilotValuesBeforeApply
        )
        metadataSource = "ocr"
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        UIAccessibility.post(
            notification: .announcement,
            argument: "Uzupełniono z okładki: \(appliedFields.joined(separator: ", ")). Sprawdź dane przed zapisem."
        )
    }

    private func undoRecentSave() {
        guard let recentSaveNotice else { return }

        do {
            let result = try CatalogingUndoService.undo(
                itemID: recentSaveNotice.itemID,
                in: modelContext
            )

            if result.didUndo {
                _ = catalogingSession.undoLastSaved(itemID: recentSaveNotice.itemID)
                recordPilotEvent(
                    .mutation(PilotMutationMetric(action: .undoAdd, outcome: .completed))
                )
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                UIAccessibility.post(
                    notification: .announcement,
                    argument: "Cofnięto dodanie: \(recentSaveNotice.title)."
                )
            } else {
                UIAccessibility.post(
                    notification: .announcement,
                    argument: "Ostatniego wpisu nie ma już w kolekcji."
                )
            }
            self.recentSaveNotice = nil
        } catch {
            recordPilotEvent(
                .mutation(PilotMutationMetric(action: .undoAdd, outcome: .failed))
            )
            validationMessage = "Nie udało się cofnąć ostatniego dodania: \(error.localizedDescription)"
        }
    }

    private func startRescan() {
        recordPilotDuplicatePreventionIfNeeded()
        clearPublicationFields(preserveCopyFields: true)
        step = .scanner
    }

    private func prepareNextPublication(startWithScanner: Bool) {
        isSaving = false
        serialModeEnabled = startWithScanner
        clearPublicationFields(preserveCopyFields: false)
        let needsShelf = startWithScanner && LocationPath(catalogingSession.locationText).isEmpty
        // Wybór pustej sesji półki jeszcze nie jest próbą katalogowania.
        // Pomiar zaczyna się po zatwierdzeniu miejsca albo przy wejściu ręcznym.
        resetPilotAttemptForNextPublication(startImmediately: !needsShelf)
        step = needsShelf ? .shelfSetup : (startWithScanner ? .scanner : .form)
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
        eanSupplement = ""
        issueNumber = ""
        issueVolume = ""
        issueDate = ""
        metadataSource = "manual"
        coverURLString = ""
        coverSource = ""
        validationMessage = nil
        showsMoreData = false
        forceNewPeriodicalPublication = false
        pilotDuplicateDecisionRecorded = false

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
        barcode = parsed.eanSupplement.map { "\(parsed.normalized)+\($0)" }
            ?? rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        eanSupplement = parsed.eanSupplement ?? ""

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

    /// Reuses only the series-level description from a periodical that is
    /// already in the user's collection. A new issue never inherits a number,
    /// date, volume, barcode or cover from the older issue.
    @discardableResult
    private func applyKnownPeriodicalSeriesPrefill() -> Bool {
        guard publicationType == .periodical,
              let prefill = PeriodicalSeriesPrefillResolver.prefill(
                in: existingItems,
                incomingISSN: issn,
                incomingEAN: ean
              ) else {
            return false
        }

        var didApply = false
        func fill(_ current: inout String, with value: String) {
            guard current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return
            }
            current = value
            didApply = true
        }

        fill(&title, with: prefill.title)
        fill(&subtitle, with: prefill.subtitle)
        fill(&authors, with: prefill.authors)
        fill(&publisher, with: prefill.publisher)
        if language.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || language == "pl" {
            let incomingLanguage = prefill.language.trimmingCharacters(in: .whitespacesAndNewlines)
            if !incomingLanguage.isEmpty, language != incomingLanguage {
                language = incomingLanguage
                didApply = true
            }
        }
        return didApply
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
            language: language,
            coverURLString: coverURLString,
            coverSource: coverSource
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

                let pilotValuesBeforeApply = currentPilotValues(for: Self.pilotMetadataFields)
                apply(metadata: metadata, preservingChangesSince: snapshot)
                _ = pilotAttemptTracker.markRecognition()
                capturePilotAutomaticChanges(
                    in: Self.pilotMetadataFields,
                    from: pilotValuesBeforeApply
                )
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
        if coverSource == BookMetadataSource.openLibrary.rawValue {
            coverURLString = ""
            coverSource = ""
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
        if coverURLString == snapshot.coverURLString,
           coverSource == snapshot.coverSource,
           let value = metadata.coverURL {
            coverURLString = value.absoluteString
            coverSource = metadata.coverSource?.rawValue ?? ""
        }
    }

    private func save() {
        guard !isSaving else { return }
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
        var supplement = cleanEANSupplement
        if !normalizedEAN.isEmpty {
            let parsed = PublicationIdentifierParser.parse(normalizedEAN)
            if parsed.kind == .ean13 || parsed.kind == .isbn13 {
                guard parsed.isValid else {
                    validationMessage = "EAN-13 ma nieprawidłową cyfrę kontrolną."
                    return
                }
                normalizedEAN = String(parsed.normalized.prefix(13))
                if supplement.isEmpty, let parsedSupplement = parsed.eanSupplement {
                    supplement = parsedSupplement
                }
            }
        }

        if !supplement.isEmpty {
            guard publicationType == .periodical,
                  (supplement.count == 2 || supplement.count == 5),
                  supplement.allSatisfy(\.isNumber) else {
                validationMessage = "Dodatek EAN musi mieć dokładnie 2 albo 5 cyfr."
                return
            }
            guard normalizedEAN.hasPrefix("977"),
                  PublicationIdentifierParser.isValidEAN13(normalizedEAN) else {
                validationMessage = "Dodatek EAN można zapisać tylko razem z prawidłowym kodem prasy 977."
                return
            }
        }
        let normalizedBarcode = canonicalBarcode(ean: normalizedEAN, supplement: supplement)

        let forceNewPublication = forceNewPeriodicalPublication && publicationType == .periodical
        let match = forceNewPublication
            ? nil
            : ExistingPublicationMatcher.match(
                in: existingItems,
                type: publicationType,
                isbn13: normalizedISBN,
                issn: issn,
                ean: normalizedEAN,
                barcode: normalizedBarcode,
                issueNumber: issueNumber,
                issueDate: issueDate,
                locationPath: LocationPath(catalogingSession.locationText)
            )

        if let readinessFailure = CatalogingReadiness.failure(
            serialMode: serialModeEnabled,
            locationText: catalogingSession.locationText,
            publicationType: publicationType,
            title: cleanTitle,
            hasExistingPublicationMatch: match != nil,
            issueNumber: issueNumber,
            issueDate: issueDate,
            eanSupplement: supplement
        ) {
            validationMessage = readinessFailure.message
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
        let request = CatalogingSaveRequest(
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
            barcode: normalizedBarcode,
            issueNumber: issueNumber.trimmingCharacters(in: .whitespacesAndNewlines),
            issueVolume: issueVolume.trimmingCharacters(in: .whitespacesAndNewlines),
            issueDate: issueDate.trimmingCharacters(in: .whitespacesAndNewlines),
            metadataSource: metadataSource,
            coverURLString: coverURLString,
            coverSource: coverSource,
            locationPathText: catalogingSession.locationText,
            notes: notes.trimmingCharacters(in: .whitespacesAndNewlines),
            savedAt: now,
            forceNewPublication: forceNewPublication
        )

        isSaving = true
        do {
            let result = try CatalogingService(modelContext: modelContext).save(request)
            onMutation?()
            if forceNewPublication || result.duplicateKind == .possibleRepeatScan {
                recordPilotDuplicateDecision(.duplicateOverride, outcome: .completed)
            }
            recordCompletedPilotAttempt()
            recordPilotLocationOutcome()
            catalogingSession.recordSaved(itemID: result.item.id, savedAt: now)
            savedTitle = result.publication.title
            savedLocation = catalogingSession.canonicalLocation.canonical
            savedCopyCount = result.copyCount
            savedUsedExistingPublication = result.usedExisting

            if serialModeEnabled {
                let scannedCode = normalizedBarcode
                recentSaveNotice = RecentSaveNotice(
                    itemID: result.item.id,
                    title: result.publication.title,
                    suppressedCode: scannedCode.isEmpty ? nil : scannedCode
                )
                clearPublicationFields(preserveCopyFields: false)
                // Merely waiting for another book is not an attempt. The ready
                // tracker starts lazily when a new scan/manual action arrives.
                resetPilotAttemptForNextPublication(startImmediately: false)
                step = .scanner
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                UIAccessibility.post(
                    notification: .announcement,
                    argument: "Dodano do kolekcji: \(result.publication.title). Możesz skanować następną publikację."
                )
            } else {
                step = .saved
            }
        } catch {
            if forceNewPublication || match?.kind == .possibleRepeatScan {
                recordPilotDuplicateDecision(.duplicateOverride, outcome: .failed, terminal: false)
            }
            isSaving = false
            validationMessage = "Nie udało się zapisać publikacji: \(error.localizedDescription)"
        }
    }

    private func startPilotAttemptIfNeeded() {
        guard pilotAttemptTracker.state == .ready else { return }
        pilotAttemptStartingLocation = LocationPath(catalogingSession.locationText).canonical
        _ = pilotAttemptTracker.start()
        if scenePhase != .active {
            _ = pilotAttemptTracker.pause()
        }
    }

    private func resetPilotAttemptForNextPublication(startImmediately: Bool) {
        pilotAttemptTracker = PilotAttemptTracker(publicationKind: .book)
        pilotAttemptMetricRecorded = false
        pilotAutofillCorrections = PilotAutofillCorrectionTracker()
        pilotAttemptStartingLocation = LocationPath(catalogingSession.locationText).canonical
        if startImmediately {
            startPilotAttemptIfNeeded()
        }
    }

    private func finishPilotAttempt(cancelled: Bool) {
        if cancelled {
            recordPilotDuplicatePreventionIfNeeded()
        }
        guard cancelled,
              !pilotAttemptMetricRecorded,
              let metric = pilotAttemptTracker.cancel(
                publicationKind: pilotPublicationKind,
                manualCorrectionCount: pilotManualCorrectionCount,
                hadAutomaticFieldFill: pilotAutofillCorrections.hasAutomaticFieldFill
              ) else {
            return
        }
        pilotAttemptMetricRecorded = true
        recordPilotEvent(.catalog(metric))
    }

    private func recordCompletedPilotAttempt() {
        guard !pilotAttemptMetricRecorded,
              let metric = pilotAttemptTracker.complete(
                publicationKind: pilotPublicationKind,
                manualCorrectionCount: pilotManualCorrectionCount,
                hadAutomaticFieldFill: pilotAutofillCorrections.hasAutomaticFieldFill
              ) else {
            return
        }
        pilotAttemptMetricRecorded = true
        recordPilotEvent(.catalog(metric))
    }

    private var pilotPublicationKind: PilotPublicationKind {
        publicationType == .periodical ? .periodical : .book
    }

    private var pilotManualCorrectionCount: Int {
        pilotAutofillCorrections.correctionCount { field in
            currentPilotValue(for: field)
        }
    }

    private func currentPilotValues(
        for fields: [PilotTrackedField]
    ) -> [PilotTrackedField: String] {
        Dictionary(uniqueKeysWithValues: fields.map { field in
            (field, currentPilotValue(for: field))
        })
    }

    private func capturePilotAutomaticChanges(
        in fields: [PilotTrackedField],
        from previousValues: [PilotTrackedField: String]
    ) {
        var corrections = pilotAutofillCorrections
        for field in fields {
            guard let previousValue = previousValues[field] else { continue }
            _ = corrections.recordAutomaticChange(
                for: field,
                from: previousValue,
                to: currentPilotValue(for: field)
            )
        }
        pilotAutofillCorrections = corrections
    }

    private func currentPilotValue(for field: PilotTrackedField) -> String {
        switch field {
        case .title: title
        case .subtitle: subtitle
        case .authors: authors
        case .language: language
        case .publisher: publisher
        case .publicationYear: publicationYear
        case .isbn: isbn13
        case .issn: issn
        case .ean: ean
        case .barcode: barcode
        case .issueNumber: issueNumber
        case .issueVolume: issueVolume
        case .issueDate: issueDate
        }
    }

    private func recordPilotLocationOutcome() {
        let current = LocationPath(catalogingSession.locationText).canonical
        let outcome: PilotLocationOutcome
        if current.isEmpty {
            outcome = .none
        } else if pilotAttemptStartingLocation.isEmpty {
            outcome = .freshSelection
        } else if LocationPath(current) == LocationPath(pilotAttemptStartingLocation) {
            outcome = .reusedPrevious
        } else {
            outcome = .changed
        }
        recordPilotEvent(.location(PilotLocationMetric(outcome: outcome)))
    }

    /// A possible repeat scan is a guardrail, not a bibliographic fact. We only
    /// count an explicit outcome: rescan/dismiss prevents it, while a successful
    /// save (or the explicit periodical override) accepts it.
    private func recordPilotDuplicatePreventionIfNeeded() {
        guard !pilotAttemptMetricRecorded,
              duplicateMatch?.kind == .possibleRepeatScan else { return }
        recordPilotDuplicateDecision(.duplicatePrevented, outcome: .completed)
    }

    private func recordPilotDuplicateDecision(
        _ action: PilotMutationAction,
        outcome: PilotOperationOutcome,
        terminal: Bool = true
    ) {
        guard !pilotDuplicateDecisionRecorded else { return }
        if terminal {
            pilotDuplicateDecisionRecorded = true
        }
        recordPilotEvent(.mutation(PilotMutationMetric(action: action, outcome: outcome)))
    }

    private func recordPilotEvent(_ event: PilotMetricEvent) {
        guard let pilotMetricsStore else { return }
        Task {
            _ = try? await pilotMetricsStore.record(event)
        }
    }
}
