import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \OwnedItem.addedAt, order: .reverse) private var items: [OwnedItem]

    @AppStorage("collectionID") private var collectionID = ""
    @AppStorage("collectionName") private var collectionName = "Moja biblioteka"

    @State private var searchText = ""
    @State private var showingAddFlow = false
    @State private var addFlowStartsWithScanner = false
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
            return [
                publication?.title,
                publication?.subtitle,
                publication?.authorsText,
                publication?.isbn13,
                publication?.issn,
                publication?.ean,
                item.locationPathText,
                item.notes
            ]
            .compactMap { $0 }
            .contains { $0.localizedCaseInsensitiveContains(query) }
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if items.isEmpty {
                    ContentUnavailableView {
                        Label("Kolekcja jest pusta", systemImage: "books.vertical")
                    } description: {
                        Text("Zeskanuj kod albo dodaj pierwszą publikację ręcznie.")
                    } actions: {
                        Button("Skanuj kod") {
                            presentAddFlow(scanner: true)
                        }
                        .buttonStyle(.borderedProminent)

                        Button("Dodaj ręcznie") {
                            presentAddFlow(scanner: false)
                        }
                        .buttonStyle(.bordered)
                    }
                } else if filteredItems.isEmpty {
                    ContentUnavailableView.search(text: searchText)
                } else {
                    collectionList
                }
            }
            .navigationTitle(collectionName)
            .searchable(text: $searchText, prompt: "Tytuł, autor, kod lub lokalizacja")
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        presentAddFlow(scanner: true)
                    } label: {
                        Label("Skanuj", systemImage: "barcode.viewfinder")
                    }

                    Menu {
                        Button {
                            presentAddFlow(scanner: false)
                        } label: {
                            Label("Dodaj ręcznie", systemImage: "square.and.pencil")
                        }

                        Button(action: prepareExport) {
                            Label("Eksportuj JSON", systemImage: "square.and.arrow.up")
                        }
                        .disabled(items.isEmpty)

                        Button {
                            showingImporter = true
                        } label: {
                            Label(
                                isImporting ? "Importowanie…" : "Importuj JSON",
                                systemImage: isImporting ? "hourglass" : "square.and.arrow.down"
                            )
                        }
                        .disabled(isImporting)
                    } label: {
                        Label("Więcej", systemImage: "ellipsis.circle")
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                if !items.isEmpty {
                    Text("\(items.count) \(itemCountLabel(items.count))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity)
                        .background(.bar)
                }
            }
        }
        .sheet(isPresented: $showingAddFlow) {
            AddItemFlow(startWithScanner: addFlowStartsWithScanner)
        }
        .fileExporter(
            isPresented: $showingExporter,
            document: exportDocument,
            contentType: .json,
            defaultFilename: "domowa-biblioteka.json"
        ) { result in
            switch result {
            case .success:
                message = ExportMessage(title: "Eksport gotowy", details: "Plik JSON można wczytać na stronie WWW.")
            case .failure(let error):
                message = ExportMessage(title: "Nie udało się wyeksportować", details: error.localizedDescription)
            }
        }
        .fileImporter(
            isPresented: $showingImporter,
            allowedContentTypes: [.json],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .failure(let error):
                guard !isFilePickerCancellation(error) else { return }
                message = ExportMessage(
                    title: "Nie udało się zaimportować",
                    details: error.localizedDescription
                )
            case .success(let urls):
                guard let url = urls.first else {
                    message = ExportMessage(
                        title: "Nie udało się zaimportować",
                        details: CocoaError(.fileNoSuchFile).localizedDescription
                    )
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

                        let shouldAdoptCollectionMetadata = items.isEmpty
                        let report = try CollectionImporter.apply(prepared, into: modelContext)
                        if shouldAdoptCollectionMetadata {
                            collectionID = report.collectionID
                            collectionName = report.collectionName
                        }
                        message = ExportMessage(title: "Import zakończony", details: report.summary)
                    } catch is CancellationError {
                        // Anulowanie nie jest błędem, który wymaga komunikatu dla użytkownika.
                    } catch {
                        message = ExportMessage(
                            title: "Nie udało się zaimportować",
                            details: error.localizedDescription
                        )
                    }
                }
            }
        }
        .alert(item: $message) { message in
            Alert(title: Text(message.title), message: Text(message.details), dismissButton: .default(Text("OK")))
        }
        .task {
            if collectionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                collectionID = UUID().uuidString
            }
        }
    }

    private var collectionList: some View {
        List {
            ForEach(filteredItems) { item in
                NavigationLink {
                    ItemDetailView(item: item)
                } label: {
                    ItemRow(item: item)
                }
            }
            .onDelete(perform: deleteItems)
        }
        .listStyle(.plain)
    }

    private func presentAddFlow(scanner: Bool) {
        addFlowStartsWithScanner = scanner
        showingAddFlow = true
    }

    private func deleteItems(at offsets: IndexSet) {
        for offset in offsets {
            let item = filteredItems[offset]
            modelContext.delete(item)
        }
        try? modelContext.save()
    }

    private func prepareExport() {
        do {
            let stableCollectionID: String
            let trimmedCollectionID = collectionID.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedCollectionID.isEmpty {
                stableCollectionID = trimmedCollectionID
            } else {
                stableCollectionID = UUID().uuidString
                collectionID = stableCollectionID
            }
            let payload = CollectionExporter.makeExport(
                items: items,
                collectionID: stableCollectionID,
                collectionName: collectionName
            )
            exportDocument = CollectionJSONDocument(data: try CollectionExporter.encode(payload))
            showingExporter = true
        } catch {
            message = ExportMessage(title: "Nie udało się przygotować eksportu", details: error.localizedDescription)
        }
    }

    private func itemCountLabel(_ count: Int) -> String {
        if count == 1 { return "egzemplarz" }
        let modulo100 = count % 100
        let modulo10 = count % 10
        if modulo100 < 12 || modulo100 > 14, (2...4).contains(modulo10) {
            return "egzemplarze"
        }
        return "egzemplarzy"
    }
}

private func isFilePickerCancellation(_ error: Error) -> Bool {
    if error is CancellationError {
        return true
    }
    let cocoaError = error as NSError
    return cocoaError.domain == NSCocoaErrorDomain
        && cocoaError.code == CocoaError.Code.userCancelled.rawValue
}

private struct ItemRow: View {
    let item: OwnedItem

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: item.publication?.publicationType.symbolName ?? "questionmark.square")
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 34, height: 46)
                .background(.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 4) {
                Text(item.publication?.title ?? "Publikacja bez tytułu")
                    .font(.headline)
                    .lineLimit(2)

                if let detail = publicationDetail {
                    Text(detail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Label(item.locationDisplayName, systemImage: "mappin.and.ellipse")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 4)
    }

    private var publicationDetail: String? {
        guard let publication = item.publication else { return nil }
        if publication.publicationType == .periodical {
            let issue = publication.issueNumber.isEmpty ? nil : "nr \(publication.issueNumber)"
            return [issue, publication.issueDate.nilIfBlank].compactMap { $0 }.joined(separator: " · ").nilIfBlank
        }
        return publication.authorsText.nilIfBlank
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
