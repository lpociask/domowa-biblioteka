import SwiftUI

struct PeriodicalOverviewView: View {
    fileprivate enum Filter: String, CaseIterable, Identifiable {
        case all
        case gaps
        case duplicates

        var id: Self { self }

        var label: String {
            switch self {
            case .all: "Wszystkie"
            case .gaps: "Luki"
            case .duplicates: "Duplikaty"
            }
        }
    }

    let items: [OwnedItem]

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var filter: Filter = .all

    private var analysis: PeriodicalCollectionAnalysis {
        PeriodicalIssueAnalyzer.analyze(items: items)
    }

    private var filteredSeries: [PeriodicalSeriesAnalysis] {
        switch filter {
        case .all:
            analysis.series
        case .gaps:
            analysis.series.filter(\.hasGapFindings)
        case .duplicates:
            analysis.series.filter(\.hasDuplicateFindings)
        }
    }

    private var itemByID: [UUID: OwnedItem] {
        Self.makeItemIndex(items: items)
    }

    /// Legacy imports may contain repeated copy UUIDs. Preserve the first item
    /// in the already deterministic collection order instead of trapping in
    /// `Dictionary(uniqueKeysWithValues:)`.
    static func makeItemIndex(items: [OwnedItem]) -> [UUID: OwnedItem] {
        var result: [UUID: OwnedItem] = [:]
        for item in items where result[item.id] == nil {
            result[item.id] = item
        }
        return result
    }

    private var issueCount: Int {
        analysis.series.reduce(0) { $0 + $1.issues.count }
    }

    private var missingCount: Int {
        analysis.series.reduce(0) { $0 + $1.missingIssues.count }
    }

    private var reviewFindingCount: Int {
        analysis.series.reduce(0) {
            $0 + $1.multipleCopyGroups.count
                + $1.duplicatePublicationGroups.count
                + $1.warnings.count
        }
    }

    private var filterCounts: [Filter: Int] {
        [
            .all: analysis.series.count,
            .gaps: analysis.series.count(where: \.hasGapFindings),
            .duplicates: analysis.series.count(where: \.hasDuplicateFindings)
        ]
    }

    var body: some View {
        ZStack {
            PaperBackground()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: LibrarySpacing.large) {
                    LibraryMasthead(
                        title: "Serie prasy",
                        eyebrow: "ANALIZA KOLEKCJI · \(padded(analysis.series.count)) SERII",
                        subtitle: "Numery są grupowane na podstawie ISSN, EAN albo zgodnego opisu. Ten widok niczego nie zmienia w zapisanej kolekcji.",
                        compact: horizontalSizeClass == .compact
                    )

                    EditorialMetricStrip(metrics: [
                        EditorialMetric(value: String(analysis.series.count), label: "Serie"),
                        EditorialMetric(value: String(issueCount), label: "Numery"),
                        EditorialMetric(value: String(missingCount), label: "Luki"),
                        EditorialMetric(value: String(reviewFindingCount), label: "Do sprawdzenia")
                    ])

                    PeriodicalOverviewFilter(
                        selection: $filter,
                        counts: filterCounts,
                        usesVerticalLayout: dynamicTypeSize.isAccessibilitySize
                    )

                    if filteredSeries.isEmpty {
                        emptyState
                    } else {
                        ForEach(Array(filteredSeries.enumerated()), id: \.element.id) { index, series in
                            PeriodicalSeriesSection(
                                index: index + 1,
                                series: series,
                                filter: filter,
                                itemByID: itemByID
                            )
                        }
                    }

                    if analysis.excludedArchivedCopyCount > 0 {
                        Text("POMINIĘTO ARCHIWALNE EGZEMPLARZE · \(analysis.excludedArchivedCopyCount)")
                            .font(.caption2.weight(.bold))
                            .tracking(1.4)
                            .foregroundStyle(LibraryPalette.mutedInk)
                            .padding(.top, LibrarySpacing.small)
                            .accessibilityLabel(
                                "Pominięto archiwalne egzemplarze: \(analysis.excludedArchivedCopyCount)"
                            )
                    }
                }
                .editorialPage(width: 980)
                .padding(.top, LibrarySpacing.small)
                .padding(.bottom, LibrarySpacing.xLarge)
            }
            .scrollIndicators(.hidden)
        }
        .foregroundStyle(LibraryPalette.ink)
        .navigationTitle("Serie prasy")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(LibraryPalette.paper, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarColorScheme(.light, for: .navigationBar)
        .libraryLightAppearance()
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: LibrarySpacing.medium) {
            EditorialSectionHeader(title: filter.emptyTitle, value: "00")

            Text(filter.emptyHeading)
                .font(.system(.title2, design: .serif, weight: .bold))
                .fixedSize(horizontal: false, vertical: true)

            Text(filter.emptyMessage)
                .font(.system(.body, design: .serif))
                .lineSpacing(3)
                .foregroundStyle(LibraryPalette.mutedInk)
                .fixedSize(horizontal: false, vertical: true)

            if filter != .all {
                EditorialSecondaryButton(title: "Pokaż wszystkie serie", icon: "line.3.horizontal.decrease") {
                    filter = .all
                }
                .frame(maxWidth: 420, alignment: .leading)
            }
        }
    }

    private func padded(_ value: Int) -> String {
        String(format: "%02d", value)
    }
}

private extension PeriodicalOverviewView.Filter {
    var emptyTitle: String {
        switch self {
        case .all: "Serie"
        case .gaps: "Luki pomiędzy zapisanymi numerami"
        case .duplicates: "Duplikaty"
        }
    }

    var emptyHeading: String {
        switch self {
        case .all: "Nie ma jeszcze aktywnych numerów prasy."
        case .gaps: "Nie znaleziono luk wewnątrz zapisanych zakresów."
        case .duplicates: "Nie znaleziono powtórzeń do sprawdzenia."
        }
    }

    var emptyMessage: String {
        switch self {
        case .all:
            "Dodaj numer czasopisma albo przywróć egzemplarz z archiwum, aby zobaczyć analizę serii."
        case .gaps:
            "Luką jest wyłącznie brak pomiędzy najniższym i najwyższym zapisanym numerem tego samego roku, tomu lub numeracji ciągłej."
        case .duplicates:
            "Wiele egzemplarzy jednego rekordu i powtórzone rekordy publikacji są liczone osobno."
        }
    }
}

private struct PeriodicalOverviewFilter: View {
    @Binding var selection: PeriodicalOverviewView.Filter
    let counts: [PeriodicalOverviewView.Filter: Int]
    let usesVerticalLayout: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: LibrarySpacing.xSmall) {
            Text("FILTR WIDOKU")
                .font(.caption2.weight(.bold))
                .tracking(1.5)
                .foregroundStyle(LibraryPalette.mutedInk)

            Group {
                if usesVerticalLayout {
                    VStack(spacing: 0) { filterButtons }
                } else {
                    HStack(spacing: 0) { filterButtons }
                }
            }
            .overlay(alignment: .top) {
                Rectangle().fill(LibraryPalette.ink).frame(height: 1)
            }
            .overlay(alignment: .bottom) {
                Rectangle().fill(LibraryPalette.ink).frame(height: 1)
            }
        }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var filterButtons: some View {
        ForEach(PeriodicalOverviewView.Filter.allCases) { option in
            Button {
                selection = option
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Text(option.label.uppercased())
                        .font(usesVerticalLayout ? .caption.weight(.bold) : .caption2.weight(.bold))
                        .tracking(usesVerticalLayout ? 1.1 : 0.75)
                        .lineLimit(usesVerticalLayout ? nil : 1)
                        .minimumScaleFactor(usesVerticalLayout ? 1 : 0.72)
                        .allowsTightening(!usesVerticalLayout)
                        .fixedSize(horizontal: false, vertical: usesVerticalLayout)
                    Text(String(counts[option, default: 0]))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(
                            selection == option ? LibraryPalette.ink : LibraryPalette.mutedInk
                        )
                    Spacer(minLength: 0)
                }
                .foregroundStyle(selection == option ? LibraryPalette.orangeText : LibraryPalette.ink)
                .padding(.horizontal, LibrarySpacing.small)
                .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                .contentShape(Rectangle())
                .overlay(alignment: .bottom) {
                    Rectangle()
                        .fill(selection == option ? LibraryPalette.orange : Color.clear)
                        .frame(height: 3)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(option.label)
            .accessibilityValue(
                "\(counts[option, default: 0]) serii\(selection == option ? ", wybrano" : "")"
            )
            .accessibilityAddTraits(selection == option ? .isSelected : [])
        }
    }
}

private struct PeriodicalSeriesSection: View {
    let index: Int
    let series: PeriodicalSeriesAnalysis
    let filter: PeriodicalOverviewView.Filter
    let itemByID: [UUID: OwnedItem]

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var displaysIssues: Bool { true }
    private var displaysGaps: Bool { filter != .duplicates && !series.missingIssues.isEmpty }
    private var displaysDuplicates: Bool { filter != .gaps }

    var body: some View {
        VStack(alignment: .leading, spacing: LibrarySpacing.medium) {
            seriesHeader

            if !series.warnings.isEmpty {
                VStack(spacing: 0) {
                    ForEach(series.warnings, id: \.id) { warning in
                        PeriodicalWarningRow(warning: warning)
                    }
                }
            }

            if displaysGaps {
                missingIssuesSection
            }

            if displaysDuplicates {
                if !series.multipleCopyGroups.isEmpty {
                    multipleCopiesSection
                }

                if !series.duplicatePublicationGroups.isEmpty {
                    duplicateRecordsSection
                }
            }

            if displaysIssues {
                savedIssuesSection
            }
        }
        .padding(.top, LibrarySpacing.small)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(LibraryPalette.ink)
                .frame(height: 2)
                .accessibilityHidden(true)
        }
    }

    private var seriesHeader: some View {
        VStack(alignment: .leading, spacing: LibrarySpacing.small) {
            HStack(alignment: .top, spacing: LibrarySpacing.small) {
                Text(String(format: "%02d", index))
                    .font(.caption.monospacedDigit().weight(.bold))
                    .foregroundStyle(LibraryPalette.orangeText)
                    .frame(minWidth: 32, minHeight: 44, alignment: .topLeading)

                VStack(alignment: .leading, spacing: 5) {
                    Text("SERIA")
                        .font(.caption2.weight(.bold))
                        .tracking(1.6)
                        .foregroundStyle(LibraryPalette.orangeText)

                    Text(series.title.nilIfBlank ?? "Seria bez tytułu")
                        .font(.system(.title2, design: .serif, weight: .bold))
                        .fontWidth(.condensed)
                        .fixedSize(horizontal: false, vertical: true)

                    if let metadataLine {
                        Text(metadataLine)
                            .font(.subheadline)
                            .foregroundStyle(LibraryPalette.mutedInk)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if !dynamicTypeSize.isAccessibilitySize {
                    VStack(alignment: .trailing, spacing: 3) {
                        Text(String(series.issues.count))
                            .font(.title3.monospacedDigit().weight(.bold))
                        Text("NUMERÓW")
                            .font(.caption2.weight(.bold))
                            .tracking(1.1)
                            .foregroundStyle(LibraryPalette.mutedInk)
                    }
                    .accessibilityHidden(true)
                }
            }

            HStack(alignment: .firstTextBaseline, spacing: LibrarySpacing.xSmall) {
                Text(identificationLabel)
                    .font(.caption2.weight(.bold))
                    .tracking(1.25)
                    .foregroundStyle(LibraryPalette.mutedInk)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if dynamicTypeSize.isAccessibilitySize {
                    Text("\(series.issues.count) numerów")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(LibraryPalette.mutedInk)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    private var metadataLine: String? {
        [series.publisher.nilIfBlank, series.language.nilIfBlank]
            .compactMap { $0 }
            .joined(separator: " · ")
            .nilIfBlank
    }

    private var identificationLabel: String {
        switch series.identification {
        case .issn(let value):
            "ISSN · \(value)"
        case .metadata:
            "GRUPOWANIE · TYTUŁ + WYDAWCA + JĘZYK"
        case .isolatedIdentifierConflict:
            "ODIZOLOWANY REKORD · KONFLIKT IDENTYFIKATORÓW"
        case .isolatedPublication:
            "ODIZOLOWANY REKORD · BRAK DANYCH SERII"
        }
    }

    private var missingIssuesSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            EditorialSectionHeader(
                title: "Luki pomiędzy zapisanymi numerami",
                value: String(series.missingIssues.count),
                accent: LibraryPalette.orange
            )

            Text("Nie zakładamy braków przed pierwszym ani po ostatnim zapisanym numerze w danym cyklu.")
                .font(.system(.footnote, design: .serif))
                .lineSpacing(3)
                .foregroundStyle(LibraryPalette.mutedInk)
                .padding(.vertical, LibrarySpacing.small)

            ForEach(missingGroups) { group in
                Group {
                    if dynamicTypeSize.isAccessibilitySize {
                        VStack(alignment: .leading, spacing: LibrarySpacing.xSmall) {
                            missingCycleLabel(group)
                            missingNumbersLabel(group)
                        }
                    } else {
                        HStack(alignment: .firstTextBaseline, spacing: LibrarySpacing.small) {
                            missingCycleLabel(group)
                                .frame(minWidth: 118, alignment: .leading)
                            missingNumbersLabel(group)
                            Spacer(minLength: 0)
                        }
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
                .padding(.vertical, dynamicTypeSize.isAccessibilitySize ? LibrarySpacing.small : 0)
                .overlay(alignment: .top) {
                    Rectangle().fill(LibraryPalette.rule).frame(height: 1)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(
                    "\(group.cycle.displayName), brakujące numery: \(group.numbers.map(String.init).joined(separator: ", "))"
                )
            }
        }
    }

    private func missingCycleLabel(_ group: MissingIssueGroup) -> some View {
        Text(group.cycle.displayName.uppercased())
            .font(.caption2.weight(.bold))
            .tracking(1.2)
            .foregroundStyle(LibraryPalette.orangeText)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func missingNumbersLabel(_ group: MissingIssueGroup) -> some View {
        Text(group.numbers.map(String.init).joined(separator: ", "))
            .font(.system(.body, design: .serif, weight: .semibold))
            .fixedSize(horizontal: false, vertical: true)
    }

    private var multipleCopiesSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            EditorialSectionHeader(
                title: "Wiele egzemplarzy jednego rekordu",
                value: String(series.multipleCopyGroups.count),
                accent: LibraryPalette.ink
            )

            Text("To osobne fizyczne egzemplarze przypisane do jednego opisu numeru.")
                .font(.system(.footnote, design: .serif))
                .lineSpacing(3)
                .foregroundStyle(LibraryPalette.mutedInk)
                .padding(.vertical, LibrarySpacing.small)

            ForEach(series.multipleCopyGroups, id: \.id) { group in
                let issue = series.issues.first { $0.publicationID == group.publicationID }
                PeriodicalFindingRow(
                    kicker: "EGZEMPLARZE",
                    title: issueLabel(issue),
                    detail: "\(group.itemIDs.count) egzemplarze · jeden rekord publikacji",
                    destinationItem: group.itemIDs.compactMap { itemByID[$0] }.first
                )
            }
        }
    }

    private var duplicateRecordsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            EditorialSectionHeader(
                title: "Powtórzone rekordy publikacji",
                value: String(series.duplicatePublicationGroups.count),
                accent: LibraryPalette.orange
            )

            Text("Te rekordy opisują ten sam numer i mogą wymagać scalenia po ręcznym sprawdzeniu.")
                .font(.system(.footnote, design: .serif))
                .lineSpacing(3)
                .foregroundStyle(LibraryPalette.mutedInk)
                .padding(.vertical, LibrarySpacing.small)

            ForEach(series.duplicatePublicationGroups, id: \.id) { group in
                PeriodicalFindingRow(
                    kicker: "REKORDY",
                    title: "Nr \(group.issueRange.displayName) · \(group.cycle.displayName)",
                    detail: "\(group.publicationIDs.count) rekordy publikacji · \(group.itemIDs.count) egzemplarzy",
                    destinationItem: group.itemIDs.compactMap { itemByID[$0] }.first
                )
            }
        }
    }

    private var savedIssuesSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            EditorialSectionHeader(
                title: "Zapisane numery",
                value: String(series.issues.count),
                accent: filter == .all ? LibraryPalette.orange : LibraryPalette.ink
            )

            ForEach(series.issues, id: \.id) { issue in
                PeriodicalIssueRow(
                    issue: issue,
                    destinationItem: issue.copies.compactMap { itemByID[$0.itemID] }.first
                )
            }
        }
    }

    private var missingGroups: [MissingIssueGroup] {
        var order: [PeriodicalIssueCycle] = []
        var numbers: [PeriodicalIssueCycle: [Int]] = [:]
        for issue in series.missingIssues {
            if numbers[issue.cycle] == nil {
                order.append(issue.cycle)
            }
            numbers[issue.cycle, default: []].append(issue.number)
        }
        return order.map { cycle in
            MissingIssueGroup(cycle: cycle, numbers: numbers[cycle, default: []])
        }
    }

    private func issueLabel(_ issue: PeriodicalAnalyzedIssue?) -> String {
        guard let issue else { return "Numer bez oznaczenia" }
        return issue.primaryLabel
    }
}

private struct MissingIssueGroup: Identifiable {
    let cycle: PeriodicalIssueCycle
    let numbers: [Int]
    var id: String { "\(cycle.displayName)|\(numbers.map(String.init).joined(separator: ","))" }
}

private struct PeriodicalIssueRow: View {
    let issue: PeriodicalAnalyzedIssue
    let destinationItem: OwnedItem?

    var body: some View {
        Group {
            if let destinationItem {
                NavigationLink {
                    ItemDetailView(item: destinationItem)
                } label: {
                    rowContent(showsChevron: true)
                }
                .buttonStyle(.plain)
                .accessibilityHint("Otwiera szczegóły pierwszego egzemplarza")
            } else {
                rowContent(showsChevron: false)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    private func rowContent(showsChevron: Bool) -> some View {
        HStack(alignment: .top, spacing: LibrarySpacing.small) {
            VStack(alignment: .leading, spacing: 5) {
                Text("NUMER")
                    .font(.caption2.weight(.bold))
                    .tracking(1.35)
                    .foregroundStyle(LibraryPalette.orangeText)

                Text(issue.primaryLabel)
                    .font(.system(.title3, design: .serif, weight: .bold))
                    .fixedSize(horizontal: false, vertical: true)

                if let detailLine {
                    Text(detailLine)
                        .font(.subheadline)
                        .foregroundStyle(LibraryPalette.mutedInk)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let copyLine {
                    Text(copyLine)
                        .font(.caption)
                        .foregroundStyle(LibraryPalette.mutedInk)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(LibraryPalette.orangeText)
                    .frame(width: 44, height: 44)
                    .accessibilityHidden(true)
            }
        }
        .foregroundStyle(LibraryPalette.ink)
        .padding(.vertical, LibrarySpacing.small)
        .frame(maxWidth: .infinity, minHeight: 68, alignment: .leading)
        .contentShape(Rectangle())
        .overlay(alignment: .top) {
            Rectangle().fill(LibraryPalette.rule).frame(height: 1)
        }
    }

    private var detailLine: String? {
        var values: [String] = []
        if !issue.issueDate.isEmpty { values.append(issue.issueDate) }
        if !issue.issueVolume.isEmpty { values.append("tom \(issue.issueVolume)") }
        if let cycle = issue.cycle,
           !values.contains(cycle.displayName) {
            values.append(cycle.displayName)
        }
        return values.joined(separator: " · ").nilIfBlank
    }

    private var copyLine: String? {
        guard !issue.copies.isEmpty else { return nil }
        let countLabel = issue.copies.count == 1 ? "1 egzemplarz" : "\(issue.copies.count) egzemplarze"
        let locations = Array(Set(issue.copies.map(\.locationPath).filter { !$0.isEmpty })).sorted()
        let locationLabel: String
        if locations.isEmpty {
            locationLabel = "bez lokalizacji"
        } else if locations.count == 1 {
            locationLabel = locations[0].replacingOccurrences(of: " / ", with: " › ")
        } else {
            locationLabel = "\(locations.count) lokalizacje"
        }
        let statusLabel = copyStatusLabel
        return [countLabel, statusLabel, locationLabel]
            .compactMap { $0 }
            .joined(separator: " · ")
    }

    private var copyStatusLabel: String? {
        let statuses = Set(issue.copies.map(\.status))
        var labels: [String] = []
        if statuses.contains(.loaned) { labels.append("wypożyczone") }
        if statuses.contains(.missing) { labels.append("oznaczone jako brak") }
        return labels.joined(separator: ", ").nilIfBlank
    }

    private var accessibilityLabel: String {
        [issue.primaryLabel, detailLine, copyLine].compactMap { $0 }.joined(separator: ", ")
    }
}

private struct PeriodicalFindingRow: View {
    let kicker: String
    let title: String
    let detail: String
    let destinationItem: OwnedItem?

    var body: some View {
        Group {
            if let destinationItem {
                NavigationLink {
                    ItemDetailView(item: destinationItem)
                } label: {
                    rowContent(showsChevron: true)
                }
                .buttonStyle(.plain)
                .accessibilityHint("Otwiera szczegóły pierwszego egzemplarza")
            } else {
                rowContent(showsChevron: false)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title), \(detail)")
    }

    private func rowContent(showsChevron: Bool) -> some View {
        HStack(alignment: .center, spacing: LibrarySpacing.small) {
            VStack(alignment: .leading, spacing: 5) {
                Text(kicker.uppercased())
                    .font(.caption2.weight(.bold))
                    .tracking(1.35)
                    .foregroundStyle(LibraryPalette.orangeText)
                Text(title)
                    .font(.system(.body, design: .serif, weight: .bold))
                    .fixedSize(horizontal: false, vertical: true)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(LibraryPalette.mutedInk)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(LibraryPalette.orangeText)
                    .frame(width: 44, height: 44)
                    .accessibilityHidden(true)
            }
        }
        .foregroundStyle(LibraryPalette.ink)
        .padding(.vertical, LibrarySpacing.small)
        .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
        .contentShape(Rectangle())
        .overlay(alignment: .top) {
            Rectangle().fill(LibraryPalette.rule).frame(height: 1)
        }
    }
}

private struct PeriodicalWarningRow: View {
    let warning: PeriodicalAnalysisWarning

    var body: some View {
        HStack(alignment: .top, spacing: LibrarySpacing.small) {
            Rectangle()
                .fill(LibraryPalette.orange)
                .frame(width: 3)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 5) {
                Text(warningLabel)
                    .font(.caption2.weight(.bold))
                    .tracking(1.45)
                    .foregroundStyle(LibraryPalette.orangeText)

                Text(warning.message)
                    .font(.system(.footnote, design: .serif))
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, LibrarySpacing.small)
        .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
        .overlay(alignment: .top) {
            Rectangle().fill(LibraryPalette.rule).frame(height: 1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(warningLabel). \(warning.message)")
    }

    private var warningLabel: String {
        switch warning.kind {
        case .invalidExplicitISSN: "DO SPRAWDZENIA · ISSN"
        case .identifierConflict: "DO SPRAWDZENIA · IDENTYFIKATORY"
        case .conflictingIssueMetadata: "DO SPRAWDZENIA · OPIS NUMERU"
        case .missingRangeLimitExceeded: "UWAGA · ZAKRES NUMERÓW"
        case .missingListTruncated: "UWAGA · LISTA LUK"
        }
    }
}

private extension PeriodicalAnalyzedIssue {
    var primaryLabel: String {
        if let canonicalIssueNumber, !canonicalIssueNumber.isEmpty {
            return "Nr \(canonicalIssueNumber)"
        }
        let clean = issueNumber.trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty ? "Numer bez oznaczenia" : "Nr \(clean)"
    }
}

private extension PeriodicalSeriesAnalysis {
    var hasGapFindings: Bool {
        !missingIssues.isEmpty
            || warnings.contains { $0.kind == .missingRangeLimitExceeded }
    }

    var hasDuplicateFindings: Bool {
        !multipleCopyGroups.isEmpty
            || !duplicatePublicationGroups.isEmpty
            || warnings.contains { $0.kind == .conflictingIssueMetadata }
    }
}

private extension String {
    var nilIfBlank: String? {
        let clean = trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty ? nil : clean
    }
}
