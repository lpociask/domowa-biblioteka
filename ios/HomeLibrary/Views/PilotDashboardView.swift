import SwiftUI
import UniformTypeIdentifiers

@MainActor
struct PilotDashboardSnapshot: Equatable {
    let status: PilotMetricsStatus
    let report: PilotReport
    let jsonData: Data?
    let csvData: Data?

    static let loading = PilotDashboardSnapshot(
        status: PilotMetricsStatus(
            enabled: false,
            retainedEventCount: 0,
            lastSequence: nil,
            hasQuarantinedFile: false
        ),
        report: PilotReportBuilder.build(from: []),
        jsonData: nil,
        csvData: nil
    )
}

@MainActor
enum PilotDashboardPresenter {
    static let minimumPilotItems = 100
    static let targetPilotItems = 200

    static func completedItems(in report: PilotReport) -> Int {
        let saves = report.catalog.reduce(0) { $0 + $1.completed }
        let revertedAdds = report.mutations
            .first { $0.action == .undoAdd }?
            .completed ?? 0
        return max(0, saves - revertedAdds)
    }

    static func progressValue(in report: PilotReport) -> Double {
        min(
            1,
            Double(completedItems(in: report)) / Double(targetPilotItems)
        )
    }

    static func progressSummary(in report: PilotReport) -> String {
        let completed = completedItems(in: report)
        if completed >= targetPilotItems {
            return "Cel pilota osiągnięty · \(completed) obiektów"
        }
        if completed >= minimumPilotItems {
            return "Minimum osiągnięte · \(completed) z \(targetPilotItems) obiektów"
        }
        return "\(completed) z \(minimumPilotItems) do pierwszego podsumowania"
    }

    static func duration(_ milliseconds: Double?) -> String {
        guard let milliseconds, milliseconds.isFinite else { return "—" }
        let seconds = milliseconds / 1_000
        if seconds < 10 {
            return String(format: "%.1f s", locale: Locale(identifier: "pl_PL"), seconds)
        }
        if seconds < 60 {
            return "\(Int(seconds.rounded())) s"
        }
        let minutes = Int(seconds) / 60
        let remainder = Int(seconds.rounded()) % 60
        return "\(minutes) min \(remainder) s"
    }

    static func percent(_ rate: PilotRate) -> String {
        guard let value = rate.value, value.isFinite else { return "—" }
        return NumberFormatter.pilotPercent.string(from: NSNumber(value: value)) ?? "—"
    }

    static func lookupLabel(_ source: PilotLookupSource) -> String {
        switch source {
        case .nationalLibrary: "BN"
        case .openLibrary: "Open Library"
        case .libraryOfCongress: "Library of Congress"
        case .issnPortal: "ISSN Portal"
        case .metadataCache: "Cache"
        }
    }

    static func transferLabel(_ direction: PilotTransferDirection) -> String {
        switch direction {
        case .export: "Eksport"
        case .import: "Import"
        case .roundTrip: "Odtworzenie"
        }
    }

    static func transferRate(_ report: PilotTransferDirectionReport) -> PilotRate {
        switch report.direction {
        case .export, .import:
            PilotRate(
                numerator: report.completed,
                denominator: report.completed + report.failed + report.cancelled
            )
        case .roundTrip:
            report.verificationRate
        }
    }

    static func transferDetail(_ report: PilotTransferDirectionReport) -> String {
        switch report.direction {
        case .export, .import:
            "Ukończone: \(report.completed) · błędy: \(report.failed) · anulowane: \(report.cancelled)"
        case .roundTrip:
            "\(report.verified) potwierdzonych · \(report.mismatch) rozbieżności"
        }
    }

    static func kindLabel(_ kind: PilotPublicationKind) -> String {
        switch kind {
        case .book: "Książka"
        case .periodical: "Prasa"
        }
    }
}

/// Local, aggregate-only dashboard for the 100–200 item collection pilot.
/// It never requests or exposes raw pilot records.
struct PilotDashboardView: View {
    private let store: PilotMetricsStore
    private let onVerifyRoundTrip: (() -> Void)?

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var snapshot = PilotDashboardSnapshot.loading
    @State private var isLoading = true
    @State private var isUpdatingPreference = false
    @State private var showsResetConfirmation = false
    @State private var errorMessage: String?

    init(
        store: PilotMetricsStore = PilotMetricsStore(),
        onVerifyRoundTrip: (() -> Void)? = nil
    ) {
        self.store = store
        self.onVerifyRoundTrip = onVerifyRoundTrip
    }

    var body: some View {
        ZStack {
            PaperBackground()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: LibrarySpacing.large) {
                    LibraryMasthead(
                        title: "Pilot kolekcji",
                        eyebrow: dynamicTypeSize.isAccessibilitySize
                            ? "PILOT 100–200"
                            : "POMIAR 100–200 OBIEKTÓW",
                        subtitle: "Sprawdźmy szybkość katalogowania, jakość metadanych i pewność odtworzenia bazy na prawdziwej półce.",
                        compact: horizontalSizeClass == .compact || dynamicTypeSize.isAccessibilitySize,
                        constrainAccessibilityHeight: true
                    )

                    privacySection

                    if isLoading {
                        loadingSection
                    } else {
                        progressSection
                        catalogSection
                        qualitySection
                        workflowSection
                        exportSection
                        controlsSection
                    }
                }
                .editorialPage(width: 980)
                .padding(.top, LibrarySpacing.small)
                .padding(.bottom, LibrarySpacing.xLarge)
            }
            .scrollIndicators(.hidden)
        }
        .foregroundStyle(LibraryPalette.ink)
        .navigationTitle("Pilot kolekcji")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(LibraryPalette.paper, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarColorScheme(.light, for: .navigationBar)
        .libraryLightAppearance()
        .task { await refresh() }
        .refreshable { await refresh() }
        .confirmationDialog(
            "Usunąć wszystkie pomiary pilota?",
            isPresented: $showsResetConfirmation,
            titleVisibility: .visible
        ) {
            Button("Usuń pomiary", role: .destructive) {
                Task { await resetMetrics() }
            }
            Button("Anuluj", role: .cancel) {}
        } message: {
            Text("Tej operacji nie można cofnąć. Ustawienie udziału w pilocie pozostanie bez zmian.")
        }
        .alert(
            "Nie udało się wykonać operacji",
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "Spróbuj ponownie.")
        }
    }

    private var privacySection: some View {
        VStack(alignment: .leading, spacing: LibrarySpacing.medium) {
            if dynamicTypeSize.isAccessibilitySize {
                Text(snapshot.status.enabled ? "POMIAR WŁĄCZONY" : "POMIAR WYŁĄCZONY")
                    .font(.headline.weight(.bold))
                    .tracking(0.5)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Lokalnie zapisujemy tylko zamknięte wyniki działań i czasy; udostępniany raport zawiera wyłącznie agregaty. Bez tytułów, ISBN, lokalizacji, notatek, zdjęć i identyfikatorów.")
                    .font(.system(.body, design: .serif))
                    .foregroundStyle(LibraryPalette.mutedInk)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                EditorialStatusBand(
                    title: snapshot.status.enabled ? "Pomiar jest włączony" : "Pomiar jest wyłączony",
                    message: "Lokalnie zapisujemy tylko zamknięte wyniki działań i czasy; udostępniany raport zawiera wyłącznie agregaty. Bez tytułów, ISBN, lokalizacji, notatek, zdjęć i identyfikatorów egzemplarzy.",
                    icon: snapshot.status.enabled ? "checkmark.shield" : "lock.shield",
                    accent: snapshot.status.enabled ? LibraryPalette.orangeText : LibraryPalette.mutedInk
                )
            }

            Toggle(
                isOn: Binding(
                    get: { snapshot.status.enabled },
                    set: { value in Task { await setEnabled(value) } }
                )
            ) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Biorę udział w pilocie")
                        .font(.system(.title3, design: .serif, weight: .bold))
                    Text("Wyłączenie zatrzymuje nowe pomiary, ale zachowuje dotychczasowe wyniki.")
                        .font(.footnote)
                        .foregroundStyle(LibraryPalette.mutedInk)
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            .tint(LibraryPalette.orangeAction)
            .disabled(isLoading || isUpdatingPreference)
            .frame(minHeight: 56)
            .accessibilityIdentifier("pilot.optIn")
            .accessibilityValue(snapshot.status.enabled ? "Włączony" : "Wyłączony")

            if snapshot.status.hasQuarantinedFile {
                EditorialStatusBand(
                    title: "Odzyskano bezpieczny stan",
                    message: "Uszkodzony lokalny plik pomiarów został odizolowany. Nowe pomiary można zbierać normalnie.",
                    icon: "exclamationmark.triangle",
                    accent: LibraryPalette.orangeText
                )
            }
        }
    }

    private var loadingSection: some View {
        HStack(spacing: LibrarySpacing.small) {
            ProgressView()
                .tint(LibraryPalette.orangeText)
                .accessibilityHidden(true)
            Text("Wczytywanie podsumowania pilota…")
                .font(.system(.body, design: .serif))
        }
        .frame(maxWidth: .infinity, minHeight: 96, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Wczytywanie podsumowania pilota")
    }

    private var progressSection: some View {
        let completed = PilotDashboardPresenter.completedItems(in: snapshot.report)
        return VStack(alignment: .leading, spacing: LibrarySpacing.medium) {
            EditorialSectionHeader(
                title: "Postęp prawdziwej kolekcji",
                value: "\(completed) / 200"
            )

            Text(PilotDashboardPresenter.progressSummary(in: snapshot.report))
                .font(.system(.title2, design: .serif, weight: .bold))
                .fixedSize(horizontal: false, vertical: true)

            ProgressView(value: PilotDashboardPresenter.progressValue(in: snapshot.report))
                .tint(LibraryPalette.orangeAction)
                .scaleEffect(x: 1, y: 2, anchor: .center)
                .accessibilityLabel("Postęp pilota")
                .accessibilityValue("\(completed) z docelowych 200 obiektów")

            EditorialMetricStrip(metrics: [
                EditorialMetric(value: String(completed), label: "Zapisane obiekty"),
                EditorialMetric(value: String(snapshot.report.retainedEventCount), label: "Pomiary"),
                EditorialMetric(value: pilotDayCount, label: "Dni pomiaru")
            ])
        }
        .accessibilityIdentifier("pilot.progress")
    }

    private var catalogSection: some View {
        VStack(alignment: .leading, spacing: LibrarySpacing.medium) {
            EditorialSectionHeader(title: "Czas katalogowania", value: "MEDIANA · P90")
            Text("Mediana pokazuje typowy czas, a P90 wolniejsze 10% zapisów. Liczymy tylko zakończone dodawanie.")
                .font(.system(.footnote, design: .serif))
                .lineSpacing(3)
                .foregroundStyle(LibraryPalette.mutedInk)
                .fixedSize(horizontal: false, vertical: true)

            adaptiveGrid {
                ForEach(snapshot.report.catalog, id: \.publicationKind) { item in
                    PilotMetricCard(
                        kicker: PilotDashboardPresenter.kindLabel(item.publicationKind),
                        title: PilotDashboardPresenter.duration(item.activeMilliseconds.median),
                        detail: "P90 · \(PilotDashboardPresenter.duration(item.activeMilliseconds.p90))",
                        sample: "\(item.completed) ukończonych"
                    )
                }
            }
        }
        .accessibilityIdentifier("pilot.catalogKPI")
    }

    private var qualitySection: some View {
        VStack(alignment: .leading, spacing: LibrarySpacing.medium) {
            EditorialSectionHeader(title: "Metadane i poprawki", value: "JAKOŚĆ")

            adaptiveGrid {
                PilotMetricCard(
                    kicker: "Ręczne poprawki",
                    title: PilotDashboardPresenter.percent(snapshot.report.corrections.correctedItemRate),
                    detail: "\(snapshot.report.corrections.manualCorrections) zmian w polach",
                    sample: "\(snapshot.report.corrections.completedItems) zapisów"
                )

                ForEach(snapshot.report.lookups, id: \.source) { item in
                    PilotMetricCard(
                        kicker: PilotDashboardPresenter.lookupLabel(item.source),
                        title: PilotDashboardPresenter.percent(
                            item.source == .metadataCache ? item.usableCacheRate : item.foundRate
                        ),
                        detail: "\(item.found) znalezionych · \(item.notFound) braków",
                        sample: "\(item.attempts) prób"
                    )
                }
            }
        }
        .accessibilityIdentifier("pilot.metadataKPI")
    }

    private var workflowSection: some View {
        VStack(alignment: .leading, spacing: LibrarySpacing.medium) {
            EditorialSectionHeader(title: "Wygoda pracy", value: "PRZEPŁYW")

            adaptiveGrid {
                PilotMetricCard(
                    kicker: "Lokalizacja",
                    title: PilotDashboardPresenter.percent(snapshot.report.location.reuseRate),
                    detail: "Ponowne użycie bieżącej półki",
                    sample: "\(snapshot.report.location.measurements) pomiarów"
                )
                PilotMetricCard(
                    kicker: "OCR prasy",
                    title: PilotDashboardPresenter.percent(snapshot.report.ocr.appliedRate),
                    detail: "Zastosowane sugestie numeru lub daty",
                    sample: "\(snapshot.report.ocr.attempts) prób"
                )
                PilotMetricCard(
                    kicker: "Wyszukiwanie",
                    title: PilotDashboardPresenter.percent(snapshot.report.search.successfulOpenRate),
                    detail: "Sesje zakończone otwarciem wyniku",
                    sample: "\(snapshot.report.search.sessions) sesji"
                )

                ForEach(snapshot.report.transfers, id: \.direction) { item in
                    PilotMetricCard(
                        kicker: PilotDashboardPresenter.transferLabel(item.direction),
                        title: PilotDashboardPresenter.percent(
                            PilotDashboardPresenter.transferRate(item)
                        ),
                        detail: PilotDashboardPresenter.transferDetail(item),
                        sample: "\(item.attempts) prób"
                    )
                }
            }
        }
        .accessibilityIdentifier("pilot.workflowKPI")
    }

    private var exportSection: some View {
        VStack(alignment: .leading, spacing: LibrarySpacing.medium) {
            EditorialSectionHeader(title: "Eksport raportu", value: "BEZ RAW EVENTS")
            Text("Pliki zawierają wyłącznie podsumowanie pomiarów: liczniki, rozkłady czasów i wskaźniki. To nie jest eksport kolekcji i tych plików nie importuje się na stronie WWW.")
                .font(.system(.footnote, design: .serif))
                .lineSpacing(3)
                .foregroundStyle(LibraryPalette.mutedInk)
                .fixedSize(horizontal: false, vertical: true)

            Group {
                if let jsonData = snapshot.jsonData,
                   let csvData = snapshot.csvData {
                    if dynamicTypeSize.isAccessibilitySize {
                        VStack(spacing: LibrarySpacing.small) {
                            shareButton(data: jsonData, format: .json)
                            shareButton(data: csvData, format: .csv)
                        }
                    } else {
                        HStack(spacing: LibrarySpacing.small) {
                            shareButton(data: jsonData, format: .json)
                            shareButton(data: csvData, format: .csv)
                        }
                    }
                } else {
                    Text("Raport nie jest jeszcze gotowy do udostępnienia.")
                        .font(.footnote)
                        .foregroundStyle(LibraryPalette.mutedInk)
                }
            }
        }
        .accessibilityIdentifier("pilot.aggregateExport")
    }

    private var controlsSection: some View {
        VStack(alignment: .leading, spacing: LibrarySpacing.small) {
            EditorialSectionHeader(title: "Kontrola danych", value: String(snapshot.status.retainedEventCount))

            if let onVerifyRoundTrip {
                EditorialPrimaryButton(
                    title: "Sprawdź plik po WWW",
                    icon: "checkmark.shield"
                ) {
                    onVerifyRoundTrip()
                }
                .accessibilityIdentifier("pilot.verifyRoundTrip")
                Text("Wybierz JSON pobrany po użyciu kolekcji na WWW. Porównanie odbywa się tylko w pamięci i nie zmienia bazy na iPhonie.")
                    .font(.system(.footnote, design: .serif))
                    .lineSpacing(3)
                    .foregroundStyle(LibraryPalette.mutedInk)
                    .fixedSize(horizontal: false, vertical: true)
            }

            EditorialSecondaryButton(
                title: "Odśwież podsumowanie",
                icon: "arrow.clockwise"
            ) {
                Task { await refresh() }
            }
            .accessibilityIdentifier("pilot.refresh")

            Button(role: .destructive) {
                showsResetConfirmation = true
            } label: {
                HStack(spacing: LibrarySpacing.small) {
                    Text("USUŃ POMIARY PILOTA")
                        .font(.subheadline.weight(.bold))
                        .tracking(1.2)
                    Spacer(minLength: LibrarySpacing.small)
                    Image(systemName: "trash")
                        .accessibilityHidden(true)
                }
                .foregroundStyle(LibraryPalette.orangeAction)
                .padding(.horizontal, LibrarySpacing.medium)
                .frame(maxWidth: .infinity, minHeight: 56)
                .overlay {
                    RoundedRectangle(cornerRadius: LibraryRadius.small)
                        .stroke(LibraryPalette.orangeAction, lineWidth: 1)
                }
                .contentShape(RoundedRectangle(cornerRadius: LibraryRadius.small))
            }
            .buttonStyle(.plain)
            .disabled(snapshot.status.retainedEventCount == 0)
            .accessibilityIdentifier("pilot.reset")
            .accessibilityHint("Wymaga potwierdzenia")
        }
    }

    private var pilotDayCount: String {
        guard let first = snapshot.report.firstDayIndex,
              let last = snapshot.report.lastDayIndex else {
            return "0"
        }
        return String(last - first + 1)
    }

    @ViewBuilder
    private func adaptiveGrid<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        if dynamicTypeSize.isAccessibilitySize || horizontalSizeClass == .compact {
            LazyVStack(alignment: .leading, spacing: LibrarySpacing.small, content: content)
        } else {
            LazyVGrid(
                columns: [
                    GridItem(.flexible(), spacing: LibrarySpacing.medium),
                    GridItem(.flexible(), spacing: LibrarySpacing.medium)
                ],
                alignment: .leading,
                spacing: LibrarySpacing.medium,
                content: content
            )
        }
    }

    @ViewBuilder
    private func shareButton(data: Data, format: PilotDashboardExportFormat) -> some View {
        switch format {
        case .json:
            ShareLink(
                item: PilotDashboardJSONExport(data: data),
                preview: SharePreview(format.shareTitle, image: Image(systemName: format.icon))
            ) {
                shareButtonLabel(format)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("pilot.export.json")
        case .csv:
            ShareLink(
                item: PilotDashboardCSVExport(data: data),
                preview: SharePreview(format.shareTitle, image: Image(systemName: format.icon))
            ) {
                shareButtonLabel(format)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("pilot.export.csv")
        }
    }

    private func shareButtonLabel(_ format: PilotDashboardExportFormat) -> some View {
        HStack(spacing: LibrarySpacing.small) {
            Text(format.buttonTitle.uppercased())
                .font(.subheadline.weight(.bold))
                .tracking(1.1)
            Spacer(minLength: LibrarySpacing.small)
            Image(systemName: "square.and.arrow.up")
                .accessibilityHidden(true)
        }
        .foregroundStyle(LibraryPalette.ink)
        .padding(.horizontal, LibrarySpacing.medium)
        .frame(maxWidth: .infinity, minHeight: 56)
        .overlay {
            RoundedRectangle(cornerRadius: LibraryRadius.small)
                .stroke(LibraryPalette.ink, lineWidth: 1)
        }
    }

    private func refresh() async {
        isLoading = true
        do {
            let data = try await store.dashboardData()
            snapshot = PilotDashboardSnapshot(
                status: data.status,
                report: data.report,
                jsonData: data.jsonData,
                csvData: data.csvData
            )
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    private func setEnabled(_ enabled: Bool) async {
        guard !isUpdatingPreference else { return }
        isUpdatingPreference = true
        do {
            _ = try await store.setEnabled(enabled)
            await refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
        isUpdatingPreference = false
    }

    private func resetMetrics() async {
        do {
            try await store.reset()
            await refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct PilotMetricCard: View {
    let kicker: String
    let title: String
    let detail: String
    let sample: String

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(alignment: .leading, spacing: LibrarySpacing.xSmall) {
            Text(kicker.uppercased())
                .font(.caption2.weight(.bold))
                .tracking(1.45)
                .foregroundStyle(LibraryPalette.orangeText)

            Text(title)
                .font(.system(.title, design: .serif, weight: .bold))
                .fontWidth(.condensed)
                .monospacedDigit()
                .minimumScaleFactor(dynamicTypeSize.isAccessibilitySize ? 1 : 0.72)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
                .fixedSize(horizontal: false, vertical: dynamicTypeSize.isAccessibilitySize)

            Text(detail)
                .font(.system(.footnote, design: .serif))
                .lineSpacing(2)
                .foregroundStyle(LibraryPalette.ink)
                .fixedSize(horizontal: false, vertical: true)

            Text(sample.uppercased())
                .font(.caption2.monospacedDigit().weight(.semibold))
                .tracking(0.7)
                .foregroundStyle(LibraryPalette.mutedInk)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(LibrarySpacing.medium)
        .frame(maxWidth: .infinity, minHeight: 150, alignment: .topLeading)
        .background(LibraryPalette.ink.opacity(0.035))
        .overlay(alignment: .top) {
            Rectangle().fill(LibraryPalette.ink).frame(height: 1)
        }
        .overlay(alignment: .leading) {
            Rectangle().fill(LibraryPalette.orange).frame(width: 3)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(kicker), \(title), \(detail), \(sample)")
    }
}

enum PilotDashboardExportFormat: String, Sendable {
    case json
    case csv

    var contentType: UTType {
        switch self {
        case .json: .json
        case .csv: .commaSeparatedText
        }
    }

    var fileExtension: String { rawValue }
    var fileName: String { "raport-pilota-kpi.\(fileExtension)" }
    var shareTitle: String { "Raport pilota \(rawValue.uppercased())" }
    var buttonTitle: String { "Udostępnij raport \(rawValue.uppercased())" }
    var icon: String { self == .json ? "curlybraces" : "tablecells" }
}

struct PilotDashboardJSONExport: Transferable, Sendable, Equatable {
    let data: Data

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .json) { item in
            SentTransferredFile(
                try PilotDashboardTemporaryExport.write(
                    item.data,
                    fileName: PilotDashboardExportFormat.json.fileName
                )
            )
        }
    }
}

struct PilotDashboardCSVExport: Transferable, Sendable, Equatable {
    let data: Data

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .commaSeparatedText) { item in
            SentTransferredFile(
                try PilotDashboardTemporaryExport.write(
                    item.data,
                    fileName: PilotDashboardExportFormat.csv.fileName
                )
            )
        }
    }
}

private enum PilotDashboardTemporaryExport {
    static func write(_ data: Data, fileName: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HomeLibrary-Pilot-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let file = directory.appendingPathComponent(fileName, isDirectory: false)
        try data.write(to: file, options: [.atomic, .completeFileProtection])
        return file
    }
}

private extension NumberFormatter {
    static let pilotPercent: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "pl_PL")
        formatter.numberStyle = .percent
        formatter.maximumFractionDigits = 0
        formatter.minimumFractionDigits = 0
        return formatter
    }()
}
