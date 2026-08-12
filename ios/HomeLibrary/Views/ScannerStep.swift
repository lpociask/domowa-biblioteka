import SwiftUI
import UIKit
import Vision
import VisionKit

struct ScannerStep: View {
    let currentLocation: String?
    let recentSaveTitle: String?
    let initiallySuppressedCode: String?
    let onUndoRecentSave: (() -> Void)?
    let onChangeLocation: (() -> Void)?
    let onCode: (_ value: String, _ cameFromCamera: Bool) -> Void

    @State private var manualCode = ""
    @State private var scannerBecameUnavailable = false
    @State private var validationMessage: String?
    @State private var showsPrivacyInformation = false
    @FocusState private var manualCodeIsFocused: Bool

    init(
        currentLocation: String? = nil,
        recentSaveTitle: String? = nil,
        initiallySuppressedCode: String? = nil,
        onUndoRecentSave: (() -> Void)? = nil,
        onChangeLocation: (() -> Void)? = nil,
        onCode: @escaping (_ value: String, _ cameFromCamera: Bool) -> Void
    ) {
        let cleanLocation = currentLocation?.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanRecentSaveTitle = recentSaveTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.currentLocation = cleanLocation?.isEmpty == false ? cleanLocation : nil
        self.recentSaveTitle = cleanRecentSaveTitle?.isEmpty == false ? cleanRecentSaveTitle : nil
        if let initiallySuppressedCode,
           case .accepted(let normalizedCode) = ScannerCodeValidator.validate(initiallySuppressedCode) {
            self.initiallySuppressedCode = normalizedCode
        } else {
            self.initiallySuppressedCode = nil
        }
        self.onUndoRecentSave = onUndoRecentSave
        self.onChangeLocation = onChangeLocation
        self.onCode = onCode
    }

    var showsLocationChangeAction: Bool {
        currentLocation != nil && onChangeLocation != nil
    }

    private var cameraScannerAvailable: Bool {
        DataScannerViewController.isSupported
            && DataScannerViewController.isAvailable
            && !scannerBecameUnavailable
    }

    var body: some View {
        ZStack {
            if cameraScannerAvailable {
                DataScannerRepresentable(
                    initiallySuppressedCode: initiallySuppressedCode,
                    onRecognized: { value in
                        validationMessage = nil
                        onCode(value, true)
                    },
                    onRejected: showValidationError,
                    onUnavailable: { scannerBecameUnavailable = true }
                )
                .ignoresSafeArea()

                cameraOverlay
            } else {
                unavailableCameraMessage
            }
        }
        .background(cameraScannerAvailable ? Color.black : LibraryPalette.paper)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            manualEntryPanel
        }
        .libraryLightAppearance()
    }

    private var cameraOverlay: some View {
        VStack(spacing: 0) {
            scannerInstruction
                .padding(.top, LibrarySpacing.small)

            Spacer(minLength: LibrarySpacing.medium)

            ScannerTargetFrame()
                .frame(maxWidth: 420)
                .aspectRatio(1.65, contentMode: .fit)
                .padding(.horizontal, LibrarySpacing.large)
                .accessibilityHidden(true)

            Spacer(minLength: LibrarySpacing.large)
        }
        .editorialPage(width: LibrarySpacing.readerWidth)
    }

    private var scannerInstruction: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("KOD Z TYŁU OKŁADKI")
                .font(.caption2.weight(.bold))
                .tracking(1.45)
            Text("Ustaw w ramce cały kod: 978/979 dla książki albo 977 dla prasy. Przy czasopiśmie obejmij też mały kod po prawej.")
                .font(.system(.footnote, design: .serif))
                .lineSpacing(2)
        }
        .foregroundStyle(LibraryPalette.ink)
        .padding(.horizontal, LibrarySpacing.medium)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LibraryPalette.paper.opacity(0.96))
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(LibraryPalette.orange)
                .frame(width: 4)
        }
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(LibraryPalette.ink.opacity(0.3))
                .frame(height: 1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Zeskanuj cały kod z tylnej okładki. Kod książki zaczyna się od 978 lub 979, a kod prasy od 977. Przy czasopiśmie obejmij też mały kod po prawej.")
        .accessibilityIdentifier("scanner.cameraInstruction")
    }

    private var unavailableCameraMessage: some View {
        ZStack {
            PaperBackground()

            ScrollView {
                VStack(alignment: .leading, spacing: LibrarySpacing.medium) {
                    Text("WPISZ KOD RĘCZNIE")
                        .font(.caption.weight(.bold))
                        .tracking(1.7)
                        .foregroundStyle(LibraryPalette.orangeText)

                    Text("Aparat nie jest dostępny.")
                        .font(.system(.largeTitle, design: .serif, weight: .bold))
                        .fontWidth(.condensed)
                        .foregroundStyle(LibraryPalette.ink)
                        .fixedSize(horizontal: false, vertical: true)

                    Rectangle()
                        .fill(LibraryPalette.ink)
                        .frame(width: 76, height: 2)

                    Text("Kod znajdziesz przy kodzie kreskowym z tyłu okładki. Pole poniżej przyjmuje ISBN książki i kod EAN prasy.")
                        .font(.system(.body, design: .serif))
                        .lineSpacing(4)
                        .foregroundStyle(LibraryPalette.mutedInk)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .editorialPage(width: 560)
                .padding(.vertical, LibrarySpacing.large)
            }
            .scrollIndicators(.hidden)
        }
    }

    private var manualEntryPanel: some View {
        ViewThatFits(in: .vertical) {
            manualPanelContent

            ScrollView {
                manualPanelContent
            }
            .frame(minHeight: 240, maxHeight: 340)
            .scrollDismissesKeyboard(.interactively)
        }
        .frame(maxWidth: LibrarySpacing.readerWidth)
        .frame(maxWidth: .infinity)
        .background(LibraryPalette.paper)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(LibraryPalette.ink)
                .frame(height: 1)
        }
    }

    private var manualPanelContent: some View {
        VStack(alignment: .leading, spacing: LibrarySpacing.small) {
            if let recentSaveTitle, let onUndoRecentSave {
                HStack(alignment: .center, spacing: LibrarySpacing.small) {
                    Image(systemName: "checkmark")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(LibraryPalette.orangeText)
                        .frame(width: 28, height: 28)
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 3) {
                        Text("DODANO DO KOLEKCJI")
                            .font(.caption2.weight(.bold))
                            .tracking(1.35)
                        Text(recentSaveTitle)
                            .font(.system(.footnote, design: .serif, weight: .semibold))
                            .foregroundStyle(LibraryPalette.mutedInk)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer(minLength: LibrarySpacing.xSmall)

                    Button("Cofnij", action: onUndoRecentSave)
                        .font(.caption2.weight(.bold))
                        .tracking(1.05)
                        .foregroundStyle(LibraryPalette.orangeText)
                        .frame(minWidth: 58, minHeight: 44)
                        .contentShape(Rectangle())
                        .accessibilityLabel("Cofnij dodanie \(recentSaveTitle)")
                        .accessibilityIdentifier("scanner.undoLastSave")
                }
                .padding(.leading, LibrarySpacing.small)
                .frame(maxWidth: .infinity, minHeight: 58, alignment: .leading)
                .background(LibraryPalette.ink.opacity(0.045))
                .overlay(alignment: .leading) {
                    Rectangle()
                        .fill(LibraryPalette.orange)
                        .frame(width: 4)
                }
                .overlay(alignment: .bottom) {
                    Rectangle().fill(LibraryPalette.rule).frame(height: 1)
                }
            }

            if let currentLocation {
                HStack(alignment: .center, spacing: LibrarySpacing.small) {
                    HStack(alignment: .top, spacing: LibrarySpacing.small) {
                        Image(systemName: "mappin")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(LibraryPalette.orangeText)
                            .frame(width: 24, height: 24)
                            .accessibilityHidden(true)

                        VStack(alignment: .leading, spacing: 3) {
                            Text("BIEŻĄCA PÓŁKA")
                                .font(.caption2.weight(.bold))
                                .tracking(1.35)
                            Text(currentLocation)
                                .font(.system(.footnote, design: .serif, weight: .semibold))
                                .foregroundStyle(LibraryPalette.mutedInk)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Bieżąca półka")
                    .accessibilityValue(currentLocation)
                    .accessibilityIdentifier("scanner.currentLocation")

                    if showsLocationChangeAction, let onChangeLocation {
                        Button(action: onChangeLocation) {
                            HStack(spacing: 5) {
                                Text("Zmień")
                                Image(systemName: "chevron.right")
                                    .font(.caption2.weight(.bold))
                                    .accessibilityHidden(true)
                            }
                            .font(.caption2.weight(.bold))
                            .tracking(1.05)
                            .foregroundStyle(LibraryPalette.orangeText)
                            .frame(minWidth: 68, minHeight: 44)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Zmień bieżącą półkę")
                        .accessibilityHint("Otwiera wybór lokalizacji dla kolejnych publikacji.")
                        .accessibilityIdentifier("scanner.changeLocation")
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .overlay(alignment: .bottom) {
                    Rectangle().fill(LibraryPalette.rule).frame(height: 1)
                }
            }

            Text("KOD RĘCZNIE")
                .font(.caption2.weight(.bold))
                .tracking(1.55)
                .foregroundStyle(LibraryPalette.mutedInk)

            TextField("ISBN 978/979 lub 977 + mały kod", text: $manualCode)
                .font(.body.monospacedDigit())
                .foregroundStyle(LibraryPalette.ink)
                .keyboardType(.numbersAndPunctuation)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.done)
                .focused($manualCodeIsFocused)
                .onSubmit(submitManualCode)
                .onChange(of: manualCode) { _, _ in
                    validationMessage = nil
                }
                .padding(.horizontal, 14)
                .frame(minHeight: 50)
                .background(LibraryPalette.warmPaper.opacity(0.72))
                .overlay {
                    RoundedRectangle(cornerRadius: LibraryRadius.small)
                        .stroke(validationMessage == nil ? LibraryPalette.rule : Color.red.opacity(0.8), lineWidth: 1)
                }
                .clipShape(RoundedRectangle(cornerRadius: LibraryRadius.small))
                .accessibilityLabel("Kod z tylnej okładki")
                .accessibilityHint("Wpisz 13-cyfrowy ISBN zaczynający się od 978 lub 979 albo kod prasy 977. Po plusie możesz dopisać dwu- lub pięciocyfrowy mały kod.")
                .accessibilityIdentifier("scanner.manualCode")

            if let validationMessage {
                Label(validationMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Błąd kodu")
                    .accessibilityValue(validationMessage)
                    .accessibilityIdentifier("scanner.validationMessage")
            }

            EditorialPrimaryButton(title: "Dalej", icon: "arrow.right", action: submitManualCode)
                .disabled(isManualCodeEmpty)
                .opacity(isManualCodeEmpty ? 0.5 : 1)
                .accessibilityHint("Sprawdza kod i przechodzi dalej, jeśli jest poprawny.")
                .accessibilityIdentifier("scanner.submitManualCode")

            DisclosureGroup(isExpanded: $showsPrivacyInformation) {
                Text("Po rozpoznaniu ISBN aplikacja wyśle tylko ten numer do Biblioteki Narodowej, a przy braku wyniku — do Open Library. Kod prasy 977 uzupełni ISSN. Lokalizacja i notatki pozostają na urządzeniu.")
                    .font(.caption)
                    .foregroundStyle(LibraryPalette.mutedInk)
                    .lineSpacing(2)
                    .padding(.top, LibrarySpacing.xSmall)
                    .fixedSize(horizontal: false, vertical: true)
            } label: {
                Label("Jak używamy kodu", systemImage: "info.circle")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(LibraryPalette.ink)
                    .frame(minHeight: 44)
            }
            .tint(LibraryPalette.orangeText)
        }
        .padding(.horizontal, LibrarySpacing.page)
        .padding(.top, LibrarySpacing.medium)
        .padding(.bottom, LibrarySpacing.small)
    }

    private var isManualCodeEmpty: Bool {
        manualCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func submitManualCode() {
        switch ScannerCodeValidator.validate(manualCode) {
        case .accepted(let value):
            validationMessage = nil
            manualCodeIsFocused = false
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            onCode(value, false)
        case .rejected(let message):
            showValidationError(message)
        }
    }

    private func showValidationError(_ message: String) {
        validationMessage = message
        UINotificationFeedbackGenerator().notificationOccurred(.error)
        UIAccessibility.post(notification: .announcement, argument: message)
    }
}

private struct ScannerTargetFrame: View {
    var body: some View {
        ZStack {
            ScannerCornerShape()
                .stroke(Color.white, style: StrokeStyle(lineWidth: 3, lineCap: .square, lineJoin: .miter))
                .shadow(color: .black.opacity(0.42), radius: 2, y: 1)

            Rectangle()
                .fill(LibraryPalette.orange)
                .frame(height: 2)
                .padding(.horizontal, LibrarySpacing.medium)
                .shadow(color: .black.opacity(0.25), radius: 1, y: 1)
        }
    }
}

private struct ScannerCornerShape: Shape {
    func path(in rect: CGRect) -> Path {
        let corner = min(42, min(rect.width, rect.height) * 0.26)
        var path = Path()

        path.move(to: CGPoint(x: rect.minX, y: rect.minY + corner))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX + corner, y: rect.minY))

        path.move(to: CGPoint(x: rect.maxX - corner, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + corner))

        path.move(to: CGPoint(x: rect.maxX, y: rect.maxY - corner))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX - corner, y: rect.maxY))

        path.move(to: CGPoint(x: rect.minX + corner, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - corner))

        return path
    }
}

enum ScannerCodeValidation: Equatable {
    case accepted(String)
    case rejected(String)
}

enum ScannerCodeInputSource: Equatable {
    case manual
    case ean13
    case qr
}

enum ScannerCodeValidator {
    static let emptyMessage = "Wpisz kod z tylnej okładki."
    static let formatMessage = "To nie jest kod publikacji. Użyj 13-cyfrowego kodu zaczynającego się od 978, 979 lub 977."
    static let checksumMessage = "Kod ma nieprawidłową cyfrę kontrolną. Sprawdź cyfry i spróbuj ponownie."
    static let unsupportedEANMessage = "To poprawny EAN, ale nie jest kodem książki ani prasy. Szukaj kodu zaczynającego się od 978, 979 lub 977."
    static let unsupportedQRMessage = "Ten kod QR nie zawiera poprawnego ISBN. Zeskanuj kod kreskowy z tylnej okładki."
    static let supplementMessage = "Dodatek kodu prasy po znaku + musi mieć dokładnie 2 albo 5 cyfr."

    static func validate(
        _ rawValue: String,
        supplementalPayload: String? = nil,
        source: ScannerCodeInputSource = .manual
    ) -> ScannerCodeValidation {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .rejected(emptyMessage)
        }

        // A person entering the printed add-on explicitly should hear that it
        // is incomplete instead of silently losing it. VisionKit payloads are
        // handled separately and may still fall back to the valid main EAN.
        if source == .manual, hasMalformedExplicitPeriodicalSupplement(trimmed) {
            return .rejected(supplementMessage)
        }

        guard var candidate = normalizedCandidate(from: trimmed) else {
            return .rejected(source == .qr ? unsupportedQRMessage : formatMessage)
        }

        if let supplementalPayload,
           let supplement = normalizedSupplement(supplementalPayload),
           !candidate.contains("+") {
            candidate += "+\(supplement)"
        }

        let parsed = PublicationIdentifierParser.parse(candidate)
        guard parsed.isValid else {
            return .rejected(source == .qr ? unsupportedQRMessage : checksumMessage)
        }

        if parsed.kind == .isbn13,
           parsed.normalized.hasPrefix("978") || parsed.normalized.hasPrefix("979") {
            return .accepted(parsed.normalized)
        }

        guard source != .qr else {
            return .rejected(unsupportedQRMessage)
        }

        if parsed.kind == .ean13,
           parsed.normalized.hasPrefix("977"),
           parsed.issn != nil {
            let canonicalValue = parsed.eanSupplement
                .map { "\(parsed.normalized)+\($0)" }
                ?? parsed.normalized
            return .accepted(canonicalValue)
        }

        return .rejected(unsupportedEANMessage)
    }

    private static func normalizedCandidate(from rawValue: String) -> String? {
        var candidate = rawValue
        if candidate.uppercased().hasPrefix("ISBN") {
            candidate = String(candidate.dropFirst(4))
                .trimmingCharacters(in: .whitespacesAndNewlines)

            if candidate.hasPrefix("-13") {
                candidate = String(candidate.dropFirst(3))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if candidate.hasPrefix(":") {
                candidate = String(candidate.dropFirst())
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        let allowedSeparators = "-‐‑‒–—+"
        guard candidate.allSatisfy({ character in
            character.isNumber || character.isWhitespace || allowedSeparators.contains(character)
        }) else {
            return nil
        }

        let parts = candidate.split(separator: "+", omittingEmptySubsequences: false)
        if parts.count == 2 {
            let primary = parts[0].filter(\.isNumber)
            guard primary.count == 13 else { return nil }

            let supplement = parts[1].filter(\.isNumber)
            if supplement.count == 2 || supplement.count == 5 {
                return "\(primary)+\(supplement)"
            }

            // A damaged or partial add-on must not make a valid primary EAN
            // unusable. The scanner can still catalogue the issue by its main
            // 977 code and the user may complete the issue data later.
            return String(primary)
        }

        guard parts.count == 1 else { return nil }
        let digits = candidate.filter(\.isNumber)
        if digits.count == 13 {
            return String(digits)
        }
        if digits.count == 15 || digits.count == 18 {
            return "\(digits.prefix(13))+\(digits.dropFirst(13))"
        }
        return nil
    }

    private static func hasMalformedExplicitPeriodicalSupplement(_ rawValue: String) -> Bool {
        guard rawValue.contains("+") else { return false }
        let parts = rawValue.split(separator: "+", omittingEmptySubsequences: false)
        guard let primaryPart = parts.first else { return false }
        let primary = primaryPart.filter(\.isNumber)
        guard primary.count == 13, primary.hasPrefix("977") else { return false }
        guard parts.count == 2 else { return true }
        let supplement = parts[1].filter(\.isNumber)
        return (supplement.count != 2 && supplement.count != 5) ||
            !parts[1].allSatisfy { $0.isNumber || $0.isWhitespace }
    }

    private static func normalizedSupplement(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count == 2 || trimmed.count == 5,
              trimmed.allSatisfy(\.isNumber) else {
            return nil
        }
        return trimmed
    }
}

enum ScannerEANSupplementAction: Equatable {
    case wait(until: Date)
    case emit(String)
    case ignore
}

/// Small deterministic state machine that gives VisionKit a short window to
/// attach EAN-2/EAN-5 in `didUpdate`. Keeping it independent from the camera
/// delegate makes the exactly-once behavior testable without VisionKit.
struct ScannerEANSupplementAccumulator {
    private enum State: Equatable {
        case idle
        case waiting(primaryEAN: String, deadline: Date)
        case completed
    }

    private let waitInterval: TimeInterval
    private var state: State = .idle

    init(waitInterval: TimeInterval = 0.45) {
        self.waitInterval = waitInterval
    }

    mutating func observe(
        canonicalCode: String,
        supplementalPayload: String?,
        now: Date = .now
    ) -> ScannerEANSupplementAction {
        guard state != .completed else { return .ignore }

        let parsed = PublicationIdentifierParser.parse(canonicalCode)
        guard parsed.isValid,
              parsed.kind == .ean13,
              parsed.normalized.hasPrefix("977") else {
            state = .completed
            return .emit(canonicalCode)
        }

        let primaryEAN = parsed.normalized
        let supplement = parsed.eanSupplement ?? Self.normalizedSupplement(supplementalPayload)
        if let supplement {
            state = .completed
            return .emit("\(primaryEAN)+\(supplement)")
        }

        switch state {
        case .idle:
            let deadline = now.addingTimeInterval(waitInterval)
            state = .waiting(primaryEAN: primaryEAN, deadline: deadline)
            return .wait(until: deadline)
        case .waiting(let pendingEAN, let deadline):
            guard pendingEAN == primaryEAN else {
                let replacementDeadline = now.addingTimeInterval(waitInterval)
                state = .waiting(primaryEAN: primaryEAN, deadline: replacementDeadline)
                return .wait(until: replacementDeadline)
            }
            return .wait(until: deadline)
        case .completed:
            return .ignore
        }
    }

    mutating func resolveTimeout(now: Date = .now) -> ScannerEANSupplementAction {
        guard case .waiting(let primaryEAN, let deadline) = state else {
            return .ignore
        }
        guard now >= deadline else {
            return .wait(until: deadline)
        }

        state = .completed
        return .emit(primaryEAN)
    }

    mutating func reset() {
        state = .idle
    }

    /// Cancels a pending 977 when it is no longer visible. A transient item
    /// must never be emitted after the camera has already moved to another code.
    @discardableResult
    mutating func cancelIfPendingCodeIsNotVisible(_ canonicalCodes: [String]) -> Bool {
        guard case .waiting(let primaryEAN, _) = state else { return false }
        let visiblePrimaryEANs = canonicalCodes.compactMap { code -> String? in
            let parsed = PublicationIdentifierParser.parse(code)
            guard parsed.isValid, parsed.kind == .ean13 else { return nil }
            return parsed.normalized
        }
        guard !visiblePrimaryEANs.contains(primaryEAN) else { return false }
        state = .idle
        return true
    }

    private static func normalizedSupplement(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count == 2 || trimmed.count == 5,
              trimmed.allSatisfy(\.isNumber) else {
            return nil
        }
        return trimmed
    }
}

private struct DataScannerRepresentable: UIViewControllerRepresentable {
    let initiallySuppressedCode: String?
    let onRecognized: (String) -> Void
    let onRejected: (String) -> Void
    let onUnavailable: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            initiallySuppressedCode: initiallySuppressedCode,
            onRecognized: onRecognized,
            onRejected: onRejected,
            onUnavailable: onUnavailable
        )
    }

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let controller = DataScannerViewController(
            recognizedDataTypes: [
                .barcode(symbologies: [.ean13, .qr])
            ],
            qualityLevel: .balanced,
            recognizesMultipleItems: false,
            isHighFrameRateTrackingEnabled: true,
            isPinchToZoomEnabled: true,
            isGuidanceEnabled: true,
            isHighlightingEnabled: true
        )
        controller.delegate = context.coordinator

        Task { @MainActor in
            do {
                try controller.startScanning()
            } catch {
                context.coordinator.reportUnavailable()
            }
        }
        return controller
    }

    func updateUIViewController(_ uiViewController: DataScannerViewController, context: Context) {}

    static func dismantleUIViewController(_ uiViewController: DataScannerViewController, coordinator: Coordinator) {
        coordinator.cancelPendingSupplement()
        uiViewController.stopScanning()
    }

    @MainActor
    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        private let onRecognized: (String) -> Void
        private let onRejected: (String) -> Void
        private let onUnavailable: () -> Void
        private var lastRejectedValue: String?
        private var repeatGate: ScannerRepeatGate
        private var supplementAccumulator = ScannerEANSupplementAccumulator()
        private var supplementTimeoutTask: Task<Void, Never>?

        init(
            initiallySuppressedCode: String?,
            onRecognized: @escaping (String) -> Void,
            onRejected: @escaping (String) -> Void,
            onUnavailable: @escaping () -> Void
        ) {
            self.onRecognized = onRecognized
            self.onRejected = onRejected
            self.onUnavailable = onUnavailable
            repeatGate = ScannerRepeatGate(suppressedCode: initiallySuppressedCode)
        }

        func dataScanner(
            _ dataScanner: DataScannerViewController,
            didAdd addedItems: [RecognizedItem],
            allItems: [RecognizedItem]
        ) {
            process(addedItems, with: dataScanner)
        }

        func dataScanner(
            _ dataScanner: DataScannerViewController,
            didUpdate updatedItems: [RecognizedItem],
            allItems: [RecognizedItem]
        ) {
            process(updatedItems, with: dataScanner)
        }

        func dataScanner(
            _ dataScanner: DataScannerViewController,
            didRemove removedItems: [RecognizedItem],
            allItems: [RecognizedItem]
        ) {
            let visibleCodes = allItems.compactMap(Self.normalizedPublicationCode)
            repeatGate.updateVisibleCodes(visibleCodes)
            if supplementAccumulator.cancelIfPendingCodeIsNotVisible(visibleCodes) {
                cancelPendingSupplement()
            }
        }

        func dataScanner(
            _ dataScanner: DataScannerViewController,
            becameUnavailableWithError error: DataScannerViewController.ScanningUnavailable
        ) {
            reportUnavailable()
        }

        func reportUnavailable() {
            cancelPendingSupplement()
            onUnavailable()
        }

        func cancelPendingSupplement() {
            supplementTimeoutTask?.cancel()
            supplementTimeoutTask = nil
        }

        private func process(
            _ items: [RecognizedItem],
            with dataScanner: DataScannerViewController
        ) {
            for item in items {
                guard case .barcode(let barcode) = item,
                      let value = barcode.payloadStringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !value.isEmpty else {
                    continue
                }

                let inputSource: ScannerCodeInputSource = barcode.observation.symbology == .qr
                    ? .qr
                    : .ean13
                let supplementalPayload = inputSource == .ean13
                    ? barcode.observation.supplementalPayloadString
                    : nil

                switch ScannerCodeValidator.validate(
                    value,
                    supplementalPayload: supplementalPayload,
                    source: inputSource
                ) {
                case .accepted(let canonicalValue):
                    lastRejectedValue = nil
                    let action = inputSource == .ean13
                        ? supplementAccumulator.observe(
                            canonicalCode: canonicalValue,
                            supplementalPayload: supplementalPayload
                        )
                        : .emit(canonicalValue)
                    if handle(action, with: dataScanner) {
                        return
                    }
                case .rejected(let message):
                    let rejectionKey = "\(value)|\(supplementalPayload ?? "")"
                    guard lastRejectedValue != rejectionKey else { continue }
                    lastRejectedValue = rejectionKey
                    onRejected(message)
                }
            }
        }

        @discardableResult
        private func handle(
            _ action: ScannerEANSupplementAction,
            with dataScanner: DataScannerViewController
        ) -> Bool {
            switch action {
            case .wait(let deadline):
                scheduleSupplementTimeout(at: deadline, with: dataScanner)
                return false
            case .emit(let canonicalValue):
                cancelPendingSupplement()
                guard repeatGate.shouldAccept(canonicalValue) else {
                    supplementAccumulator.reset()
                    return false
                }
                dataScanner.stopScanning()
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                onRecognized(canonicalValue)
                return true
            case .ignore:
                return false
            }
        }

        private func scheduleSupplementTimeout(
            at deadline: Date,
            with dataScanner: DataScannerViewController
        ) {
            supplementTimeoutTask?.cancel()
            let delay = max(0, deadline.timeIntervalSinceNow)
            let nanoseconds = UInt64(delay * 1_000_000_000)
            supplementTimeoutTask = Task { @MainActor [weak self, weak dataScanner] in
                do {
                    try await Task.sleep(nanoseconds: nanoseconds)
                } catch {
                    return
                }
                guard let self, let dataScanner else { return }
                let action = self.supplementAccumulator.resolveTimeout()
                self.handle(action, with: dataScanner)
            }
        }

        private static func normalizedPublicationCode(from item: RecognizedItem) -> String? {
            guard case .barcode(let barcode) = item,
                  let value = barcode.payloadStringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.isEmpty else {
                return nil
            }

            let inputSource: ScannerCodeInputSource = barcode.observation.symbology == .qr
                ? .qr
                : .ean13
            guard case .accepted(let normalizedValue) = ScannerCodeValidator.validate(
                value,
                supplementalPayload: inputSource == .ean13
                    ? barcode.observation.supplementalPayloadString
                    : nil,
                source: inputSource
            ) else {
                return nil
            }
            return normalizedValue
        }
    }
}

struct ScannerRepeatGate {
    private(set) var suppressedCode: String?
    private let suppressionExpiresAt: Date
    private var hasObservedSuppressedCode = false

    init(
        suppressedCode: String?,
        now: Date = .now,
        graceInterval: TimeInterval = 1.25
    ) {
        self.suppressedCode = suppressedCode
        suppressionExpiresAt = now.addingTimeInterval(graceInterval)
    }

    mutating func shouldAccept(_ code: String, now: Date = .now) -> Bool {
        guard let suppressedCode,
              Self.representsSameVisiblePeriodicalCode(code, suppressedCode) else {
            return true
        }

        guard now < suppressionExpiresAt else {
            self.suppressedCode = nil
            return true
        }

        hasObservedSuppressedCode = true
        return false
    }

    mutating func updateVisibleCodes(_ codes: [String]) {
        guard hasObservedSuppressedCode,
              let suppressedCode,
              !codes.contains(where: {
                  Self.representsSameVisiblePeriodicalCode($0, suppressedCode)
              }) else {
            return
        }
        self.suppressedCode = nil
    }

    /// VisionKit may report the same printed EAN-977 first without an add-on
    /// and then with it (or vice versa). During the short post-save grace
    /// window these are one physical code. Two different non-empty add-ons
    /// remain distinct so scanning the next issue is never blocked.
    private static func representsSameVisiblePeriodicalCode(
        _ left: String,
        _ right: String
    ) -> Bool {
        if left == right { return true }

        let leftParsed = PublicationIdentifierParser.parse(left)
        let rightParsed = PublicationIdentifierParser.parse(right)
        guard leftParsed.isValid,
              rightParsed.isValid,
              leftParsed.kind == .ean13,
              rightParsed.kind == .ean13,
              leftParsed.normalized.hasPrefix("977"),
              rightParsed.normalized.hasPrefix("977"),
              leftParsed.normalized == rightParsed.normalized else {
            return false
        }

        switch (leftParsed.eanSupplement, rightParsed.eanSupplement) {
        case let (.some(leftSupplement), .some(rightSupplement)):
            return leftSupplement == rightSupplement
        default:
            return true
        }
    }
}
