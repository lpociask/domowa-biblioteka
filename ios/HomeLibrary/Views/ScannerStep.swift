import SwiftUI
import UIKit
import Vision
import VisionKit

struct ScannerStep: View {
    let onCode: (_ value: String, _ cameFromCamera: Bool) -> Void

    @State private var manualCode = ""
    @State private var scannerBecameUnavailable = false
    @State private var validationMessage: String?

    private var cameraScannerAvailable: Bool {
        DataScannerViewController.isSupported
            && DataScannerViewController.isAvailable
            && !scannerBecameUnavailable
    }

    var body: some View {
        ZStack {
            if cameraScannerAvailable {
                DataScannerRepresentable(
                    onRecognized: { value in
                        validationMessage = nil
                        onCode(value, true)
                    },
                    onRejected: showValidationError,
                    onUnavailable: { scannerBecameUnavailable = true }
                )
                .ignoresSafeArea(edges: .bottom)

                VStack {
                    VStack(spacing: 4) {
                        Text("Znajdź kod z tyłu okładki")
                            .font(.callout.weight(.semibold))
                        Text("Zeskanuj 13 cyfr: 978/979 dla książki albo 977 dla prasy")
                            .font(.caption)
                    }
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
                        .padding(.top, 16)
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("Zeskanuj kod z tylnej okładki. Kod książki zaczyna się od 978 lub 979, a kod prasy od 977.")
                        .accessibilityIdentifier("scanner.cameraInstruction")
                    Spacer()
                }
            } else {
                ContentUnavailableView {
                    Label("Skaner aparatu jest niedostępny", systemImage: "camera.fill")
                } description: {
                    Text("Wpisz poniżej 13-cyfrowy kod z tylnej okładki: 978/979 dla książki albo 977 dla prasy.")
                }
            }
        }
        .background(Color.black.opacity(cameraScannerAvailable ? 1 : 0.04))
        .safeAreaInset(edge: .bottom) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Kod ręcznie")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                HStack {
                    TextField("ISBN 978/979 lub kod prasy 977", text: $manualCode)
                        .textFieldStyle(.roundedBorder)
                        .keyboardType(.numberPad)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.done)
                        .onSubmit(submitManualCode)
                        .onChange(of: manualCode) { _, _ in
                            validationMessage = nil
                        }
                        .accessibilityLabel("Kod z tylnej okładki")
                        .accessibilityHint("Wpisz 13-cyfrowy ISBN zaczynający się od 978 lub 979 albo kod prasy zaczynający się od 977.")
                        .accessibilityIdentifier("scanner.manualCode")

                    Button("Dalej", action: submitManualCode)
                        .buttonStyle(.borderedProminent)
                        .disabled(manualCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityHint("Sprawdza kod i przechodzi dalej, jeśli jest poprawny.")
                        .accessibilityIdentifier("scanner.submitManualCode")
                }

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

                Text("Po rozpoznaniu ISBN aplikacja wyśle tylko ten numer do Biblioteki Narodowej, a przy braku wyniku — do Open Library. Kod prasy 977 uzupełni ISSN. Lokalizacja i notatki pozostają na urządzeniu.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding()
            .background(.bar)
        }
    }

    private func submitManualCode() {
        switch ScannerCodeValidator.validate(manualCode) {
        case .accepted(let value):
            validationMessage = nil
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

    static func validate(
        _ rawValue: String,
        source: ScannerCodeInputSource = .manual
    ) -> ScannerCodeValidation {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .rejected(emptyMessage)
        }

        guard let candidate = normalizedCandidate(from: trimmed) else {
            return .rejected(source == .qr ? unsupportedQRMessage : formatMessage)
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
            return .accepted(parsed.normalized)
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

        let allowedSeparators = "-‐‑‒–—"
        guard candidate.allSatisfy({ character in
            character.isNumber || character.isWhitespace || allowedSeparators.contains(character)
        }) else {
            return nil
        }

        let digits = candidate.filter(\.isNumber)
        guard digits.count == 13 else {
            return nil
        }
        return String(digits)
    }
}

private struct DataScannerRepresentable: UIViewControllerRepresentable {
    let onRecognized: (String) -> Void
    let onRejected: (String) -> Void
    let onUnavailable: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
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
        uiViewController.stopScanning()
    }

    @MainActor
    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        private let onRecognized: (String) -> Void
        private let onRejected: (String) -> Void
        private let onUnavailable: () -> Void
        private var lastRejectedValue: String?

        init(
            onRecognized: @escaping (String) -> Void,
            onRejected: @escaping (String) -> Void,
            onUnavailable: @escaping () -> Void
        ) {
            self.onRecognized = onRecognized
            self.onRejected = onRejected
            self.onUnavailable = onUnavailable
        }

        func dataScanner(
            _ dataScanner: DataScannerViewController,
            didAdd addedItems: [RecognizedItem],
            allItems: [RecognizedItem]
        ) {
            for item in addedItems {
                guard case .barcode(let barcode) = item,
                      let value = barcode.payloadStringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !value.isEmpty else {
                    continue
                }

                let inputSource: ScannerCodeInputSource = barcode.observation.symbology == .qr
                    ? .qr
                    : .ean13
                switch ScannerCodeValidator.validate(value, source: inputSource) {
                case .accepted(let normalizedValue):
                    dataScanner.stopScanning()
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                    onRecognized(normalizedValue)
                    return
                case .rejected(let message):
                    guard lastRejectedValue != value else { continue }
                    lastRejectedValue = value
                    onRejected(message)
                }
            }
        }

        func dataScanner(
            _ dataScanner: DataScannerViewController,
            becameUnavailableWithError error: DataScannerViewController.ScanningUnavailable
        ) {
            reportUnavailable()
        }

        func reportUnavailable() {
            onUnavailable()
        }
    }
}
