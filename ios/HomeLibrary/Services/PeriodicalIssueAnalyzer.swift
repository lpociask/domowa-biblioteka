import Foundation

struct PeriodicalCollectionAnalysis: Equatable, Sendable {
    let series: [PeriodicalSeriesAnalysis]
    let excludedArchivedCopyCount: Int
    let excludedNonPeriodicalItemCount: Int
}

enum PeriodicalSeriesIdentification: Equatable, Hashable, Sendable {
    case issn(String)
    case metadata(title: String, publisher: String, language: String)
    case isolatedIdentifierConflict(
        publicationID: UUID,
        explicitISSN: String,
        derivedISSN: String
    )
    case isolatedPublication(publicationID: UUID)

    fileprivate var stableID: String {
        switch self {
        case .issn(let issn):
            return "issn:\(issn.replacingOccurrences(of: "-", with: ""))"
        case .metadata(let title, let publisher, let language):
            return "metadata:\(title)|\(publisher)|\(language)"
        case .isolatedIdentifierConflict(let publicationID, _, _):
            return "conflict:\(publicationID.uuidString.lowercased())"
        case .isolatedPublication(let publicationID):
            return "publication:\(publicationID.uuidString.lowercased())"
        }
    }
}

enum PeriodicalIssueCycle: Equatable, Hashable, Sendable {
    case year(Int)
    case volume(String)
    case continuous

    var displayName: String {
        switch self {
        case .year(let year): String(year)
        case .volume(let volume): "Tom \(volume)"
        case .continuous: "Numeracja ciągła"
        }
    }
}

struct PeriodicalIssueRange: Equatable, Hashable, Sendable {
    let first: Int
    let last: Int

    var displayName: String {
        first == last ? String(first) : "\(first)-\(last)"
    }
}

enum PeriodicalAnalyzedCopyStatus: String, Equatable, Sendable {
    case owned
    case loaned
    case missing
}

struct PeriodicalCopySnapshot: Equatable, Sendable {
    let itemID: UUID
    let externalID: String
    let status: PeriodicalAnalyzedCopyStatus
    let locationPath: String
}

struct PeriodicalAnalyzedIssue: Equatable, Sendable {
    let id: String
    let publicationID: UUID
    let publicationExternalID: String
    let issueNumber: String
    let canonicalIssueNumber: String?
    let issueRange: PeriodicalIssueRange?
    let cycle: PeriodicalIssueCycle?
    let issueDate: String
    let issueVolume: String
    let publicationYear: Int?
    let explicitMainEANs: [String]
    let eanSupplements: [String]
    let copies: [PeriodicalCopySnapshot]
}

struct PeriodicalMissingIssue: Equatable, Sendable {
    let id: String
    let cycle: PeriodicalIssueCycle
    let number: Int
}

struct PeriodicalMultipleCopyGroup: Equatable, Sendable {
    let id: String
    let publicationID: UUID
    let itemIDs: [UUID]
}

struct PeriodicalDuplicatePublicationGroup: Equatable, Sendable {
    let id: String
    let cycle: PeriodicalIssueCycle
    let issueRange: PeriodicalIssueRange
    let publicationIDs: [UUID]
    let itemIDs: [UUID]
}

enum PeriodicalAnalysisWarningKind: String, Equatable, Sendable {
    case invalidExplicitISSN
    case identifierConflict
    case conflictingIssueMetadata
    case missingRangeLimitExceeded
    case missingListTruncated
}

struct PeriodicalAnalysisWarning: Equatable, Sendable {
    let id: String
    let kind: PeriodicalAnalysisWarningKind
    let publicationIDs: [UUID]
    let message: String
}

struct PeriodicalSeriesAnalysis: Equatable, Sendable {
    let id: String
    let identification: PeriodicalSeriesIdentification
    let title: String
    let publisher: String
    let language: String
    let issn: String?
    let issues: [PeriodicalAnalyzedIssue]
    let missingIssues: [PeriodicalMissingIssue]
    let multipleCopyGroups: [PeriodicalMultipleCopyGroup]
    let duplicatePublicationGroups: [PeriodicalDuplicatePublicationGroup]
    let warnings: [PeriodicalAnalysisWarning]
}

/// Builds a read-only projection of periodical series and issue continuity.
/// Nothing produced by this analyzer is persisted or included in collection
/// export; every value can be rebuilt from `Publication` and `OwnedItem`.
enum PeriodicalIssueAnalyzer {
    private static let maximumMissingRange = 200
    private static let maximumMissingIssues = 50

    static func analyze(items: [OwnedItem]) -> PeriodicalCollectionAnalysis {
        var publications: [ObjectIdentifier: PublicationAccumulator] = [:]
        var excludedArchivedCopyCount = 0
        var excludedNonPeriodicalItemCount = 0

        for item in items {
            guard let publication = item.publication,
                  publication.publicationType == .periodical else {
                excludedNonPeriodicalItemCount += 1
                continue
            }

            guard item.status != .archived else {
                excludedArchivedCopyCount += 1
                continue
            }

            let key = ObjectIdentifier(publication)
            if publications[key] == nil {
                publications[key] = PublicationAccumulator(publication: publication)
            }
            publications[key]?.copies.append(copySnapshot(item))
        }

        let snapshots = publications.values
            .map(\.snapshot)
            .sorted(by: publicationSnapshotSort)

        var grouped: [PeriodicalSeriesIdentification: [PublicationSnapshot]] = [:]
        for snapshot in snapshots {
            grouped[snapshot.identification, default: []].append(snapshot)
        }

        let series = grouped
            .map { identification, publications in
                analyzeSeries(
                    identification: identification,
                    publications: publications.sorted(by: publicationSnapshotSort)
                )
            }
            .sorted { lhs, rhs in
                lhs.id.localizedStandardCompare(rhs.id) == .orderedAscending
            }

        return PeriodicalCollectionAnalysis(
            series: series,
            excludedArchivedCopyCount: excludedArchivedCopyCount,
            excludedNonPeriodicalItemCount: excludedNonPeriodicalItemCount
        )
    }

    private static func analyzeSeries(
        identification: PeriodicalSeriesIdentification,
        publications: [PublicationSnapshot]
    ) -> PeriodicalSeriesAnalysis {
        let seriesID = identification.stableID
        let issues = publications
            .map { issueSnapshot(from: $0, seriesID: seriesID) }
            .sorted(by: issueSort)

        var warnings = publications.flatMap(\.warnings)
        let multipleCopyGroups: [PeriodicalMultipleCopyGroup] = publications.compactMap { publication in
            guard publication.copies.count > 1 else { return nil }
            return PeriodicalMultipleCopyGroup(
                id: "\(seriesID)|copies|\(stableUUID(publication.id))",
                publicationID: publication.id,
                itemIDs: publication.copies.map(\.itemID).sorted(by: uuidSort)
            )
        }

        let duplicateResult = duplicatePublicationGroups(
            issues: issues,
            seriesID: seriesID
        )
        warnings.append(contentsOf: duplicateResult.warnings)

        let missingResult = missingIssues(issues: issues, seriesID: seriesID)
        warnings.append(contentsOf: missingResult.warnings)

        return PeriodicalSeriesAnalysis(
            id: seriesID,
            identification: identification,
            title: preferredDisplayValue(publications.map(\.title)),
            publisher: preferredDisplayValue(publications.map(\.publisher)),
            language: preferredDisplayValue(publications.map(\.language)),
            issn: displayISSN(for: identification),
            issues: issues,
            missingIssues: missingResult.issues,
            multipleCopyGroups: multipleCopyGroups.sorted { $0.id < $1.id },
            duplicatePublicationGroups: duplicateResult.groups.sorted { $0.id < $1.id },
            warnings: uniqueWarnings(warnings)
        )
    }

    private static func issueSnapshot(
        from publication: PublicationSnapshot,
        seriesID: String
    ) -> PeriodicalAnalyzedIssue {
        let parsed = parseIssueNumber(publication.issueNumber)
        let cycle = parsed.map {
            issueCycle(
                encodedYear: $0.encodedYear,
                issueDate: publication.issueDate,
                publicationYear: publication.publicationYear,
                issueVolume: publication.issueVolume
            )
        }
        let coordinate = parsed.map { parsed in
            "\(cycle!.stableID)|\(parsed.range.first)-\(parsed.range.last)"
        } ?? "unparsed:\(normalizedText(publication.issueNumber))"

        return PeriodicalAnalyzedIssue(
            id: "\(seriesID)|\(coordinate)|\(stableUUID(publication.id))",
            publicationID: publication.id,
            publicationExternalID: publication.externalID,
            issueNumber: publication.issueNumber,
            canonicalIssueNumber: parsed?.canonical,
            issueRange: parsed?.range,
            cycle: cycle,
            issueDate: publication.issueDate,
            issueVolume: publication.issueVolume,
            publicationYear: publication.publicationYear,
            explicitMainEANs: publication.explicitMainEANs,
            eanSupplements: publication.eanSupplements,
            copies: publication.copies.sorted { uuidSort($0.itemID, $1.itemID) }
        )
    }

    private static func duplicatePublicationGroups(
        issues: [PeriodicalAnalyzedIssue],
        seriesID: String
    ) -> (
        groups: [PeriodicalDuplicatePublicationGroup],
        warnings: [PeriodicalAnalysisWarning]
    ) {
        var candidates: [IssueIdentity: [PeriodicalAnalyzedIssue]] = [:]
        for issue in issues {
            guard let cycle = issue.cycle, let range = issue.issueRange else { continue }
            candidates[IssueIdentity(cycle: cycle, range: range), default: []].append(issue)
        }

        var groups: [PeriodicalDuplicatePublicationGroup] = []
        var warnings: [PeriodicalAnalysisWarning] = []

        for (identity, matchingIssues) in candidates {
            let identityID = "\(identity.cycle.stableID)|\(identity.range.first)-\(identity.range.last)"

            for partition in compatibleIdentifierPartitions(matchingIssues) {
                let publicationIDs = partition.issues
                    .map(\.publicationID)
                    .uniquedAndSortedUUIDs()
                guard publicationIDs.count > 1 else { continue }

                let hasDateConflict = hasConflictingDates(partition.issues.map(\.issueDate))
                let hasVolumeConflict = hasConflictingVolumes(partition.issues.map(\.issueVolume))
                let partitionID = partition.signature.stableID

                if hasDateConflict || hasVolumeConflict {
                    var fields: [String] = []
                    if hasDateConflict { fields.append("daty numeru") }
                    if hasVolumeConflict { fields.append("tomu") }
                    warnings.append(
                        PeriodicalAnalysisWarning(
                            id: "\(seriesID)|warning|metadata-conflict|\(identityID)|\(partitionID)",
                            kind: .conflictingIssueMetadata,
                            publicationIDs: publicationIDs,
                            message: "Rekordy numeru \(identity.range.displayName) mają sprzeczne wartości \(fields.joined(separator: " i ")); nie oznaczono ich jako pewnego duplikatu."
                        )
                    )
                    continue
                }

                groups.append(
                    PeriodicalDuplicatePublicationGroup(
                        id: "\(seriesID)|duplicate|\(identityID)|\(partitionID)",
                        cycle: identity.cycle,
                        issueRange: identity.range,
                        publicationIDs: publicationIDs,
                        itemIDs: partition.issues
                            .flatMap(\.copies)
                            .map(\.itemID)
                            .uniquedAndSortedUUIDs()
                    )
                )
            }
        }

        return (groups, warnings)
    }

    /// Splits one metadata coordinate into identifier-compatible subsets.
    /// Exact identifier evidence forms the anchors. A partial signature can
    /// join a stricter signature only when that target is unique; otherwise it
    /// remains separate and cannot bridge two conflicting EAN/add-on groups.
    private static func compatibleIdentifierPartitions(
        _ issues: [PeriodicalAnalyzedIssue]
    ) -> [IssueIdentifierPartition] {
        var bySignature = Dictionary(grouping: issues) { issue in
            IssueIdentifierSignature(issue: issue)
        }

        let mergeOrder = bySignature.keys
            .filter { !$0.isIsolated && $0.specificity < 2 }
            .sorted { lhs, rhs in
                if lhs.specificity != rhs.specificity {
                    return lhs.specificity > rhs.specificity
                }
                return lhs.stableID < rhs.stableID
            }

        for source in mergeOrder {
            guard let sourceIssues = bySignature[source] else { continue }
            let targets = bySignature.keys
                .filter { $0.isStrictRefinement(of: source) }
                .sorted { $0.stableID < $1.stableID }
            guard targets.count == 1, let target = targets.first else { continue }

            bySignature[target, default: []].append(contentsOf: sourceIssues)
            bySignature.removeValue(forKey: source)
        }

        return bySignature.map { signature, partitionIssues in
            IssueIdentifierPartition(
                signature: signature,
                issues: partitionIssues.sorted { uuidSort($0.publicationID, $1.publicationID) }
            )
        }.sorted { $0.signature.stableID < $1.signature.stableID }
    }

    private static func missingIssues(
        issues: [PeriodicalAnalyzedIssue],
        seriesID: String
    ) -> (issues: [PeriodicalMissingIssue], warnings: [PeriodicalAnalysisWarning]) {
        var rangesByCycle: [PeriodicalIssueCycle: [PeriodicalIssueRange]] = [:]
        for issue in issues {
            guard let cycle = issue.cycle, let range = issue.issueRange else { continue }
            rangesByCycle[cycle, default: []].append(range)
        }

        var result: [PeriodicalMissingIssue] = []
        var warnings: [PeriodicalAnalysisWarning] = []

        for cycle in rangesByCycle.keys.sorted(by: cycleSort) {
            guard let ranges = rangesByCycle[cycle],
                  let minimum = ranges.map(\.first).min(),
                  let maximum = ranges.map(\.last).max(),
                  maximum >= minimum else {
                continue
            }

            let span = maximum - minimum + 1
            if span > maximumMissingRange {
                warnings.append(
                    PeriodicalAnalysisWarning(
                        id: "\(seriesID)|warning|missing-range|\(cycle.stableID)",
                        kind: .missingRangeLimitExceeded,
                        publicationIDs: [],
                        message: "Zakres \(minimum)-\(maximum) dla cyklu \(cycle.displayName) przekracza bezpieczny limit \(maximumMissingRange); lista braków nie została wyliczona."
                    )
                )
                continue
            }

            var present = Set<Int>()
            for range in ranges {
                present.formUnion(range.first...range.last)
            }
            let missing = (minimum...maximum).filter { !present.contains($0) }
            let limitedMissing = missing.prefix(maximumMissingIssues)
            result.append(contentsOf: limitedMissing.map { number in
                PeriodicalMissingIssue(
                    id: "\(seriesID)|missing|\(cycle.stableID)|\(number)",
                    cycle: cycle,
                    number: number
                )
            })

            if missing.count > maximumMissingIssues {
                warnings.append(
                    PeriodicalAnalysisWarning(
                        id: "\(seriesID)|warning|missing-truncated|\(cycle.stableID)",
                        kind: .missingListTruncated,
                        publicationIDs: [],
                        message: "Lista braków dla cyklu \(cycle.displayName) została ograniczona do pierwszych \(maximumMissingIssues) pozycji."
                    )
                )
            }
        }

        return (
            result.sorted {
                if $0.cycle != $1.cycle { return cycleSort($0.cycle, $1.cycle) }
                return $0.number < $1.number
            },
            warnings
        )
    }

    private static func issueCycle(
        encodedYear: Int?,
        issueDate: String,
        publicationYear: Int?,
        issueVolume: String
    ) -> PeriodicalIssueCycle {
        if let encodedYear {
            return .year(encodedYear)
        }
        if let dateYear = year(from: issueDate) {
            return .year(dateYear)
        }
        if let publicationYear, isPlausibleYear(publicationYear) {
            return .year(publicationYear)
        }
        let volume = normalizedVolume(issueVolume)
        if !volume.isEmpty {
            return .volume(volume)
        }
        return .continuous
    }

    private static func parseIssueNumber(_ value: String) -> ParsedIssueNumber? {
        let compact = value
            .replacingOccurrences(of: "–", with: "-")
            .replacingOccurrences(of: "—", with: "-")
            .replacingOccurrences(of: "−", with: "-")
            .filter { !$0.isWhitespace }

        if let captures = captures(#"^([0-9]{1,4})-([0-9]{1,4})/([0-9]{4})$"#, in: compact),
           let first = Int(captures[0]),
           let last = Int(captures[1]),
           let year = Int(captures[2]),
           first > 0,
           last >= first,
           isPlausibleYear(year) {
            return ParsedIssueNumber(
                canonical: "\(first)-\(last)/\(year)",
                range: PeriodicalIssueRange(first: first, last: last),
                encodedYear: year
            )
        }

        if let captures = captures(#"^([0-9]{1,4})/([0-9]{4})$"#, in: compact),
           let number = Int(captures[0]),
           let year = Int(captures[1]),
           number > 0,
           isPlausibleYear(year) {
            return ParsedIssueNumber(
                canonical: "\(number)/\(year)",
                range: PeriodicalIssueRange(first: number, last: number),
                encodedYear: year
            )
        }

        if let captures = captures(#"^([0-9]{4})/([0-9]{1,4})$"#, in: compact),
           let year = Int(captures[0]),
           let number = Int(captures[1]),
           number > 0,
           isPlausibleYear(year) {
            return ParsedIssueNumber(
                canonical: "\(number)/\(year)",
                range: PeriodicalIssueRange(first: number, last: number),
                encodedYear: year
            )
        }

        if compact.count <= 4,
           compact.allSatisfy(\.isNumber),
           let number = Int(compact),
           number > 0 {
            return ParsedIssueNumber(
                canonical: String(number),
                range: PeriodicalIssueRange(first: number, last: number),
                encodedYear: nil
            )
        }

        return nil
    }

    private static func captures(_ pattern: String, in value: String) -> [String]? {
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(
                in: value,
                range: NSRange(value.startIndex..., in: value)
              ),
              match.numberOfRanges > 1 else {
            return nil
        }

        return (1..<match.numberOfRanges).compactMap { index in
            guard let range = Range(match.range(at: index), in: value) else { return nil }
            return String(value[range])
        }
    }

    private static func year(from value: String) -> Int? {
        guard let captures = captures(#".*?((?:18|19|20|21)[0-9]{2}).*"#, in: value),
              let result = captures.first.flatMap(Int.init),
              isPlausibleYear(result) else {
            return nil
        }
        return result
    }

    private static func isPlausibleYear(_ value: Int) -> Bool {
        (1800...2199).contains(value)
    }

    private static func normalizedISSN(_ value: String) -> String? {
        let compact = value.uppercased().filter { $0.isNumber || $0 == "X" }
        guard compact.count == 8 else { return nil }

        let characters = Array(compact)
        guard characters.dropLast().allSatisfy({ $0.isNumber }),
              let expectedCheck = characters.last else {
            return nil
        }

        let sum = characters.dropLast().enumerated().reduce(0) { partial, pair in
            partial + (pair.element.wholeNumberValue ?? 0) * (8 - pair.offset)
        }
        let checkValue = (11 - (sum % 11)) % 11
        let actualCheck: Int
        if expectedCheck == "X" {
            actualCheck = 10
        } else if let digit = expectedCheck.wholeNumberValue {
            actualCheck = digit
        } else {
            return nil
        }
        guard actualCheck == checkValue else { return nil }

        return "\(compact.prefix(4))-\(compact.suffix(4))"
    }

    private static func derivedISSNs(ean: String, barcode: String) -> [String] {
        [ean, barcode]
            .compactMap { value -> String? in
                let parsed = PublicationIdentifierParser.parse(value)
                guard parsed.isValid else { return nil }
                return parsed.issn.flatMap(normalizedISSN)
            }
            .uniquedAndSortedStrings()
    }

    private static func periodicalIdentifierEvidence(
        ean: String,
        barcode: String
    ) -> (mainEANs: [String], supplements: [String]) {
        var mainEANs: [String] = []
        var supplements: [String] = []

        for (value, isEANField) in [(ean, true), (barcode, false)] {
            let parsed = PublicationIdentifierParser.parse(value)
            guard parsed.isValid, parsed.normalized.count == 13 else { continue }

            // `ean` is the explicit main-code field. A barcode participates
            // only when it has the serial-publication 977 prefix, avoiding an
            // unrelated historical vendor barcode becoming identity evidence.
            if isEANField || parsed.normalized.hasPrefix("977") {
                mainEANs.append(parsed.normalized)
            }
            if let supplement = parsed.eanSupplement, !supplement.isEmpty {
                supplements.append(supplement)
            }
        }

        return (
            mainEANs.uniquedAndSortedStrings(),
            supplements.uniquedAndSortedStrings()
        )
    }

    private static func identification(
        publicationID: UUID,
        title: String,
        publisher: String,
        language: String,
        explicitISSN: String,
        ean: String,
        barcode: String
    ) -> (
        identification: PeriodicalSeriesIdentification,
        warnings: [PeriodicalAnalysisWarning]
    ) {
        let cleanExplicit = explicitISSN.trimmingCharacters(in: .whitespacesAndNewlines)
        let validExplicit = normalizedISSN(cleanExplicit)
        let derived = derivedISSNs(ean: ean, barcode: barcode)
        var warnings: [PeriodicalAnalysisWarning] = []

        if !cleanExplicit.isEmpty, validExplicit == nil {
            warnings.append(
                PeriodicalAnalysisWarning(
                    id: "publication:\(stableUUID(publicationID))|warning|invalid-issn",
                    kind: .invalidExplicitISSN,
                    publicationIDs: [publicationID],
                    message: "Jawny ISSN „\(cleanExplicit)” ma niepoprawny format lub cyfrę kontrolną."
                )
            )
        }

        if let validExplicit,
           let conflicting = derived.first(where: { $0 != validExplicit }) {
            warnings.append(
                PeriodicalAnalysisWarning(
                    id: "publication:\(stableUUID(publicationID))|warning|identifier-conflict",
                    kind: .identifierConflict,
                    publicationIDs: [publicationID],
                    message: "Jawny ISSN \(validExplicit) jest sprzeczny z ISSN \(conflicting) wyprowadzonym z EAN-977; rekord został odizolowany."
                )
            )
            return (
                .isolatedIdentifierConflict(
                    publicationID: publicationID,
                    explicitISSN: validExplicit,
                    derivedISSN: conflicting
                ),
                warnings
            )
        }

        if derived.count > 1 {
            warnings.append(
                PeriodicalAnalysisWarning(
                    id: "publication:\(stableUUID(publicationID))|warning|identifier-conflict",
                    kind: .identifierConflict,
                    publicationIDs: [publicationID],
                    message: "Pola EAN wskazują różne serie (\(derived.joined(separator: ", "))); rekord został odizolowany."
                )
            )
            return (
                .isolatedIdentifierConflict(
                    publicationID: publicationID,
                    explicitISSN: validExplicit ?? "",
                    derivedISSN: derived.joined(separator: ",")
                ),
                warnings
            )
        }

        if let validExplicit {
            return (.issn(validExplicit), warnings)
        }
        if let derivedISSN = derived.first {
            return (.issn(derivedISSN), warnings)
        }

        let normalizedTitle = normalizedText(title)
        let normalizedPublisher = normalizedText(publisher)
        let normalizedLanguage = normalizedText(language)
        guard !normalizedTitle.isEmpty,
              !normalizedPublisher.isEmpty,
              !normalizedLanguage.isEmpty else {
            return (.isolatedPublication(publicationID: publicationID), warnings)
        }
        return (
            .metadata(
                title: normalizedTitle,
                publisher: normalizedPublisher,
                language: normalizedLanguage
            ),
            warnings
        )
    }

    private static func displayISSN(for identification: PeriodicalSeriesIdentification) -> String? {
        switch identification {
        case .issn(let value): value
        case .isolatedIdentifierConflict(_, let explicitISSN, _):
            explicitISSN.isEmpty ? nil : explicitISSN
        case .metadata, .isolatedPublication: nil
        }
    }

    private static func normalizedText(_ value: String) -> String {
        let folded = value.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: Locale(identifier: "pl_PL")
        )
        let scalars = folded.unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) ? Character(String(scalar)) : " "
        }
        return String(scalars)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .lowercased()
    }

    private static func normalizedVolume(_ value: String) -> String {
        let normalized = normalizedText(value)
        if normalized.allSatisfy(\.isNumber), let number = Int(normalized) {
            return String(number)
        }
        return normalized
    }

    private static func preferredDisplayValue(_ values: [String]) -> String {
        let candidates = values
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !candidates.isEmpty else { return "" }

        let counts = Dictionary(grouping: candidates, by: normalizedText).mapValues(\.count)
        return candidates.sorted { lhs, rhs in
            let lhsCount = counts[normalizedText(lhs), default: 0]
            let rhsCount = counts[normalizedText(rhs), default: 0]
            if lhsCount != rhsCount { return lhsCount > rhsCount }
            let lhsNormalized = normalizedText(lhs)
            let rhsNormalized = normalizedText(rhs)
            if lhsNormalized != rhsNormalized { return lhsNormalized < rhsNormalized }
            return lhs < rhs
        }.first ?? ""
    }

    private static func hasConflictingVolumes(_ values: [String]) -> Bool {
        values.map(normalizedVolume).filter { !$0.isEmpty }.uniquedAndSortedStrings().count > 1
    }

    private static func hasConflictingDates(_ values: [String]) -> Bool {
        let dates = values
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        for firstIndex in dates.indices {
            for secondIndex in dates.indices where secondIndex > firstIndex {
                if datesConflict(dates[firstIndex], dates[secondIndex]) {
                    return true
                }
            }
        }
        return false
    }

    private static func datesConflict(_ lhs: String, _ rhs: String) -> Bool {
        let left = parsedDateComponents(lhs)
        let right = parsedDateComponents(rhs)
        if let left, let right {
            if left.year != right.year { return true }
            if let leftMonth = left.month, let rightMonth = right.month, leftMonth != rightMonth {
                return true
            }
            if let leftDay = left.day, let rightDay = right.day, leftDay != rightDay {
                return true
            }
            return false
        }
        return normalizedText(lhs) != normalizedText(rhs)
    }

    private static func parsedDateComponents(_ value: String) -> SimpleDateComponents? {
        if let captures = captures(#".*?((?:18|19|20|21)[0-9]{2})[-./](0?[1-9]|1[0-2])[-./](0?[1-9]|[12][0-9]|3[01]).*"#, in: value),
           let year = Int(captures[0]),
           let month = Int(captures[1]),
           let day = Int(captures[2]) {
            return SimpleDateComponents(year: year, month: month, day: day)
        }
        if let captures = captures(#".*?((?:18|19|20|21)[0-9]{2})[-./](0?[1-9]|1[0-2]).*"#, in: value),
           let year = Int(captures[0]),
           let month = Int(captures[1]) {
            return SimpleDateComponents(year: year, month: month, day: nil)
        }
        if let year = year(from: value) {
            return SimpleDateComponents(year: year, month: nil, day: nil)
        }
        return nil
    }

    private static func issueSort(
        _ lhs: PeriodicalAnalyzedIssue,
        _ rhs: PeriodicalAnalyzedIssue
    ) -> Bool {
        switch (lhs.cycle, rhs.cycle) {
        case let (left?, right?) where left != right:
            return cycleSort(left, right)
        case (nil, _?):
            return false
        case (_?, nil):
            return true
        default:
            break
        }

        if lhs.issueRange?.first != rhs.issueRange?.first {
            return (lhs.issueRange?.first ?? Int.max) < (rhs.issueRange?.first ?? Int.max)
        }
        if lhs.issueRange?.last != rhs.issueRange?.last {
            return (lhs.issueRange?.last ?? Int.max) < (rhs.issueRange?.last ?? Int.max)
        }
        return uuidSort(lhs.publicationID, rhs.publicationID)
    }

    private static func cycleSort(_ lhs: PeriodicalIssueCycle, _ rhs: PeriodicalIssueCycle) -> Bool {
        lhs.sortKey.localizedStandardCompare(rhs.sortKey) == .orderedAscending
    }

    private static func publicationSnapshotSort(
        _ lhs: PublicationSnapshot,
        _ rhs: PublicationSnapshot
    ) -> Bool {
        uuidSort(lhs.id, rhs.id)
    }

    private static func uniqueWarnings(
        _ warnings: [PeriodicalAnalysisWarning]
    ) -> [PeriodicalAnalysisWarning] {
        var byID: [String: PeriodicalAnalysisWarning] = [:]
        for warning in warnings {
            byID[warning.id] = warning
        }
        return byID.values.sorted { $0.id < $1.id }
    }

    private static func copySnapshot(_ item: OwnedItem) -> PeriodicalCopySnapshot {
        let status: PeriodicalAnalyzedCopyStatus
        switch item.status {
        case .owned: status = .owned
        case .loaned: status = .loaned
        case .missing: status = .missing
        case .archived:
            preconditionFailure("Archived copies are filtered before snapshotting")
        }
        return PeriodicalCopySnapshot(
            itemID: item.id,
            externalID: item.exportID,
            status: status,
            locationPath: LocationPath(item.locationPathText).canonical
        )
    }

    private static func stableUUID(_ value: UUID) -> String {
        value.uuidString.lowercased()
    }

    private static func uuidSort(_ lhs: UUID, _ rhs: UUID) -> Bool {
        stableUUID(lhs) < stableUUID(rhs)
    }

    private struct PublicationAccumulator {
        let id: UUID
        let externalID: String
        let title: String
        let publisher: String
        let language: String
        let publicationYear: Int?
        let issueNumber: String
        let issueVolume: String
        let issueDate: String
        let explicitMainEANs: [String]
        let eanSupplements: [String]
        let identification: PeriodicalSeriesIdentification
        let warnings: [PeriodicalAnalysisWarning]
        var copies: [PeriodicalCopySnapshot] = []

        init(publication: Publication) {
            id = publication.id
            externalID = publication.exportID
            title = publication.title.trimmingCharacters(in: .whitespacesAndNewlines)
            publisher = publication.publisher.trimmingCharacters(in: .whitespacesAndNewlines)
            language = publication.language.trimmingCharacters(in: .whitespacesAndNewlines)
            publicationYear = publication.publicationYear
            issueNumber = publication.issueNumber.trimmingCharacters(in: .whitespacesAndNewlines)
            issueVolume = publication.issueVolume.trimmingCharacters(in: .whitespacesAndNewlines)
            issueDate = publication.issueDate.trimmingCharacters(in: .whitespacesAndNewlines)
            let evidence = PeriodicalIssueAnalyzer.periodicalIdentifierEvidence(
                ean: publication.ean,
                barcode: publication.barcode
            )
            explicitMainEANs = evidence.mainEANs
            eanSupplements = evidence.supplements
            let identity = PeriodicalIssueAnalyzer.identification(
                publicationID: publication.id,
                title: publication.title,
                publisher: publication.publisher,
                language: publication.language,
                explicitISSN: publication.issn,
                ean: publication.ean,
                barcode: publication.barcode
            )
            identification = identity.identification
            warnings = identity.warnings
        }

        var snapshot: PublicationSnapshot {
            PublicationSnapshot(
                id: id,
                externalID: externalID,
                title: title,
                publisher: publisher,
                language: language,
                publicationYear: publicationYear,
                issueNumber: issueNumber,
                issueVolume: issueVolume,
                issueDate: issueDate,
                explicitMainEANs: explicitMainEANs,
                eanSupplements: eanSupplements,
                identification: identification,
                copies: copies,
                warnings: warnings
            )
        }
    }

    private struct PublicationSnapshot: Sendable {
        let id: UUID
        let externalID: String
        let title: String
        let publisher: String
        let language: String
        let publicationYear: Int?
        let issueNumber: String
        let issueVolume: String
        let issueDate: String
        let explicitMainEANs: [String]
        let eanSupplements: [String]
        let identification: PeriodicalSeriesIdentification
        let copies: [PeriodicalCopySnapshot]
        let warnings: [PeriodicalAnalysisWarning]
    }

    private struct ParsedIssueNumber {
        let canonical: String
        let range: PeriodicalIssueRange
        let encodedYear: Int?
    }

    private struct IssueIdentity: Hashable {
        let cycle: PeriodicalIssueCycle
        let range: PeriodicalIssueRange
    }

    private struct IssueIdentifierPartition {
        let signature: IssueIdentifierSignature
        let issues: [PeriodicalAnalyzedIssue]
    }

    private struct IssueIdentifierSignature: Hashable {
        let mainEAN: String?
        let supplement: String?
        let isolatedPublicationID: UUID?

        init(issue: PeriodicalAnalyzedIssue) {
            guard issue.explicitMainEANs.count <= 1,
                  issue.eanSupplements.count <= 1 else {
                mainEAN = nil
                supplement = nil
                isolatedPublicationID = issue.publicationID
                return
            }
            mainEAN = issue.explicitMainEANs.first
            supplement = issue.eanSupplements.first
            isolatedPublicationID = nil
        }

        var isIsolated: Bool { isolatedPublicationID != nil }

        var specificity: Int {
            (mainEAN == nil ? 0 : 1) + (supplement == nil ? 0 : 1)
        }

        var stableID: String {
            if let isolatedPublicationID {
                return "isolated:\(stableUUID(isolatedPublicationID))"
            }
            return "main:\(mainEAN ?? "none")|addon:\(supplement ?? "none")"
        }

        func isStrictRefinement(of other: IssueIdentifierSignature) -> Bool {
            guard !isIsolated, !other.isIsolated else { return false }
            if let otherMain = other.mainEAN, mainEAN != otherMain { return false }
            if let otherSupplement = other.supplement, supplement != otherSupplement { return false }

            let addsMain = other.mainEAN == nil && mainEAN != nil
            let addsSupplement = other.supplement == nil && supplement != nil
            return addsMain || addsSupplement
        }
    }

    private struct SimpleDateComponents {
        let year: Int
        let month: Int?
        let day: Int?
    }
}

private extension PeriodicalIssueCycle {
    var stableID: String {
        switch self {
        case .year(let year): "year:\(year)"
        case .volume(let volume): "volume:\(volume)"
        case .continuous: "continuous"
        }
    }

    var sortKey: String {
        switch self {
        case .year(let year): String(format: "0:%04d", year)
        case .volume(let volume): "1:\(volume)"
        case .continuous: "2:"
        }
    }
}

private extension Array where Element == UUID {
    func uniquedAndSortedUUIDs() -> [UUID] {
        Array(Set(self)).sorted { $0.uuidString.lowercased() < $1.uuidString.lowercased() }
    }
}

private extension Array where Element == String {
    func uniquedAndSortedStrings() -> [String] {
        Array(Set(self)).sorted()
    }
}
