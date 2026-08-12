import CoreTransferable
import ImageIO
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct PeriodicalCoverOCRSelection: Equatable, Sendable {
    let issueNumber: String?
    let issueVolume: String?
    let issueDate: String?

    var isEmpty: Bool {
        issueNumber == nil && issueVolume == nil && issueDate == nil
    }
}

/// Review-first cover OCR. The image exists only while the local Vision task
/// runs; the view returns selected text values and never persists a photo.
struct PeriodicalCoverOCRView: View {
    private enum Phase: Equatable {
        case source
        case processing
        case result(PeriodicalIssueTextSuggestions)
        case failed(String)
    }

    @Environment(\.dismiss) private var dismiss

    let existingIssueNumber: String
    let existingIssueVolume: String
    let existingIssueDate: String
    let onApply: (PeriodicalCoverOCRSelection) -> Void

    private let service: PeriodicalCoverOCRService

    @State private var phase: Phase = .source
    @State private var showsCamera = false
    @State private var photoItem: PhotosPickerItem?
    @State private var recognitionTask: Task<Void, Never>?
    @State private var useIssueNumber = false
    @State private var useIssueVolume = false
    @State private var useIssueDate = false

    init(
        existingIssueNumber: String,
        existingIssueVolume: String,
        existingIssueDate: String,
        service: PeriodicalCoverOCRService = PeriodicalCoverOCRService(),
        onApply: @escaping (PeriodicalCoverOCRSelection) -> Void
    ) {
        self.existingIssueNumber = existingIssueNumber
        self.existingIssueVolume = existingIssueVolume
        self.existingIssueDate = existingIssueDate
        self.service = service
        self.onApply = onApply
    }

    var body: some View {
        NavigationStack {
            ZStack {
                PaperBackground()

                ScrollView {
                    VStack(alignment: .leading, spacing: LibrarySpacing.xLarge) {
                        LibraryMasthead(
                            title: "Odczytaj okładkę",
                            eyebrow: "PRASA · OCR NA URZĄDZENIU",
                            subtitle: "Zrób zdjęcie przedniej okładki. Aplikacja zaproponuje numer, tom i datę — niczego nie zapisze bez Twojego potwierdzenia.",
                            compact: true
                        )

                        content
                    }
                    .padding(.vertical, LibrarySpacing.medium)
                    .editorialPage(width: 720)
                }
                .scrollIndicators(.hidden)
            }
            .foregroundStyle(LibraryPalette.ink)
            .navigationTitle("OCR okładki")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(LibraryPalette.paper, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(.light, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Anuluj") { dismiss() }
                        .foregroundStyle(LibraryPalette.ink)
                        .frame(minWidth: 44, minHeight: 44)
                }
            }
        }
        .libraryLightAppearance()
        .fullScreenCover(isPresented: $showsCamera) {
            PeriodicalCameraCapture(
                isPresented: $showsCamera,
                onImage: processCameraImage
            )
            .ignoresSafeArea()
        }
        .onChange(of: photoItem) { _, newItem in
            guard let newItem else { return }
            recognitionTask?.cancel()
            recognitionTask = Task {
                do {
                    guard let photo = try await newItem.loadTransferable(type: PeriodicalPhotoTransfer.self) else {
                        throw PeriodicalCoverImageError.unreadable
                    }
                    await processImageData(photo.data)
                } catch is CancellationError {
                    return
                } catch {
                    phase = .failed(error.localizedDescription)
                }
            }
        }
        .onDisappear {
            recognitionTask?.cancel()
        }
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .source:
            sourceContent
        case .processing:
            processingContent
        case .result(let suggestions):
            resultContent(suggestions)
        case .failed(let message):
            failureContent(message)
        }
    }

    private var sourceContent: some View {
        VStack(alignment: .leading, spacing: LibrarySpacing.large) {
            EditorialStatusBand(
                title: "Zdjęcie pozostaje prywatne",
                message: "Tekst jest rozpoznawany lokalnie przez iPhone’a. Zdjęcie nie trafia do internetu, kolekcji ani cache aplikacji.",
                icon: "lock"
            )

            VStack(alignment: .leading, spacing: LibrarySpacing.medium) {
                EditorialSectionHeader(title: "Wybierz źródło", value: "01")

                if UIImagePickerController.isSourceTypeAvailable(.camera) {
                    EditorialPrimaryButton(title: "Zrób zdjęcie okładki", icon: "camera") {
                        showsCamera = true
                    }
                    .accessibilityIdentifier("periodicalOCR.camera")
                }

                PhotosPicker(selection: $photoItem, matching: .images) {
                    HStack(spacing: LibrarySpacing.small) {
                        Text("WYBIERZ ZDJĘCIE")
                            .font(.subheadline.weight(.bold))
                            .tracking(1.1)
                        Spacer(minLength: LibrarySpacing.small)
                        Image(systemName: "photo")
                            .font(.headline)
                            .accessibilityHidden(true)
                    }
                    .foregroundStyle(LibraryPalette.ink)
                    .padding(.horizontal, LibrarySpacing.medium)
                    .frame(maxWidth: .infinity, minHeight: 56)
                    .overlay {
                        RoundedRectangle(cornerRadius: LibraryRadius.small)
                            .stroke(LibraryPalette.controlBorder, lineWidth: 1)
                    }
                    .contentShape(Rectangle())
                }
                .accessibilityLabel("Wybierz zdjęcie okładki z biblioteki zdjęć")
                .accessibilityIdentifier("periodicalOCR.photoLibrary")
            }
        }
    }

    private var processingContent: some View {
        VStack(alignment: .leading, spacing: LibrarySpacing.large) {
            EditorialStatusBand(
                title: "Czytam okładkę",
                message: "Szukam oznaczeń numeru, tomu i daty po polsku, angielsku lub niemiecku.",
                icon: "text.viewfinder"
            )
            ProgressView()
                .tint(LibraryPalette.orangeText)
                .controlSize(.large)
                .frame(maxWidth: .infinity, minHeight: 80)
                .accessibilityLabel("Rozpoznawanie tekstu z okładki")

            EditorialSecondaryButton(title: "Przerwij", icon: "xmark") {
                recognitionTask?.cancel()
                phase = .source
            }
        }
    }

    private func resultContent(_ suggestions: PeriodicalIssueTextSuggestions) -> some View {
        VStack(alignment: .leading, spacing: LibrarySpacing.large) {
            EditorialStatusBand(
                title: hasAnySuggestion(suggestions) ? "Sprawdź propozycje" : "Nie znalazłem numeru ani daty",
                message: hasAnySuggestion(suggestions)
                    ? "Porównaj odczyt z okładką. Zaznaczone wartości zostaną wpisane dopiero po użyciu przycisku poniżej."
                    : "Spróbuj ponownie w lepszym świetle i obejmij cały tytuł, numer oraz datę.",
                icon: hasAnySuggestion(suggestions) ? "checkmark" : "questionmark"
            )

            if hasAnySuggestion(suggestions) {
                VStack(alignment: .leading, spacing: 0) {
                    EditorialSectionHeader(title: "Odczytane dane", value: "DO POTWIERDZENIA")

                    if let suggestion = suggestions.issueNumber {
                        suggestionRow(
                            label: "Numer",
                            suggestion: suggestion,
                            occupied: !existingIssueNumber.trimmedForOCR.isEmpty,
                            selection: $useIssueNumber
                        )
                    }
                    if let suggestion = suggestions.issueVolume {
                        suggestionRow(
                            label: "Tom / rocznik",
                            suggestion: suggestion,
                            occupied: !existingIssueVolume.trimmedForOCR.isEmpty,
                            selection: $useIssueVolume
                        )
                    }
                    if let suggestion = suggestions.issueDate {
                        suggestionRow(
                            label: "Data numeru",
                            suggestion: suggestion,
                            occupied: !existingIssueDate.trimmedForOCR.isEmpty,
                            selection: $useIssueDate
                        )
                    }
                }

                EditorialPrimaryButton(title: "Zastosuj zaznaczone", icon: "checkmark") {
                    apply(suggestions)
                }
                .disabled(!hasApplicableSelection(suggestions))
                .opacity(hasApplicableSelection(suggestions) ? 1 : 0.5)
                .accessibilityIdentifier("periodicalOCR.apply")
            }

            EditorialSecondaryButton(title: "Zrób lub wybierz inne zdjęcie", icon: "arrow.clockwise") {
                resetToSource()
            }
        }
    }

    private func failureContent(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: LibrarySpacing.large) {
            EditorialStatusBand(
                title: "Nie udało się odczytać okładki",
                message: message,
                icon: "exclamationmark.triangle",
                accent: LibraryPalette.orangeText
            )
            EditorialPrimaryButton(title: "Spróbuj ponownie", icon: "arrow.clockwise") {
                resetToSource()
            }
        }
    }

    private func suggestionRow(
        label: String,
        suggestion: PeriodicalIssueTextSuggestion,
        occupied: Bool,
        selection: Binding<Bool>
    ) -> some View {
        Button {
            guard !occupied else { return }
            selection.wrappedValue.toggle()
        } label: {
            HStack(alignment: .top, spacing: LibrarySpacing.medium) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(label.uppercased())
                        .font(.caption2.weight(.bold))
                        .tracking(1.35)
                        .foregroundStyle(LibraryPalette.orangeText)
                    Text(suggestion.value)
                        .font(.system(.title3, design: .serif, weight: .bold))
                        .fixedSize(horizontal: false, vertical: true)
                    Text(occupied
                        ? "Pole jest już uzupełnione — aplikacja go nie nadpisze."
                        : "Odczyt: „\(suggestion.evidence)” · pewność \(Int((suggestion.confidence * 100).rounded()))%")
                        .font(.system(.footnote, design: .serif))
                        .lineSpacing(2)
                        .foregroundStyle(LibraryPalette.mutedInk)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: LibrarySpacing.small)
                Image(systemName: occupied ? "lock" : (selection.wrappedValue ? "checkmark.circle.fill" : "circle"))
                    .font(.title3)
                    .foregroundStyle(occupied ? LibraryPalette.mutedInk : LibraryPalette.orangeText)
                    .accessibilityHidden(true)
            }
            .foregroundStyle(LibraryPalette.ink)
            .padding(.vertical, LibrarySpacing.medium)
            .frame(maxWidth: .infinity, minHeight: 72, alignment: .leading)
            .overlay(alignment: .top) {
                Rectangle().fill(LibraryPalette.rule).frame(height: 1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(occupied)
        .accessibilityLabel(
            occupied
                ? "\(label): pole już uzupełnione"
                : "\(label): \(suggestion.value), \(selection.wrappedValue ? "zaznaczone" : "niezaznaczone")"
        )
        .accessibilityHint(occupied ? "Wartość nie zostanie nadpisana" : "Przełącza zastosowanie propozycji")
    }

    private func processCameraImage(_ image: UIImage) {
        recognitionTask?.cancel()
        recognitionTask = Task {
            phase = .processing
            do {
                let preparedData = try await Task.detached(priority: .userInitiated) {
                    try PeriodicalCoverImagePreprocessor.prepare(image)
                }.value
                try await recognizePreparedImage(preparedData)
            } catch is CancellationError {
                return
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
    }

    private func processImageData(_ rawData: Data) async {
        phase = .processing
        do {
            let preparedData = try await Task.detached(priority: .userInitiated) {
                try PeriodicalCoverImagePreprocessor.prepare(rawData)
            }.value
            try await recognizePreparedImage(preparedData)
        } catch is CancellationError {
            return
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    private func recognizePreparedImage(_ preparedData: Data) async throws {
        let lines = try await service.recognizeText(in: preparedData)
        try Task.checkCancellation()
        let suggestions = PeriodicalIssueTextParser.parse(lines)
        useIssueNumber = suggestions.issueNumber != nil && existingIssueNumber.trimmedForOCR.isEmpty
        useIssueVolume = suggestions.issueVolume != nil && existingIssueVolume.trimmedForOCR.isEmpty
        useIssueDate = suggestions.issueDate != nil && existingIssueDate.trimmedForOCR.isEmpty
        phase = .result(suggestions)
        UIAccessibility.post(
            notification: .announcement,
            argument: hasAnySuggestion(suggestions)
                ? "Odczyt zakończony. Sprawdź propozycje."
                : "Nie znaleziono numeru ani daty na okładce."
        )
    }

    private func hasAnySuggestion(_ suggestions: PeriodicalIssueTextSuggestions) -> Bool {
        suggestions.issueNumber != nil || suggestions.issueVolume != nil || suggestions.issueDate != nil
    }

    private func hasApplicableSelection(_ suggestions: PeriodicalIssueTextSuggestions) -> Bool {
        (useIssueNumber && suggestions.issueNumber != nil && existingIssueNumber.trimmedForOCR.isEmpty) ||
            (useIssueVolume && suggestions.issueVolume != nil && existingIssueVolume.trimmedForOCR.isEmpty) ||
            (useIssueDate && suggestions.issueDate != nil && existingIssueDate.trimmedForOCR.isEmpty)
    }

    private func apply(_ suggestions: PeriodicalIssueTextSuggestions) {
        let selection = PeriodicalCoverOCRSelection(
            issueNumber: useIssueNumber && existingIssueNumber.trimmedForOCR.isEmpty
                ? suggestions.issueNumber?.value
                : nil,
            issueVolume: useIssueVolume && existingIssueVolume.trimmedForOCR.isEmpty
                ? suggestions.issueVolume?.value
                : nil,
            issueDate: useIssueDate && existingIssueDate.trimmedForOCR.isEmpty
                ? suggestions.issueDate?.value
                : nil
        )
        guard !selection.isEmpty else { return }
        onApply(selection)
        dismiss()
    }

    private func resetToSource() {
        recognitionTask?.cancel()
        photoItem = nil
        useIssueNumber = false
        useIssueVolume = false
        useIssueDate = false
        phase = .source
    }
}

private struct PeriodicalCameraCapture: UIViewControllerRepresentable {
    @Binding var isPresented: Bool
    let onImage: (UIImage) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let controller = UIImagePickerController()
        controller.sourceType = .camera
        controller.cameraCaptureMode = .photo
        controller.allowsEditing = false
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    final class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate {
        private let parent: PeriodicalCameraCapture

        init(parent: PeriodicalCameraCapture) {
            self.parent = parent
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.isPresented = false
        }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            guard let image = info[.originalImage] as? UIImage else {
                parent.isPresented = false
                return
            }
            parent.onImage(image)
            parent.isPresented = false
        }
    }
}

private enum PeriodicalCoverImageError: Error, LocalizedError {
    case tooLarge
    case unreadable

    var errorDescription: String? {
        switch self {
        case .tooLarge: "Zdjęcie jest zbyt duże do bezpiecznego przetworzenia."
        case .unreadable: "Nie udało się przygotować zdjęcia okładki."
        }
    }
}

private enum PeriodicalCoverImagePreprocessor {
    static let maximumSourceBytes = 40 * 1_024 * 1_024
    private static let maximumDimension = 4_096
    private static let maximumSourcePixels = 50_000_000

    static func prepare(_ data: Data) throws -> Data {
        guard !data.isEmpty else { throw PeriodicalCoverImageError.unreadable }
        guard data.count <= maximumSourceBytes else { throw PeriodicalCoverImageError.tooLarge }
        guard let source = CGImageSourceCreateWithData(
            data as CFData,
            [kCGImageSourceShouldCache: false] as CFDictionary
        ) else {
            throw PeriodicalCoverImageError.unreadable
        }
        guard let properties = CGImageSourceCopyPropertiesAtIndex(
            source,
            0,
            [kCGImageSourceShouldCache: false] as CFDictionary
        ) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.int64Value,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.int64Value,
              width > 0,
              height > 0 else {
            throw PeriodicalCoverImageError.unreadable
        }
        let (pixelCount, overflow) = width.multipliedReportingOverflow(by: height)
        guard !overflow, pixelCount <= Int64(maximumSourcePixels) else {
            throw PeriodicalCoverImageError.tooLarge
        }
        guard let image = CGImageSourceCreateThumbnailAtIndex(
            source,
            0,
            [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maximumDimension,
                kCGImageSourceShouldCacheImmediately: true
            ] as CFDictionary
        ) else {
            throw PeriodicalCoverImageError.unreadable
        }

        let result = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            result,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            throw PeriodicalCoverImageError.unreadable
        }
        CGImageDestinationAddImage(
            destination,
            image,
            [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary
        )
        guard CGImageDestinationFinalize(destination) else {
            throw PeriodicalCoverImageError.unreadable
        }
        return result as Data
    }

    /// Camera capture already arrives as a decoded UIImage. Redraw it directly
    /// into a bounded, metadata-free bitmap before JPEG encoding so a full
    /// resolution `jpegData` allocation never happens on the main actor.
    static func prepare(_ image: UIImage) throws -> Data {
        let pixelWidth = Int64((image.size.width * image.scale).rounded(.up))
        let pixelHeight = Int64((image.size.height * image.scale).rounded(.up))
        guard pixelWidth > 0, pixelHeight > 0 else {
            throw PeriodicalCoverImageError.unreadable
        }
        let (pixelCount, overflow) = pixelWidth.multipliedReportingOverflow(by: pixelHeight)
        guard !overflow, pixelCount <= Int64(maximumSourcePixels) else {
            throw PeriodicalCoverImageError.tooLarge
        }

        let longestSide = max(image.size.width, image.size.height)
        let ratio = longestSide > CGFloat(maximumDimension)
            ? CGFloat(maximumDimension) / longestSide
            : 1
        let targetSize = CGSize(
            width: max(1, floor(image.size.width * ratio)),
            height: max(1, floor(image.size.height * ratio))
        )
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let rendered = UIGraphicsImageRenderer(size: targetSize, format: format).image { context in
            UIColor.white.setFill()
            context.cgContext.fill(CGRect(origin: .zero, size: targetSize))
            image.draw(in: CGRect(origin: .zero, size: targetSize))
        }
        guard let data = rendered.jpegData(compressionQuality: 0.82),
              data.count <= PeriodicalCoverOCRService.Configuration.maximumAllowedInputBytes else {
            throw PeriodicalCoverImageError.tooLarge
        }
        return data
    }
}

/// Requests a file-backed PhotosPicker transfer, checks its size before
/// materializing bytes and caps the read even if the provider reports a wrong
/// file size. This keeps the input boundary bounded before ImageIO is invoked.
private struct PeriodicalPhotoTransfer: Transferable, Sendable {
    let data: Data

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .image) { received in
            let values = try received.file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard values.isRegularFile != false,
                  (values.fileSize ?? 0) <= PeriodicalCoverImagePreprocessor.maximumSourceBytes else {
                throw PeriodicalCoverImageError.tooLarge
            }

            let handle = try FileHandle(forReadingFrom: received.file)
            defer { try? handle.close() }
            let bounded = try handle.read(
                upToCount: PeriodicalCoverImagePreprocessor.maximumSourceBytes + 1
            ) ?? Data()
            guard bounded.count <= PeriodicalCoverImagePreprocessor.maximumSourceBytes else {
                throw PeriodicalCoverImageError.tooLarge
            }
            return PeriodicalPhotoTransfer(data: bounded)
        }
    }
}

private extension String {
    var trimmedForOCR: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
