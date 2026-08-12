import SwiftData
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct ContentView: View {
    fileprivate enum CollectionDisplayMode: String, CaseIterable, Identifiable {
        case covers
        case list

        var id: Self { self }

        var label: String {
            switch self {
            case .list: "Lista"
            case .covers: "Okładki"
            }
        }

        var symbolName: String {
            switch self {
            case .list: "list.bullet"
            case .covers: "square.grid.2x2"
            }
        }
    }

    private enum AddItemRoute: Hashable, Identifiable {
        case scanner, manual
        var id: Self { self }
        var startsWithScanner: Bool { self == .scanner }
    }

    private struct EditItemRoute: Identifiable {
        let id = UUID()
        let prepared: CatalogItemPreparedEdit
        let mode: ItemEditFlow.Mode
    }

    private struct PendingDeletion: Identifiable {
        let id: UUID
        let title: String
        let location: String
        let copyDescription: String
    }

    private enum CatalogMutationReceipt {
        case edit(CatalogItemEditResult)
        case deletion(CatalogItemDeletionReceipt)
    }

    private struct CatalogMutationNotice: Identifiable {
        let id = UUID()
        let title: String
        let message: String?
        let receipt: CatalogMutationReceipt
    }

    @Environment(\.modelContext) private var modelContext
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.scenePhase) private var scenePhase
    @Query(sort: \OwnedItem.addedAt, order: .reverse) private var items: [OwnedItem]
    @AppStorage("collectionID") private var collectionID = ""
    @AppStorage("collectionName") private var collectionName = "Moja biblioteka"
    @AppStorage("collectionDisplayMode") private var collectionDisplayModeRawValue = CollectionDisplayMode.list.rawValue
    @State private var searchText = ""
    @State private var navigationPath: [PersistentIdentifier] = []
    @State private var showingPeriodicalOverview = false
    @State private var addItemRoute: AddItemRoute?
    @State private var editItemRoute: EditItemRoute?
    @State private var pendingDeletion: PendingDeletion?
    @State private var mutationNotice: CatalogMutationNotice?
    @State private var exportDocument: CollectionJSONDocument?
    @State private var showingExporter = false
    @State private var showingExportPhotoWarning = false
    @State private var showingImporter = false
    @State private var isImporting = false
    @State private var message: ExportMessage?
    @State private var showingPilotDashboard = false
    @State private var showingPilotVerifier = false
    @State private var pilotVerificationOriginalData: Data?
    @State private var pilotSearchTracker = PilotSearchTracker()

    private let pilotMetricsStore: PilotMetricsStore

    init(pilotMetricsStore: PilotMetricsStore = PilotMetricsStore()) {
        self.pilotMetricsStore = pilotMetricsStore
    }

    private var filteredItems: [OwnedItem] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return items }
        return items.filter { item in
            let publication = item.publication
            return [publication?.title, publication?.subtitle, publication?.authorsText,
                    publication?.isbn13, publication?.issn, publication?.ean,
                    publication?.barcode, publication?.issueNumber,
                    publication?.issueVolume, publication?.issueDate,
                    item.locationPathText, item.notes]
                .compactMap { $0 }
                .contains { $0.localizedCaseInsensitiveContains(query) }
        }
    }

    private var collectionMetrics: [EditorialMetric] {
        [
            EditorialMetric(
                value: String(items.count),
                label: horizontalSizeClass == .compact ? "Egz." : "Egzemplarze"
            ),
            EditorialMetric(value: String(items.count { $0.publication?.publicationType == .book }), label: "Książki"),
            EditorialMetric(value: String(items.count { $0.publication?.publicationType == .periodical }), label: "Prasa"),
            EditorialMetric(
                value: String(locationCount),
                label: horizontalSizeClass == .compact ? "Miejsca" : "Lokalizacje"
            )
        ]
    }

    private var locationCount: Int {
        Set(items.compactMap { item -> LocationPath? in
            let path = LocationPath(item.locationPathText)
            return path.isEmpty ? nil : path
        }).count
    }

    private var hasPeriodicals: Bool {
        items.contains { $0.publication?.publicationType == .periodical }
    }

    private var collectionDisplayMode: CollectionDisplayMode {
        CollectionDisplayMode(rawValue: collectionDisplayModeRawValue) ?? .list
    }

    private var collectionDisplayModeBinding: Binding<CollectionDisplayMode> {
        Binding(
            get: { collectionDisplayMode },
            set: { mode in
                collectionDisplayModeRawValue = mode.rawValue
                UIAccessibility.post(
                    notification: .announcement,
                    argument: "Widok kolekcji: \(mode.label.lowercased())"
                )
            }
        )
    }

    private var coverGridColumns: [GridItem] {
        if dynamicTypeSize.isAccessibilitySize {
            return [GridItem(.flexible(), spacing: 0, alignment: .top)]
        }

        return [
            GridItem(
                .adaptive(
                    minimum: horizontalSizeClass == .regular ? 190 : 142,
                    maximum: 235
                ),
                spacing: horizontalSizeClass == .regular ? LibrarySpacing.medium : LibrarySpacing.small,
                alignment: .top
            )
        ]
    }

    var body: some View {
        NavigationStack(path: $navigationPath) {
            ZStack {
                PaperBackground()
                if items.isEmpty {
                    emptyCollectionView
                } else {
                    populatedCollectionView
                }
            }
            .foregroundStyle(LibraryPalette.ink)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { collectionToolbar }
            .toolbarBackground(LibraryPalette.paper, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(.light, for: .navigationBar)
            .navigationDestination(for: PersistentIdentifier.self) { persistentID in
                itemDestination(persistentID)
            }
            .navigationDestination(isPresented: $showingPeriodicalOverview) {
                PeriodicalOverviewView(items: items)
            }
            .navigationDestination(isPresented: $showingPilotDashboard) {
                PilotDashboardView(
                    store: pilotMetricsStore,
                    onVerifyRoundTrip: presentPilotRoundTripVerifier
                )
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if let notice = mutationNotice {
                EditorialUndoBand(
                    title: notice.title,
                    message: notice.message,
                    accessibilityIdentifier: "collection.mutationConfirmation",
                    undoAccessibilityIdentifier: "collection.undoMutation",
                    dismissAccessibilityIdentifier: "collection.dismissMutation",
                    onDismiss: { mutationNotice = nil },
                    onUndo: undoLatestMutation
                )
                .padding(.horizontal, LibrarySpacing.page)
                .padding(.vertical, LibrarySpacing.small)
                .background(LibraryPalette.paper)
            }
        }
        .sheet(item: $addItemRoute) { route in
            AddItemFlow(
                startWithScanner: route.startsWithScanner,
                pilotMetricsStore: pilotMetricsStore,
                onMutation: { mutationNotice = nil }
            )
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        .sheet(item: $editItemRoute) { route in
            ItemEditFlow(prepared: route.prepared, mode: route.mode) { result in
                recordEdit(result, mode: route.mode)
            }
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
        }
        .fileExporter(isPresented: $showingExporter, document: exportDocument,
                      contentType: .json, defaultFilename: "domowa-biblioteka.json") { result in
            switch result {
            case .success:
                recordPilotTransfer(direction: .export, outcome: .completed)
                message = ExportMessage(title: "Eksport gotowy", details: "Plik JSON można wczytać na stronie WWW.")
            case .failure(let error):
                guard !isFilePickerCancellation(error) else {
                    recordPilotTransfer(direction: .export, outcome: .cancelled)
                    return
                }
                recordPilotTransfer(direction: .export, outcome: .failed)
                message = ExportMessage(title: "Nie udało się wyeksportować", details: error.localizedDescription)
            }
        }
        .fileImporter(isPresented: $showingImporter, allowedContentTypes: [.json], allowsMultipleSelection: false) { result in
            handleImportResult(result)
        }
        .fileImporter(
            isPresented: $showingPilotVerifier,
            allowedContentTypes: [.json],
            allowsMultipleSelection: false,
            onCompletion: handlePilotVerificationResult
        )
        .confirmationDialog(
            "Eksport JSON nie zawiera własnych zdjęć",
            isPresented: $showingExportPhotoWarning,
            titleVisibility: .visible
        ) {
            Button("Eksportuj bez zdjęć") {
                prepareExport()
            }
            Button("Anuluj", role: .cancel) {}
        } message: {
            Text("Opisy, identyfikatory i lokalizacje zostaną zapisane. Zdjęcia okładek pozostaną tylko w aplikacji na tym urządzeniu.")
        }
        .confirmationDialog(
            "Usunąć egzemplarz z kolekcji?",
            isPresented: deletionConfirmationBinding,
            titleVisibility: .visible,
            presenting: pendingDeletion
        ) { deletion in
            Button("Usuń z kolekcji", role: .destructive) {
                deleteItem(id: deletion.id)
            }
            Button("Anuluj", role: .cancel) {
                pendingDeletion = nil
            }
        } message: { deletion in
            Text("„\(deletion.title)” · \(deletion.location). \(deletion.copyDescription). Usunięcie będzie można od razu cofnąć.")
        }
        .alert(item: $message) { value in
            Alert(title: Text(value.title), message: Text(value.details), dismissButton: .default(Text("OK")))
        }
        .onChange(of: searchText) { _, newValue in
            if let metric = pilotSearchTracker.searchTextChanged(
                isEmpty: newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ) {
                recordPilotEvent(.search(metric))
            }
        }
        .onChange(of: scenePhase) { _, newValue in
            guard newValue != .active,
                  let metric = pilotSearchTracker.background() else { return }
            recordPilotEvent(.search(metric))
        }
        .onDisappear {
            finishPilotSearchForNavigation()
        }
        .task {
            if collectionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                collectionID = UUID().uuidString
            }
#if DEBUG
            applyUITestDestinationIfRequested()
#endif
        }
#if DEBUG
        .onChange(of: items.count) { _, _ in
            applyUITestDestinationIfRequested()
        }
#endif
        .libraryLightAppearance()
    }

#if DEBUG
    private func applyUITestDestinationIfRequested() {
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains("-ui-testing"),
              let destinationIndex = arguments.firstIndex(of: "-ui-destination"),
              arguments.indices.contains(destinationIndex + 1) else {
            return
        }

        switch arguments[destinationIndex + 1] {
        case "item-detail":
            let requestedTitle: String? = arguments.firstIndex(of: "-ui-item-title")
                .flatMap { index in arguments.indices.contains(index + 1) ? arguments[index + 1] : nil }
            let item = requestedTitle
                .flatMap { title in items.first { $0.publication?.title == title } }
                ?? items.first
            if navigationPath.isEmpty, let item {
                navigationPath = [item.persistentModelID]
            }
        case "add-manual":
            if addItemRoute == nil {
                addItemRoute = .manual
            }
        case "add-scan":
            if addItemRoute == nil {
                addItemRoute = .scanner
            }
        case "periodical-overview":
            if !showingPeriodicalOverview, hasPeriodicals {
                showingPeriodicalOverview = true
            }
        case "pilot-dashboard":
            if !showingPilotDashboard {
                showingPilotDashboard = true
            }
        default:
            break
        }
    }
#endif

    @ToolbarContentBuilder
    private var collectionToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button { presentAddFlow(scanner: true) } label: {
                ViewThatFits(in: .horizontal) {
                    Label("Skanuj", systemImage: "barcode.viewfinder").font(.subheadline.weight(.bold))
                    Image(systemName: "barcode.viewfinder")
                }
                .frame(minWidth: 44, minHeight: 44)
            }
            .accessibilityLabel("Skanuj publikację")
        }
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Button { presentAddFlow(scanner: false) } label: {
                    Label("Dodaj ręcznie", systemImage: "square.and.pencil")
                }
                Button(action: requestExport) {
                    Label("Eksportuj JSON", systemImage: "square.and.arrow.up")
                }
                .disabled(items.isEmpty)
                Button(action: presentImporter) {
                    Label(isImporting ? "Importowanie…" : "Importuj JSON",
                          systemImage: isImporting ? "hourglass" : "square.and.arrow.down")
                }
                .disabled(isImporting)
                Divider()
                Button(action: presentPilotDashboard) {
                    Label("Pilot 100–200", systemImage: "gauge.with.dots.needle.67percent")
                }
            } label: {
                Image(systemName: "ellipsis").font(.body.weight(.bold)).frame(width: 44, height: 44)
            }
            .accessibilityLabel("Więcej opcji kolekcji")
        }
    }

    private var emptyCollectionView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: LibrarySpacing.large) {
                LibraryMasthead(title: collectionName, eyebrow: "KOLEKCJA · 00")
                VStack(alignment: .leading, spacing: LibrarySpacing.small) {
                    Text("Każda publikacja.\nNa właściwej półce.")
                        .font(.system(.largeTitle, design: .serif, weight: .bold))
                        .fontWidth(.condensed)
                        .tracking(-0.8)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                    Text("Zeskanuj kod z okładki, sprawdź odnalezione dane i zapisz miejsce. Potem wystarczy kilka sekund, żeby znaleźć książkę albo numer pisma.")
                        .font(.system(.title3, design: .serif))
                        .lineSpacing(4)
                        .foregroundStyle(LibraryPalette.mutedInk)
                        .frame(maxWidth: 680, alignment: .leading)
                }
                EditorialSectionHeader(title: "Jak to działa", value: "3 kroki")
                VStack(spacing: 0) {
                    EmptyCollectionStep(number: 1, title: "Skanuj kod",
                                        detail: "Skieruj aparat na ISBN, ISSN albo EAN z tylnej okładki.")
                    EmptyCollectionStep(number: 2, title: "Sprawdź opis",
                                        detail: "Uzupełnimy tytuł, autora i wydanie; wszystko możesz poprawić.")
                    EmptyCollectionStep(number: 3, title: "Zapisz miejsce",
                                        detail: "Dodaj pokój, regał i półkę, żeby publikacja zawsze była pod ręką.")
                }
                .overlay(alignment: .bottom) { Rectangle().fill(LibraryPalette.rule).frame(height: 1) }
                EditorialPrimaryButton(title: "Zeskanuj pierwszą publikację", icon: "barcode.viewfinder") {
                    presentAddFlow(scanner: true)
                }
                VStack(spacing: 0) {
                    EditorialActionRow(title: "Dodaj ręcznie",
                                       detail: "Gdy kodu nie ma albo wolisz wpisać dane samodzielnie.",
                                       icon: "square.and.pencil", accent: LibraryPalette.orangeText) {
                        presentAddFlow(scanner: false)
                    }
                    EditorialActionRow(title: isImporting ? "Importowanie…" : "Importuj kolekcję",
                                       detail: "Wczytaj plik JSON utworzony na stronie WWW.",
                                       icon: isImporting ? "hourglass" : "square.and.arrow.down",
                                       accent: LibraryPalette.orangeText) {
                        presentImporter()
                    }
                    .disabled(isImporting)
                    .opacity(isImporting ? 0.55 : 1)
                }
            }
            .editorialPage(width: 980)
            .padding(.top, LibrarySpacing.small)
            .padding(.bottom, LibrarySpacing.xLarge)
        }
        .scrollIndicators(.hidden)
    }

    private var populatedCollectionView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: LibrarySpacing.large) {
                LibraryMasthead(title: collectionName,
                                eyebrow: "KOLEKCJA · \(paddedCount(items.count))",
                                subtitle: "Domowy katalog książek i prasy — razem z miejscem, w którym stoi każdy egzemplarz.",
                                compact: horizontalSizeClass == .compact)
                EditorialMetricStrip(metrics: collectionMetrics)
                EditorialPrimaryButton(title: "Skanuj publikację", icon: "barcode.viewfinder") {
                    presentAddFlow(scanner: true)
                }
                .frame(maxWidth: 420, alignment: .leading)
                if hasPeriodicals {
                    EditorialActionRow(
                        title: "Serie prasy",
                        detail: "Przejrzyj zapisane numery, luki pomiędzy nimi oraz potencjalne duplikaty.",
                        icon: "newspaper",
                        accent: LibraryPalette.orangeText
                    ) {
                        presentPeriodicalOverview()
                    }
                    .accessibilityIdentifier("collection.periodicalOverview")
                }
                EditorialSearchField(text: $searchText) {
                    if let metric = pilotSearchTracker.submit(resultCount: filteredItems.count) {
                        recordPilotEvent(.search(metric))
                    }
                }
                if filteredItems.isEmpty {
                    noSearchResults
                } else {
                    CollectionResultsHeader(
                        title: searchText.nilIfBlank == nil ? "Publikacje" : "Wyniki wyszukiwania",
                        value: paddedCount(filteredItems.count),
                        selection: collectionDisplayModeBinding
                    )
                    collectionRows
                }
            }
            .editorialPage(width: 980)
            .padding(.top, LibrarySpacing.small)
            .padding(.bottom, LibrarySpacing.xLarge)
        }
        .scrollDismissesKeyboard(.interactively)
        .scrollIndicators(.hidden)
    }

    @ViewBuilder private var collectionRows: some View {
        switch collectionDisplayMode {
        case .list:
            LazyVStack(spacing: 0) { publicationRows }
                .overlay(alignment: .bottom) { Rectangle().fill(LibraryPalette.rule).frame(height: 1) }

        case .covers:
            LazyVGrid(
                columns: coverGridColumns,
                alignment: .leading,
                spacing: horizontalSizeClass == .regular ? LibrarySpacing.large : LibrarySpacing.medium
            ) {
                publicationCoverCards
            }
        }
    }

    @ViewBuilder private var publicationRows: some View {
        ForEach(Array(filteredItems.enumerated()), id: \.element.persistentModelID) { index, item in
            PublicationRow(
                index: index + 1,
                item: item,
                openAction: { openPublication(item) },
                editAction: { presentItemEditor(id: item.id, mode: .full) },
                moveAction: { presentItemEditor(id: item.id, mode: .moveOnly) },
                deleteAction: { requestDeletion(of: item) }
            )
        }
    }

    @ViewBuilder private var publicationCoverCards: some View {
        ForEach(Array(filteredItems.enumerated()), id: \.element.persistentModelID) { index, item in
            CollectionCoverCard(
                index: index + 1,
                item: item,
                openAction: { openPublication(item) },
                editAction: { presentItemEditor(id: item.id, mode: .full) },
                moveAction: { presentItemEditor(id: item.id, mode: .moveOnly) },
                deleteAction: { requestDeletion(of: item) }
            )
        }
    }

    private var noSearchResults: some View {
        VStack(alignment: .leading, spacing: LibrarySpacing.medium) {
            EditorialSectionHeader(title: "Wyniki wyszukiwania", value: "00")
            Text("Nie znaleźliśmy takiej publikacji.")
                .font(.system(.title, design: .serif, weight: .bold))
            Text("Sprawdź tytuł, autora, kod lub nazwę lokalizacji i spróbuj ponownie.")
                .font(.system(.body, design: .serif))
                .lineSpacing(3)
                .foregroundStyle(LibraryPalette.mutedInk)
            EditorialSecondaryButton(title: "Wyczyść wyszukiwanie", icon: "xmark") { searchText = "" }
                .frame(maxWidth: 420, alignment: .leading)
        }
    }

    private func presentAddFlow(scanner: Bool) {
        finishPilotSearchForNavigation()
        addItemRoute = scanner ? .scanner : .manual
    }

    private func presentImporter() {
        finishPilotSearchForNavigation()
        showingImporter = true
    }

    private func presentPilotDashboard() {
        finishPilotSearchForNavigation()
        showingPilotDashboard = true
    }

    private func presentPeriodicalOverview() {
        finishPilotSearchForNavigation()
        showingPeriodicalOverview = true
    }

    private func openPublication(_ item: OwnedItem) {
        recordPilotSearchResultOpen()
        navigationPath.append(item.persistentModelID)
    }

    @ViewBuilder
    private func itemDestination(_ persistentID: PersistentIdentifier) -> some View {
        if let item = items.first(where: { $0.persistentModelID == persistentID }) {
            ItemDetailView(
                item: item,
                onEdit: { presentItemEditor(id: item.id, mode: .full) },
                onMove: { presentItemEditor(id: item.id, mode: .moveOnly) }
            )
        } else {
            ZStack {
                PaperBackground()
                VStack(alignment: .leading, spacing: LibrarySpacing.medium) {
                    Text("Egzemplarz nie jest już dostępny")
                        .font(.system(.title, design: .serif, weight: .bold))
                    Text("Wróć do kolekcji i odśwież listę.")
                        .font(.system(.body, design: .serif))
                        .foregroundStyle(LibraryPalette.mutedInk)
                }
                .editorialPage(width: 720)
            }
        }
    }

    private var deletionConfirmationBinding: Binding<Bool> {
        Binding(
            get: { pendingDeletion != nil },
            set: { if !$0 { pendingDeletion = nil } }
        )
    }

    private func presentItemEditor(id: UUID, mode: ItemEditFlow.Mode) {
        finishPilotSearchForNavigation()
        do {
            let prepared = try CatalogItemEditingService(modelContext: modelContext).prepare(itemID: id)
            editItemRoute = EditItemRoute(prepared: prepared, mode: mode)
        } catch {
            message = ExportMessage(title: "Nie można otworzyć edycji", details: error.localizedDescription)
        }
    }

    private func requestDeletion(of item: OwnedItem) {
        pendingDeletion = PendingDeletion(
            id: item.id,
            title: item.publication?.title.nilIfBlank ?? "Publikacja bez tytułu",
            location: item.locationDisplayName,
            copyDescription: "Status: \(item.status.label); dodano \(item.addedAt.formatted(date: .numeric, time: .shortened)); kopia \(item.id.uuidString.suffix(4))"
        )
    }

    private func deleteItem(id: UUID) {
        pendingDeletion = nil
        do {
            let receipt = try CatalogItemLifecycleService(modelContext: modelContext).delete(itemID: id)
            let deletedTitle = receipt.publication?.title ?? "Egzemplarz bez opisu"
            mutationNotice = CatalogMutationNotice(
                title: "Usunięto z kolekcji",
                message: "„\(deletedTitle)” · \(locationDisplay(receipt.item.locationPathText))",
                receipt: .deletion(receipt)
            )
            recordPilotMutation(.delete, outcome: .completed)
            announceMutation("Usunięto egzemplarz. Możesz cofnąć tę operację.")
        } catch {
            recordPilotMutation(.delete, outcome: .failed)
            message = ExportMessage(title: "Nie udało się usunąć", details: error.localizedDescription)
        }
    }

    private func recordEdit(_ result: CatalogItemEditResult, mode: ItemEditFlow.Mode) {
        guard result.didChange else { return }

        let title: String
        let details: String
        switch mode {
        case .moveOnly:
            title = "Przeniesiono egzemplarz"
            details = locationDisplay(result.after.draft.item.locationPathText)
        case .full:
            title = "Zapisano zmiany"
            if result.affectedCopyCount > 1 {
                details = "Wspólny opis zaktualizowano dla \(result.affectedCopyCount) egzemplarzy."
            } else {
                details = "Egzemplarz i jego opis są aktualne."
            }
        }
        let notice = CatalogMutationNotice(
            title: title,
            message: details,
            receipt: .edit(result)
        )
        mutationNotice = notice
        recordPilotMutation(mode == .moveOnly ? .move : .edit, outcome: .completed)
        announceAfterDismissal(
            "\(title). Możesz cofnąć tę operację.",
            noticeID: notice.id
        )
    }

    private func undoLatestMutation() {
        guard let notice = mutationNotice else { return }
        do {
            switch notice.receipt {
            case .edit(let result):
                _ = try CatalogItemEditingService(modelContext: modelContext).undo(result)
            case .deletion(let receipt):
                _ = try CatalogItemLifecycleService(modelContext: modelContext).restore(receipt)
            }
            mutationNotice = nil
            recordPilotMutation(.undo, outcome: .completed)
            announceMutation("Cofnięto ostatnią zmianę.")
        } catch {
            recordPilotMutation(.undo, outcome: .failed)
            message = ExportMessage(title: "Nie udało się cofnąć", details: error.localizedDescription)
        }
    }

    private func locationDisplay(_ rawValue: String) -> String {
        let location = LocationPath(rawValue)
        return location.isEmpty ? "Bez lokalizacji" : location.display
    }

    private func announceMutation(_ text: String) {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        UIAccessibility.post(notification: .announcement, argument: text)
    }

    private func announceAfterDismissal(_ text: String, noticeID: UUID) {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(450))
            guard mutationNotice?.id == noticeID else { return }
            UIAccessibility.post(notification: .announcement, argument: text)
        }
    }

    private func prepareExport() {
        finishPilotSearchForNavigation()
        do {
            let trimmed = collectionID.trimmingCharacters(in: .whitespacesAndNewlines)
            let stableID: String
            if trimmed.isEmpty {
                stableID = UUID().uuidString
                collectionID = stableID
            } else {
                stableID = trimmed
            }
            let payload = CollectionExporter.makeExport(items: items, collectionID: stableID, collectionName: collectionName)
            exportDocument = CollectionJSONDocument(data: try CollectionExporter.encode(payload))
            showingExporter = true
        } catch {
            recordPilotTransfer(direction: .export, outcome: .failed)
            message = ExportMessage(title: "Nie udało się przygotować eksportu", details: error.localizedDescription)
        }
    }

    private func requestExport() {
        finishPilotSearchForNavigation()
        if items.contains(where: { item in
            guard let data = item.publication?.coverImageData else { return false }
            return !data.isEmpty
        }) {
            showingExportPhotoWarning = true
        } else {
            prepareExport()
        }
    }

    private func handleImportResult(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let error):
            guard !isFilePickerCancellation(error) else {
                recordPilotTransfer(direction: .import, outcome: .cancelled)
                return
            }
            recordPilotTransfer(direction: .import, outcome: .failed)
            message = ExportMessage(title: "Nie udało się zaimportować", details: error.localizedDescription)
        case .success(let urls):
            guard let url = urls.first else {
                recordPilotTransfer(direction: .import, outcome: .failed)
                message = ExportMessage(title: "Nie udało się zaimportować",
                                        details: CocoaError(.fileNoSuchFile).localizedDescription)
                return
            }
            isImporting = true
            Task { @MainActor in
                defer { isImporting = false }
                do {
                    let prepared = try await Task.detached(priority: .userInitiated) {
                        try CollectionImporter.prepare(fileAt: url)
                    }.value
                    try Task.checkCancellation()
                    let shouldAdoptMetadata = items.isEmpty
                    let report = try CollectionImporter.apply(prepared, into: modelContext)
                    mutationNotice = nil
                    if shouldAdoptMetadata {
                        collectionID = report.collectionID
                        collectionName = report.collectionName
                    }
                    recordPilotTransfer(direction: .import, outcome: .completed)
                    message = ExportMessage(title: "Import zakończony", details: report.summary)
                } catch is CancellationError {
                    recordPilotTransfer(direction: .import, outcome: .cancelled)
                } catch {
                    recordPilotTransfer(direction: .import, outcome: .failed)
                    message = ExportMessage(title: "Nie udało się zaimportować", details: error.localizedDescription)
                }
            }
        }
    }

    private func recordPilotSearchResultOpen() {
        guard let metric = pilotSearchTracker.openResult() else { return }
        recordPilotEvent(.search(metric))
    }

    private func finishPilotSearchForNavigation() {
        guard let metric = pilotSearchTracker.disappear() else { return }
        recordPilotEvent(.search(metric))
    }

    private func presentPilotRoundTripVerifier() {
        finishPilotSearchForNavigation()
        do {
            let payload = CollectionExporter.makeExport(
                items: items,
                collectionID: collectionID.nilIfBlank ?? UUID().uuidString,
                collectionName: collectionName
            )
            pilotVerificationOriginalData = try CollectionExporter.encode(payload)
            showingPilotVerifier = true
        } catch {
            message = ExportMessage(
                title: "Nie udało się przygotować weryfikacji",
                details: error.localizedDescription
            )
            recordPilotTransfer(direction: .roundTrip, outcome: .failed)
        }
    }

    private func handlePilotVerificationResult(_ result: Result<[URL], Error>) {
        defer { pilotVerificationOriginalData = nil }
        switch result {
        case .failure(let error):
            if isFilePickerCancellation(error) {
                recordPilotTransfer(direction: .roundTrip, outcome: .cancelled)
            } else {
                recordPilotTransfer(direction: .roundTrip, outcome: .failed)
                message = ExportMessage(
                    title: "Nie udało się sprawdzić pliku",
                    details: error.localizedDescription
                )
            }
        case .success(let urls):
            guard let originalData = pilotVerificationOriginalData,
                  let url = urls.first else {
                recordPilotTransfer(direction: .roundTrip, outcome: .failed)
                return
            }
            Task { @MainActor in
                do {
                    let restoredData = try await Task.detached(priority: .userInitiated) {
                        let didAccess = url.startAccessingSecurityScopedResource()
                        defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
                        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
                        guard values.isRegularFile == true else {
                            throw PilotVerificationFileReadError.notARegularFile
                        }
                        guard let fileSize = values.fileSize,
                              fileSize <= PilotCollectionVerifier.maximumFileSizeBytes else {
                            throw PilotVerificationFileReadError.tooLarge
                        }
                        return try Data(contentsOf: url, options: [.mappedIfSafe])
                    }.value
                    let report = await Task.detached(priority: .userInitiated) {
                        PilotCollectionVerifier.verify(
                            original: originalData,
                            restored: restoredData
                        )
                    }.value
                    let outcome: PilotTransferOutcome
                    switch report.outcome {
                    case .verified:
                        outcome = .verified
                    case .mismatched:
                        outcome = .mismatch
                    case .originalTooLarge, .restoredTooLarge, .invalidOriginal, .invalidRestored:
                        outcome = .failed
                    }
                    recordPilotTransfer(direction: .roundTrip, outcome: outcome)
                    message = ExportMessage(
                        title: pilotVerificationTitle(report),
                        details: pilotVerificationSummary(report)
                    )
                } catch {
                    recordPilotTransfer(direction: .roundTrip, outcome: .failed)
                    message = ExportMessage(
                        title: "Nie udało się sprawdzić pliku",
                        details: error.localizedDescription
                    )
                }
            }
        }
    }

    private func pilotVerificationSummary(_ report: PilotCollectionVerificationReport) -> String {
        if report.isVerified {
            let count = report.restoredCounts?.ownedItems ?? 0
            return "Plik zachowuje publikacje, egzemplarze, lokalizacje i metadane. Sprawdzono \(count) egzemplarzy bez zmiany bieżącej kolekcji."
        }
        switch report.outcome {
        case .invalidRestored, .restoredTooLarge:
            return "Wybrany plik nie jest prawidłową kolekcją v1 albo przekracza bezpieczny limit."
        case .invalidOriginal, .originalTooLarge:
            return "Nie udało się zbudować bezpiecznego punktu odniesienia z bieżącej kolekcji."
        case .mismatched:
            return "Plik różni się liczbą rekordów, tożsamością, lokalizacjami lub metadanymi. Bieżąca kolekcja nie została zmieniona."
        case .verified:
            return "Weryfikacja zakończona."
        }
    }

    private func pilotVerificationTitle(_ report: PilotCollectionVerificationReport) -> String {
        switch report.outcome {
        case .verified:
            return "Baza odtworzona poprawnie"
        case .mismatched:
            return "Wykryto rozbieżność"
        case .invalidRestored, .restoredTooLarge:
            return "Nie można zweryfikować pliku"
        case .invalidOriginal, .originalTooLarge:
            return "Nie można przygotować porównania"
        }
    }

    private func recordPilotMutation(_ action: PilotMutationAction, outcome: PilotOperationOutcome) {
        recordPilotEvent(.mutation(PilotMutationMetric(action: action, outcome: outcome)))
    }

    private func recordPilotTransfer(
        direction: PilotTransferDirection,
        outcome: PilotTransferOutcome
    ) {
        recordPilotEvent(.transfer(PilotTransferMetric(direction: direction, outcome: outcome)))
    }

    private func recordPilotEvent(_ event: PilotMetricEvent) {
        Task {
            _ = try? await pilotMetricsStore.record(event)
        }
    }

    private func paddedCount(_ count: Int) -> String { String(format: "%02d", count) }
}

private struct EditorialSearchField: View {
    @Binding var text: String
    let onSubmit: () -> Void

    var body: some View {
        HStack(spacing: LibrarySpacing.small) {
            Image(systemName: "magnifyingglass")
                .font(.body.weight(.semibold))
                .foregroundStyle(LibraryPalette.orangeText)
                .accessibilityHidden(true)

            TextField("Tytuł, autor, numer, kod lub lokalizacja", text: $text)
                .font(.body)
                .foregroundStyle(LibraryPalette.ink)
                .submitLabel(.search)
                .autocorrectionDisabled()
                .accessibilityLabel("Szukaj w kolekcji")
                .onSubmit(onSubmit)

            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.body)
                        .foregroundStyle(LibraryPalette.mutedInk)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Wyczyść wyszukiwanie")
            }
        }
        .padding(.leading, LibrarySpacing.medium)
        .padding(.trailing, text.isEmpty ? LibrarySpacing.medium : 0)
        .frame(maxWidth: .infinity, minHeight: 52)
        .background(LibraryPalette.warmPaper)
        .overlay {
            RoundedRectangle(cornerRadius: LibraryRadius.small)
                .stroke(LibraryPalette.controlBorder, lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: LibraryRadius.small))
    }
}

private struct CollectionResultsHeader: View {
    let title: String
    let value: String
    @Binding var selection: ContentView.CollectionDisplayMode
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    var body: some View {
        Group {
            if horizontalSizeClass == .compact || dynamicTypeSize.isAccessibilitySize {
                stackedLayout
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: LibrarySpacing.small) {
                        EditorialSectionHeader(title: title, value: value)
                            .frame(minWidth: 120, maxWidth: .infinity)
                        CollectionDisplayModePicker(selection: $selection)
                    }
                    stackedLayout
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var stackedLayout: some View {
        VStack(alignment: .leading, spacing: LibrarySpacing.small) {
            EditorialSectionHeader(title: title, value: value)
            CollectionDisplayModePicker(selection: $selection)
                .frame(
                    maxWidth: horizontalSizeClass == .compact || dynamicTypeSize.isAccessibilitySize
                        ? .infinity
                        : nil,
                    alignment: .leading
                )
        }
    }
}

private struct CollectionDisplayModePicker: View {
    @Binding var selection: ContentView.CollectionDisplayMode

    var body: some View {
        HStack(spacing: 0) {
            ForEach(ContentView.CollectionDisplayMode.allCases) { mode in
                Button {
                    selection = mode
                } label: {
                    Label(mode.label.uppercased(), systemImage: mode.symbolName)
                        .font(.caption2.weight(.bold))
                        .tracking(0.7)
                        .lineLimit(1)
                        .foregroundStyle(selection == mode ? Color.white : LibraryPalette.mutedInk)
                        .padding(.horizontal, LibrarySpacing.small)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background(selection == mode ? LibraryPalette.ink : Color.clear)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(mode.label)
                .accessibilityValue(selection == mode ? "Wybrano" : "")
                .accessibilityAddTraits(selection == mode ? .isSelected : [])
                .accessibilityIdentifier("collection.displayMode.\(mode.rawValue)")
            }
        }
        .frame(minWidth: 168)
        .fixedSize(horizontal: false, vertical: true)
        .background(LibraryPalette.paper.opacity(0.78))
        .clipShape(RoundedRectangle(cornerRadius: LibraryRadius.small))
        .overlay {
            RoundedRectangle(cornerRadius: LibraryRadius.small)
                .stroke(LibraryPalette.controlBorder, lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Sposób wyświetlania kolekcji")
    }
}

private struct CollectionCoverCard: View {
    let index: Int
    let item: OwnedItem
    let openAction: () -> Void
    let editAction: () -> Void
    let moveAction: () -> Void
    let deleteAction: () -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: openAction) {
                VStack(alignment: .leading, spacing: 0) {
                    CollectionCoverArtwork(publication: item.publication)
                        .padding(LibrarySpacing.small)
                        .padding(.bottom, 0)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 7) {
                        HStack(spacing: 7) {
                            Text(String(format: "%02d", index))
                                .font(.caption2.monospacedDigit().weight(.bold))
                            Rectangle()
                                .fill(LibraryPalette.orange)
                                .frame(width: 18, height: 2)
                                .accessibilityHidden(true)
                            Text(publicationTypeLabel.uppercased())
                                .font(.caption2.weight(.bold))
                                .tracking(1.1)
                                .lineLimit(1)
                        }
                        .foregroundStyle(LibraryPalette.orangeText)

                        Text(item.publication?.title.nilIfBlank ?? "Publikacja bez tytułu")
                            .font(.system(.headline, design: .serif, weight: .bold))
                            .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 3)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(
                                minHeight: dynamicTypeSize.isAccessibilitySize ? nil : 44,
                                alignment: .topLeading
                            )

                        if let detail = publicationDetail {
                            Text(detail)
                                .font(.caption)
                                .foregroundStyle(LibraryPalette.mutedInk)
                                .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(LibrarySpacing.small)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                .foregroundStyle(LibraryPalette.ink)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityLabel)
            .accessibilityHint("Otwiera szczegóły publikacji")
            .accessibilityIdentifier("collection.coverCard.\(item.id.uuidString)")

            HStack(alignment: .center, spacing: LibrarySpacing.xSmall) {
                Image(systemName: "mappin")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(LibraryPalette.orangeText)
                    .accessibilityHidden(true)
                Text(item.locationDisplayName)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(LibraryPalette.mutedInk)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                itemMenu
            }
            .padding(.leading, LibrarySpacing.small)
            .overlay(alignment: .top) {
                Rectangle().fill(LibraryPalette.rule).frame(height: 1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(LibraryPalette.paper.opacity(0.78))
        .clipShape(RoundedRectangle(cornerRadius: LibraryRadius.small))
        .overlay {
            RoundedRectangle(cornerRadius: LibraryRadius.small)
                .stroke(LibraryPalette.controlBorder, lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
    }

    private var itemMenu: some View {
        Menu {
            Button(action: editAction) {
                Label("Edytuj", systemImage: "pencil")
            }
            .accessibilityIdentifier("collection.itemEdit.\(item.id.uuidString)")

            Button(action: moveAction) {
                Label("Przenieś", systemImage: "arrow.left.arrow.right")
            }
            .accessibilityIdentifier("collection.itemMove.\(item.id.uuidString)")

            Divider()

            Button(role: .destructive, action: deleteAction) {
                Label("Usuń z kolekcji", systemImage: "trash")
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.body.weight(.bold))
                .foregroundStyle(LibraryPalette.ink)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("Opcje publikacji \(item.publication?.title.nilIfBlank ?? "bez tytułu")")
        .accessibilityIdentifier("collection.itemOptions.\(item.id.uuidString)")
    }

    private var publicationTypeLabel: String {
        item.publication?.publicationType.label ?? "Publikacja"
    }

    private var publicationDetail: String? {
        guard let publication = item.publication else { return nil }
        if publication.publicationType == .periodical {
            let issue = publication.issueNumber.isEmpty ? nil : "nr \(publication.issueNumber)"
            return [issue, publication.issueDate.nilIfBlank]
                .compactMap { $0 }
                .joined(separator: " · ")
                .nilIfBlank
        }
        return publication.authorsText.nilIfBlank
    }

    private var accessibilityLabel: String {
        [
            item.publication?.title.nilIfBlank ?? "Publikacja bez tytułu",
            publicationDetail,
            publicationTypeLabel,
            item.locationDisplayName
        ]
        .compactMap { $0 }
        .joined(separator: ", ")
    }
}

private struct CollectionCoverArtwork: View {
    let publication: Publication?

    @ViewBuilder
    var body: some View {
        ZStack {
            CollectionEditorialFallbackCover(publication: publication)

            if let publication, publication.hasResolvedCover {
                PublicationCoverView(
                    localData: publication.resolvedCoverImageData,
                    url: publication.resolvedCoverURL,
                    title: publication.title,
                    source: publication.resolvedCoverSource,
                    mode: .collection
                )
                .frame(maxWidth: .infinity)
            }
        }
    }
}

private struct CollectionEditorialFallbackCover: View {
    let publication: Publication?

    var body: some View {
        ZStack(alignment: .leading) {
            fallbackColor

            Rectangle()
                .fill(Color.black.opacity(0.1))
                .frame(width: 8)
            Rectangle()
                .fill(Color.white.opacity(0.08))
                .frame(width: 1)
                .padding(.leading, 9)

            VStack(alignment: .leading, spacing: LibrarySpacing.xSmall) {
                Text(typeLabel.uppercased())
                    .font(.caption2.weight(.bold))
                    .tracking(1.4)

                Spacer(minLength: LibrarySpacing.small)

                Text(monogram)
                    .font(.system(size: 45, weight: .semibold, design: .serif))
                    .fontWidth(.condensed)
                    .tracking(-2.5)
                    .lineLimit(1)
                    .minimumScaleFactor(0.62)

                Rectangle()
                    .fill(Color.white.opacity(0.76))
                    .frame(height: 1)

                Spacer(minLength: LibrarySpacing.small)

                Text(dateLabel.uppercased())
                    .font(.caption2.weight(.bold))
                    .tracking(1.1)
                    .lineLimit(1)
            }
            .foregroundStyle(Color.white)
            .padding(.leading, LibrarySpacing.medium)
            .padding(.trailing, LibrarySpacing.small)
            .padding(.vertical, LibrarySpacing.medium)
        }
        .aspectRatio(3 / 4.15, contentMode: .fit)
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay {
            RoundedRectangle(cornerRadius: 4)
                .stroke(Color.black.opacity(0.22), lineWidth: 1)
        }
        .shadow(color: LibraryPalette.ink.opacity(0.14), radius: 6, x: -1, y: 4)
        .accessibilityHidden(true)
    }

    private var title: String {
        publication?.title.nilIfBlank ?? "Publikacja bez tytułu"
    }

    private var typeLabel: String {
        publication?.publicationType.label ?? "Publikacja"
    }

    private var dateLabel: String {
        guard let publication else { return "bez daty" }
        if publication.publicationType == .periodical {
            return publication.issueDate.nilIfBlank
                ?? publication.issueNumber.nilIfBlank.map { "nr \($0)" }
                ?? "bez daty"
        }
        return publication.publicationYear.map(String.init) ?? "bez daty"
    }

    private var monogram: String {
        let initials = title
            .split(whereSeparator: { $0.isWhitespace || $0.isPunctuation })
            .prefix(2)
            .compactMap(\.first)
        let value = String(initials).uppercased()
        return value.isEmpty ? "?" : value
    }

    private var fallbackColor: Color {
        let palette = [
            Color(hex: "A9470D"),
            Color(hex: "24463F"),
            Color(hex: "3D4650"),
            Color(hex: "7B3F32"),
            Color(hex: "9A651F")
        ]
        let index = title.unicodeScalars.reduce(0) { partial, scalar in
            (partial + Int(scalar.value)) % palette.count
        }
        return palette[index]
    }
}

private struct EmptyCollectionStep: View {
    let number: Int
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: LibrarySpacing.medium) {
            Text(String(format: "%02d", number))
                .font(.caption.monospacedDigit().weight(.bold))
                .tracking(1.2)
                .foregroundStyle(LibraryPalette.orangeText)
                .frame(minWidth: 44, minHeight: 44, alignment: .topLeading)
            VStack(alignment: .leading, spacing: LibrarySpacing.xSmall) {
                Text(title).font(.system(.title3, design: .serif, weight: .bold))
                Text(detail).font(.footnote).lineSpacing(3).foregroundStyle(LibraryPalette.mutedInk)
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, LibrarySpacing.medium)
        .overlay(alignment: .top) { Rectangle().fill(LibraryPalette.rule).frame(height: 1) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Krok \(number): \(title)")
        .accessibilityValue(detail)
    }
}

private struct PublicationRow: View {
    let index: Int
    let item: OwnedItem
    let openAction: () -> Void
    let editAction: () -> Void
    let moveAction: () -> Void
    let deleteAction: () -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        HStack(alignment: .top, spacing: LibrarySpacing.xSmall) {
            Button(action: openAction) {
                HStack(alignment: .top, spacing: LibrarySpacing.small) {
                    if let publication = item.publication,
                       publication.hasResolvedCover,
                       !dynamicTypeSize.isAccessibilitySize {
                        PublicationCoverView(
                            localData: publication.resolvedCoverImageData,
                            url: publication.resolvedCoverURL,
                            title: publication.title,
                            source: publication.resolvedCoverSource,
                            mode: .thumbnail
                        )
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            Text(String(format: "%02d", index)).font(.caption.monospacedDigit().weight(.bold))
                            Rectangle().fill(LibraryPalette.orange).frame(width: 20, height: 2).accessibilityHidden(true)
                            Text(publicationTypeLabel.uppercased()).font(.caption2.weight(.bold)).tracking(1.3)
                        }
                        .foregroundStyle(LibraryPalette.orangeText)
                        Text(item.publication?.title.nilIfBlank ?? "Publikacja bez tytułu")
                            .font(.system(.title3, design: .serif, weight: .bold))
                            .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 3)
                            .fixedSize(horizontal: false, vertical: true)
                        if let detail = publicationDetail {
                            Text(detail).font(.subheadline).foregroundStyle(LibraryPalette.mutedInk)
                                .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        HStack(alignment: .firstTextBaseline, spacing: 7) {
                            Image(systemName: "mappin").font(.caption.weight(.bold))
                                .foregroundStyle(LibraryPalette.orangeText).accessibilityHidden(true)
                            Text(item.locationDisplayName).font(.caption).foregroundStyle(LibraryPalette.mutedInk)
                                .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                .foregroundStyle(LibraryPalette.ink)
                .frame(maxWidth: .infinity, minHeight: 108, alignment: .topLeading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(accessibilityLabel)
            .accessibilityHint("Otwiera szczegóły publikacji")
            Menu {
                Button(action: editAction) {
                    Label("Edytuj", systemImage: "pencil")
                }
                .accessibilityIdentifier("collection.itemEdit.\(item.id.uuidString)")

                Button(action: moveAction) {
                    Label("Przenieś", systemImage: "arrow.left.arrow.right")
                }
                .accessibilityIdentifier("collection.itemMove.\(item.id.uuidString)")

                Divider()

                Button(role: .destructive, action: deleteAction) {
                    Label("Usuń z kolekcji", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis").font(.body.weight(.bold)).foregroundStyle(LibraryPalette.ink)
                    .frame(width: 44, height: 44).contentShape(Rectangle())
            }
            .accessibilityLabel("Opcje publikacji \(item.publication?.title.nilIfBlank ?? "bez tytułu")")
            .accessibilityIdentifier("collection.itemOptions.\(item.id.uuidString)")
        }
        .padding(.vertical, LibrarySpacing.medium)
        .overlay(alignment: .top) { Rectangle().fill(LibraryPalette.rule).frame(height: 1) }
    }

    private var publicationTypeLabel: String { item.publication?.publicationType.label ?? "Publikacja" }
    private var publicationDetail: String? {
        guard let publication = item.publication else { return nil }
        if publication.publicationType == .periodical {
            let issue = publication.issueNumber.isEmpty ? nil : "nr \(publication.issueNumber)"
            return [issue, publication.issueDate.nilIfBlank].compactMap { $0 }.joined(separator: " · ").nilIfBlank
        }
        return publication.authorsText.nilIfBlank
    }
    private var accessibilityLabel: String {
        [item.publication?.title.nilIfBlank ?? "Publikacja bez tytułu", publicationDetail,
         publicationTypeLabel, item.locationDisplayName].compactMap { $0 }.joined(separator: ", ")
    }
}

private func isFilePickerCancellation(_ error: Error) -> Bool {
    if error is CancellationError { return true }
    let cocoaError = error as NSError
    return cocoaError.domain == NSCocoaErrorDomain && cocoaError.code == CocoaError.Code.userCancelled.rawValue
}

private enum PilotVerificationFileReadError: LocalizedError {
    case notARegularFile
    case tooLarge

    var errorDescription: String? {
        switch self {
        case .notARegularFile:
            return "Wybrany element nie jest zwykłym plikiem JSON."
        case .tooLarge:
            return "Plik przekracza bezpieczny limit 25 MB."
        }
    }
}

private struct ExportMessage: Identifiable {
    let id = UUID()
    let title: String
    let details: String
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
