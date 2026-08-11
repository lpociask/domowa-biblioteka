import SwiftUI
import UIKit
import Vision
import VisionKit

struct ScannerStep: View {
    let onCode: (_ value: String, _ cameFromCamera: Bool) -> Void

    @State private var manualCode = ""
    @State private var scannerBecameUnavailable = false

    private var cameraScannerAvailable: Bool {
        DataScannerViewController.isSupported
            && DataScannerViewController.isAvailable
            && !scannerBecameUnavailable
    }

    var body: some View {
        ZStack {
            if cameraScannerAvailable {
                DataScannerRepresentable(
                    onRecognized: { onCode($0, true) },
                    onUnavailable: { scannerBecameUnavailable = true }
                )
                .ignoresSafeArea(edges: .bottom)

                VStack {
                    Text("Umieść EAN, ISBN, UPC‑E lub QR w kadrze")
                        .font(.callout.weight(.medium))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(.top, 16)
                    Spacer()
                }
            } else {
                ContentUnavailableView {
                    Label("Skaner aparatu jest niedostępny", systemImage: "camera.fill")
                } description: {
                    Text("Na symulatorze, nieobsługiwanym urządzeniu lub przy ograniczonym dostępie wpisz kod poniżej.")
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
                    TextField("ISBN, EAN, UPC‑E lub zawartość QR", text: $manualCode)
                        .textFieldStyle(.roundedBorder)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.done)
                        .onSubmit(submitManualCode)

                    Button("Dalej", action: submitManualCode)
                        .buttonStyle(.borderedProminent)
                        .disabled(manualCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                Text("Po rozpoznaniu ISBN aplikacja wyśle tylko ten numer do Biblioteki Narodowej, a przy braku wyniku — do Open Library. Lokalizacja i notatki pozostają na urządzeniu.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding()
            .background(.bar)
        }
    }

    private func submitManualCode() {
        let value = manualCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        onCode(value, false)
    }
}

private struct DataScannerRepresentable: UIViewControllerRepresentable {
    let onRecognized: (String) -> Void
    let onUnavailable: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onRecognized: onRecognized, onUnavailable: onUnavailable)
    }

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let controller = DataScannerViewController(
            recognizedDataTypes: [
                .barcode(symbologies: [.ean13, .upce, .qr])
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
        private let onUnavailable: () -> Void
        private var deliveredValues: Set<String> = []

        init(onRecognized: @escaping (String) -> Void, onUnavailable: @escaping () -> Void) {
            self.onRecognized = onRecognized
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
                      !value.isEmpty,
                      deliveredValues.insert(value).inserted else {
                    continue
                }
                dataScanner.stopScanning()
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                onRecognized(value)
                return
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
