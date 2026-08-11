import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    private enum AddItemRoute: Hashable, Identifiable {
        case scanner, manual
        var id: Self { self }
        var startsWithScanner: Bool { self == .scanner }
    }

    @Environment(\.modelContext) private var modelContext
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Query(sort: \OwnedItem.addedAt, order: .reverse) private var items: [OwnedItem]
    @AppStorage("collectionID") private var collectionID = ""
    @AppStorage("collectionName") private var collectionName = "Moja biblioteka"
    @State private var searchText = ""
    @State private var addItemRoute: AddItemRoute?
    @State private var exportDocument: CollectionJSONDocument?
    @State private var showingExporter = false
    @State private var showingImporter = false
    @State private var isImporting = false
    @State private var message: ExportMessage?

    private var filteredItems: [OwnedItem] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return items }
        return items.filter { item in
            let publication = item.publication
            return [publication?.title, publication?.subtitle, publication?.authorsText,
                    publication?.isbn13, publication?.issn, publication?.ean,
                    item.locationPathText, item.notes]
                .compactMap { $0 }
                .contains { $0.localizedCaseInsensitiveContains(query) }
        }
    }

    private var collectionMetrics: [EditorialMetric] {
        [
            EditorialMetric(value: String(items.count), label: "Egzemplarze"),
            EditorialMetric(value: String(items.count { $0.publication?.publicationType == .book }), label: "Książki"),
            EditorialMetric(value: String(items.count { $0.publication?.publicationType == .periodical }), label: "Prasa"),
            EditorialMetric(value: String(locationCount), label: "Lokalizacje")
        ]
    }

    private var locationCount: Int {
        Set(items.compactMap { item -> String? in
            let value = item.locationPathText.trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        }).count
    }

    private var shouldUseGrid: Bool {
        horizontalSizeClass == .regular && !dynamicTypeSize.isAccessibilitySize
    }

    var body: some View {
        NavigationStack {
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
        }
        .sheet(item: $addItemRoute) { route in
            AddItemFlow(startWithScanner: route.startsWithScanner)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        .fileExporter(isPresented: $showingExporter, document: exportDocument,
                      contentType: .json, defaultFilename: "domowa-biblioteka.json") { result in
            switch result {
            case .success:
                message = ExportMessage(title: "Eksport gotowy", details: "Plik JSON można wczytać na stronie WWW.")
            case .failure(let error):
                message = ExportMessage(title: "Nie udało się wyeksportować", details: error.localizedDescription)
            }
        }
        .fileImporter(isPresented: $showingImporter, allowedContentTypes: [.json], allowsMultipleSelection: false) { result in
            handleImportResult(result)
        }
        .alert(item: $message) { value in
            Alert(title: Text(value.title), message: Text(value.details), dismissButton: .default(Text("OK")))
        }
        .task {
            if collectionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                collectionID = UUID().uuidString
            }
        }
        .libraryLightAppearance()
    }

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
                Button(action: prepareExport) {
                    Label("Eksportuj JSON", systemImage: "square.and.arrow.up")
                }
                .disabled(items.isEmpty)
                Button { showingImporter = true } label: {
                    Label(isImporting ? "Importowanie…" : "Importuj JSON",
                          systemImage: isImporting ? "hourglass" : "square.and.arrow.down")
                }
                .disabled(isImporting)
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
                        showingImporter = true
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
                                subtitle: "Domowy katalog książek i prasy — razem z miejscem, w którym stoi każdy egzemplarz.")
                EditorialMetricStrip(metrics: collectionMetrics)
                EditorialPrimaryButton(title: "Skanuj publikację", icon: "barcode.viewfinder") {
                    presentAddFlow(scanner: true)
                }
                .frame(maxWidth: 420, alignment: .leading)
                EditorialSearchField(text: $searchText)
                if filteredItems.isEmpty {
                    noSearchResults
                } else {
                    EditorialSectionHeader(title: searchText.nilIfBlank == nil ? "Publikacje" : "Wyniki wyszukiwania",
                                           value: paddedCount(filteredItems.count))
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
        if shouldUseGrid {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 330, maximum: 470), spacing: LibrarySpacing.large)],
                      alignment: .leading, spacing: 0) { publicationRows }
                .overlay(alignment: .bottom) { Rectangle().fill(LibraryPalette.rule).frame(height: 1) }
        } else {
            LazyVStack(spacing: 0) { publicationRows }
                .overlay(alignment: .bottom) { Rectangle().fill(LibraryPalette.rule).frame(height: 1) }
        }
    }

    @ViewBuilder private var publicationRows: some View {
        ForEach(Array(filteredItems.enumerated()), id: \.element.id) { index, item in
            PublicationRow(index: index + 1, item: item) { deleteItem(item) }
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

    private func presentAddFlow(scanner: Bool) { addItemRoute = scanner ? .scanner : .manual }

    private func deleteItem(_ item: OwnedItem) {
        modelContext.delete(item)
        try? modelContext.save()
    }

    private func prepareExport() {
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
            message = ExportMessage(title: "Nie udało się przygotować eksportu", details: error.localizedDescription)
        }
    }

    private func handleImportResult(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let error):
            guard !isFilePickerCancellation(error) else { return }
            message = ExportMessage(title: "Nie udało się zaimportować", details: error.localizedDescription)
        case .success(let urls):
            guard let url = urls.first else {
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
                    if shouldAdoptMetadata {
                        collectionID = report.collectionID
                        collectionName = report.collectionName
                    }
                    message = ExportMessage(title: "Import zakończony", details: report.summary)
                } catch is CancellationError {
                    // Anulowanie nie wymaga komunikatu.
                } catch {
                    message = ExportMessage(title: "Nie udało się zaimportować", details: error.localizedDescription)
                }
            }
        }
    }

    private func paddedCount(_ count: Int) -> String { String(format: "%02d", count) }
}

private struct EditorialSearchField: View {
    @Binding var text: String

    var body: some View {
        HStack(spacing: LibrarySpacing.small) {
            Image(systemName: "magnifyingglass")
                .font(.body.weight(.semibold))
                .foregroundStyle(LibraryPalette.orangeText)
                .accessibilityHidden(true)

            TextField("Tytuł, autor, kod lub lokalizacja", text: $text)
                .font(.body)
                .foregroundStyle(LibraryPalette.ink)
                .submitLabel(.search)
                .autocorrectionDisabled()
                .accessibilityLabel("Szukaj w kolekcji")

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
                .stroke(LibraryPalette.rule, lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: LibraryRadius.small))
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
    let deleteAction: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: LibrarySpacing.xSmall) {
            NavigationLink { ItemDetailView(item: item) } label: {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Text(String(format: "%02d", index)).font(.caption.monospacedDigit().weight(.bold))
                        Rectangle().fill(LibraryPalette.orange).frame(width: 20, height: 2).accessibilityHidden(true)
                        Text(publicationTypeLabel.uppercased()).font(.caption2.weight(.bold)).tracking(1.3)
                    }
                    .foregroundStyle(LibraryPalette.orangeText)
                    Text(item.publication?.title.nilIfBlank ?? "Publikacja bez tytułu")
                        .font(.system(.title3, design: .serif, weight: .bold))
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                    if let detail = publicationDetail {
                        Text(detail).font(.subheadline).foregroundStyle(LibraryPalette.mutedInk)
                            .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    }
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Image(systemName: "mappin").font(.caption.weight(.bold))
                            .foregroundStyle(LibraryPalette.orangeText).accessibilityHidden(true)
                        Text(item.locationDisplayName).font(.caption).foregroundStyle(LibraryPalette.mutedInk)
                            .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    }
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
                Button(role: .destructive, action: deleteAction) {
                    Label("Usuń z kolekcji", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis").font(.body.weight(.bold)).foregroundStyle(LibraryPalette.ink)
                    .frame(width: 44, height: 44).contentShape(Rectangle())
            }
            .accessibilityLabel("Opcje publikacji \(item.publication?.title.nilIfBlank ?? "bez tytułu")")
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
