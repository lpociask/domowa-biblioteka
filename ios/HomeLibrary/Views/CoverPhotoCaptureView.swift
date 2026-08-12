import CoreTransferable
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

enum CoverPhotoCaptureSource: Equatable, Sendable {
    case camera
    case photoLibrary
}

/// Pure presentation state kept separate from picker and image processing APIs.
/// This makes replacement, removal and failure behavior deterministic and easy
/// to exercise without presenting UIKit.
struct CoverPhotoCaptureState: Equatable, Sendable {
    enum Activity: Equatable, Sendable {
        case idle
        case processing(CoverPhotoCaptureSource)
        case failed(String)
    }

    private(set) var hasImage: Bool
    private(set) var activity: Activity = .idle

    init(hasImage: Bool = false) {
        self.hasImage = hasImage
    }

    var isProcessing: Bool {
        if case .processing = activity { return true }
        return false
    }

    var failureMessage: String? {
        guard case .failed(let message) = activity else { return nil }
        return message
    }

    mutating func begin(_ source: CoverPhotoCaptureSource) {
        activity = .processing(source)
    }

    mutating func complete() {
        hasImage = true
        activity = .idle
    }

    mutating func fail(_ message: String) {
        activity = .failed(message)
    }

    mutating func remove() {
        hasImage = false
        activity = .idle
    }

    mutating func dismissFailure() {
        if case .failed = activity {
            activity = .idle
        }
    }
}

enum CoverPhotoCaptureInputError: Error, Equatable, LocalizedError {
    case empty
    case notARegularFile
    case inputTooLarge
    case pixelLimitExceeded
    case encodingFailed

    var errorDescription: String? {
        switch self {
        case .empty:
            "Wybrane zdjęcie jest puste."
        case .notARegularFile:
            "Nie udało się bezpiecznie odczytać wybranego zdjęcia."
        case .inputTooLarge:
            "Zdjęcie jest zbyt duże. Wybierz plik mniejszy niż 12 MB."
        case .pixelLimitExceeded:
            "Zdjęcie ma zbyt dużą rozdzielczość do bezpiecznego przetworzenia."
        case .encodingFailed:
            "Nie udało się przygotować zdjęcia okładki."
        }
    }
}

/// Boundary checks performed before the shared sanitizer decodes source bytes.
enum CoverPhotoCapturePolicy {
    static let maximumTransferBytes = LocalCoverImageProcessor.maxInputByteCount
    static let maximumSourcePixelCount = LocalCoverImageProcessor.maxPixelCount
    static let maximumCameraDimension = LocalCoverImageProcessor.maxDimension

    struct PixelSize: Equatable, Sendable {
        let width: Int
        let height: Int
    }

    static func validateTransfer(byteCount: Int, isRegularFile: Bool? = true) throws {
        guard isRegularFile != false else {
            throw CoverPhotoCaptureInputError.notARegularFile
        }
        guard byteCount > 0 else {
            throw CoverPhotoCaptureInputError.empty
        }
        guard byteCount <= maximumTransferBytes else {
            throw CoverPhotoCaptureInputError.inputTooLarge
        }
    }

    static func cameraTargetSize(pixelWidth: Int, pixelHeight: Int) throws -> PixelSize {
        guard pixelWidth > 0, pixelHeight > 0 else {
            throw CoverPhotoCaptureInputError.empty
        }
        let (pixelCount, overflow) = pixelWidth.multipliedReportingOverflow(by: pixelHeight)
        guard !overflow, pixelCount <= maximumSourcePixelCount else {
            throw CoverPhotoCaptureInputError.pixelLimitExceeded
        }

        let longestSide = max(pixelWidth, pixelHeight)
        guard longestSide > maximumCameraDimension else {
            return PixelSize(width: pixelWidth, height: pixelHeight)
        }

        let scale = Double(maximumCameraDimension) / Double(longestSide)
        return PixelSize(
            width: max(1, Int((Double(pixelWidth) * scale).rounded(.down))),
            height: max(1, Int((Double(pixelHeight) * scale).rounded(.down)))
        )
    }
}

/// Reusable, review-first control for a user-supplied cover photo.
///
/// The callback receives only the metadata-free JPEG returned by
/// `LocalCoverImageProcessor`, or `nil` after an explicit removal. This view
/// does not persist the bytes and is intentionally not wired into a form yet.
struct CoverPhotoCaptureView: View {
    private let existingImageData: Data?
    private let onChange: @MainActor (Data?) -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var previewData: Data?
    @State private var state: CoverPhotoCaptureState
    @State private var photoItem: PhotosPickerItem?
    @State private var showsCamera = false
    @State private var processingTask: Task<Void, Never>?

    init(
        existingImageData: Data? = nil,
        onChange: @escaping @MainActor (Data?) -> Void
    ) {
        self.existingImageData = existingImageData
        self.onChange = onChange
        _previewData = State(initialValue: existingImageData)
        _state = State(initialValue: CoverPhotoCaptureState(hasImage: existingImageData != nil))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: LibrarySpacing.medium) {
            EditorialSectionHeader(
                title: "Zdjęcie okładki",
                value: state.hasImage ? "GOTOWE" : "OPCJONALNE"
            )

            preview

            if state.isProcessing {
                EditorialStatusBand(
                    title: "Przygotowuję okładkę",
                    message: "Zdjęcie jest zmniejszane i czyszczone z metadanych na tym urządzeniu.",
                    icon: "photo.badge.checkmark"
                )
            }

            if let failureMessage = state.failureMessage {
                VStack(alignment: .leading, spacing: LibrarySpacing.xSmall) {
                    EditorialStatusBand(
                        title: "Nie udało się użyć zdjęcia",
                        message: failureMessage,
                        icon: "exclamationmark.triangle",
                        accent: LibraryPalette.orangeText
                    )
                    Button("Zamknij komunikat") {
                        state.dismissFailure()
                    }
                    .buttonStyle(.plain)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(LibraryPalette.orangeText)
                    .frame(minWidth: 44, minHeight: 44, alignment: .leading)
                    .accessibilityIdentifier("coverPhoto.dismissError")
                }
            }

            sourceActions

            Text("Aplikacja zachowa pomniejszony plik JPEG bez danych EXIF i lokalizacji. Oryginalne zdjęcie pozostaje w bibliotece Zdjęć.")
                .font(.system(.footnote, design: .serif))
                .lineSpacing(3)
                .foregroundStyle(LibraryPalette.mutedInk)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel("Prywatność zdjęcia")
                .accessibilityValue("Aplikacja zachowa pomniejszony plik JPEG bez danych EXIF i lokalizacji.")
        }
        .foregroundStyle(LibraryPalette.ink)
        .fullScreenCover(isPresented: $showsCamera) {
            CoverPhotoCameraPicker(
                isPresented: $showsCamera,
                onImage: processCameraImage
            )
            .ignoresSafeArea()
        }
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            processPhotoLibraryItem(item)
        }
        .onChange(of: existingImageData) { _, newData in
            // The periodical OCR sheet can return a sanitized cover to the
            // parent form. Reflect that external update without rebuilding the
            // picker or interrupting an active local conversion.
            guard !state.isProcessing, previewData != newData else { return }
            previewData = newData
            state = CoverPhotoCaptureState(hasImage: newData != nil)
        }
        .onDisappear {
            processingTask?.cancel()
        }
    }

    private var preview: some View {
        ZStack {
            LibraryPalette.warmPaper

            if let previewData, let image = UIImage(data: previewData) {
                Image(uiImage: image)
                    .resizable()
                    .interpolation(.high)
                    .antialiased(true)
                    .scaledToFit()
                    .padding(LibrarySpacing.xSmall)
                    .accessibilityLabel("Wybrane zdjęcie okładki")
            } else {
                VStack(spacing: LibrarySpacing.small) {
                    Image(systemName: "book.closed")
                        .font(.system(size: dynamicTypeSize.isAccessibilitySize ? 32 : 42, weight: .light))
                        .foregroundStyle(LibraryPalette.orangeText)
                        .accessibilityHidden(true)
                    Text("Dodaj własne zdjęcie okładki")
                        .font(.system(.headline, design: .serif, weight: .bold))
                        .multilineTextAlignment(.center)
                    Text("Najlepiej sfotografuj ją na wprost, w równym świetle.")
                        .font(.footnote)
                        .foregroundStyle(LibraryPalette.mutedInk)
                        .multilineTextAlignment(.center)
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 3)
                }
                .padding(LibrarySpacing.medium)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Brak własnego zdjęcia okładki")
            }

            if state.isProcessing {
                LibraryPalette.paper.opacity(0.72)
                ProgressView()
                    .controlSize(.large)
                    .tint(LibraryPalette.orangeText)
                    .accessibilityLabel("Przetwarzanie zdjęcia okładki")
            }
        }
        .aspectRatio(3 / 4.15, contentMode: .fit)
        .frame(maxWidth: previewMaximumWidth)
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipShape(RoundedRectangle(cornerRadius: LibraryRadius.small))
        .overlay {
            RoundedRectangle(cornerRadius: LibraryRadius.small)
                .stroke(LibraryPalette.controlBorder, lineWidth: 1)
        }
    }

    @ViewBuilder
    private var sourceActions: some View {
        VStack(alignment: .leading, spacing: LibrarySpacing.small) {
            if UIImagePickerController.isSourceTypeAvailable(.camera) {
                EditorialPrimaryButton(
                    title: state.hasImage ? "Zrób nowe zdjęcie" : "Zrób zdjęcie",
                    icon: "camera",
                    isLoading: state.isProcessing
                ) {
                    state.dismissFailure()
                    showsCamera = true
                }
                .accessibilityIdentifier("coverPhoto.camera")
            }

            PhotosPicker(selection: $photoItem, matching: .images) {
                HStack(spacing: LibrarySpacing.small) {
                    Text(state.hasImage ? "WYBIERZ INNE ZDJĘCIE" : "WYBIERZ ZDJĘCIE")
                        .font(.subheadline.weight(.bold))
                        .tracking(dynamicTypeSize.isAccessibilitySize ? 0.2 : 1.1)
                        .multilineTextAlignment(.leading)
                    Spacer(minLength: LibrarySpacing.small)
                    Image(systemName: "photo")
                        .font(.headline)
                        .accessibilityHidden(true)
                }
                .foregroundStyle(LibraryPalette.ink)
                .padding(.horizontal, LibrarySpacing.medium)
                .frame(maxWidth: .infinity, minHeight: 56)
                .background(LibraryPalette.paper.opacity(0.72))
                .overlay {
                    RoundedRectangle(cornerRadius: LibraryRadius.small)
                        .stroke(LibraryPalette.controlBorder, lineWidth: 1)
                }
                .contentShape(Rectangle())
            }
            .disabled(state.isProcessing)
            .opacity(state.isProcessing ? 0.55 : 1)
            .accessibilityLabel(state.hasImage ? "Wybierz inne zdjęcie okładki" : "Wybierz zdjęcie okładki")
            .accessibilityIdentifier("coverPhoto.photoLibrary")

            if state.hasImage {
                Button(role: .destructive) {
                    removeImage()
                } label: {
                    HStack(spacing: LibrarySpacing.small) {
                        Text("USUŃ ZDJĘCIE")
                            .font(.subheadline.weight(.bold))
                            .tracking(dynamicTypeSize.isAccessibilitySize ? 0.2 : 1.1)
                        Spacer(minLength: LibrarySpacing.small)
                        Image(systemName: "trash")
                            .font(.headline)
                            .accessibilityHidden(true)
                    }
                    .foregroundStyle(LibraryPalette.orangeText)
                    .padding(.horizontal, LibrarySpacing.medium)
                    .frame(maxWidth: .infinity, minHeight: 56)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(state.isProcessing)
                .accessibilityLabel("Usuń zdjęcie okładki")
                .accessibilityHint("Pozostawia publikację bez własnego zdjęcia okładki")
                .accessibilityIdentifier("coverPhoto.remove")
            }
        }
    }

    private var previewMaximumWidth: CGFloat {
        if horizontalSizeClass == .regular { return 320 }
        return dynamicTypeSize.isAccessibilitySize ? .infinity : 240
    }

    private func processPhotoLibraryItem(_ item: PhotosPickerItem) {
        processingTask?.cancel()
        state.dismissFailure()
        state.begin(.photoLibrary)

        processingTask = Task {
            do {
                guard let transfer = try await item.loadTransferable(type: CoverPhotoPickerTransfer.self) else {
                    throw CoverPhotoCaptureInputError.empty
                }
                let sourceData = transfer.data
                let sanitized = try await Task.detached(priority: .userInitiated) {
                    try LocalCoverImageProcessor.process(sourceData)
                }.value
                try Task.checkCancellation()
                accept(sanitized)
            } catch is CancellationError {
                return
            } catch {
                reject(error)
            }
        }
    }

    private func processCameraImage(_ image: UIImage) {
        processingTask?.cancel()
        state.dismissFailure()
        state.begin(.camera)
        let boxedImage = CoverPhotoUncheckedImage(image)

        processingTask = Task {
            do {
                let sanitized = try await Task.detached(priority: .userInitiated) {
                    let sourceData = try CoverPhotoCameraInputEncoder.encode(boxedImage.value)
                    return try LocalCoverImageProcessor.process(sourceData)
                }.value
                try Task.checkCancellation()
                accept(sanitized)
            } catch is CancellationError {
                return
            } catch {
                reject(error)
            }
        }
    }

    private func accept(_ sanitizedData: Data) {
        previewData = sanitizedData
        photoItem = nil
        state.complete()
        onChange(sanitizedData)
        UIAccessibility.post(notification: .announcement, argument: "Zdjęcie okładki jest gotowe")
    }

    private func reject(_ error: Error) {
        photoItem = nil
        let message = (error as? LocalizedError)?.errorDescription
            ?? "Nie udało się przygotować zdjęcia okładki."
        state.fail(message)
        UIAccessibility.post(notification: .announcement, argument: message)
    }

    private func removeImage() {
        processingTask?.cancel()
        previewData = nil
        photoItem = nil
        state.remove()
        onChange(nil)
        UIAccessibility.post(notification: .announcement, argument: "Usunięto zdjęcie okładki")
    }
}

private struct CoverPhotoCameraPicker: UIViewControllerRepresentable {
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
        private let parent: CoverPhotoCameraPicker

        init(parent: CoverPhotoCameraPicker) {
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

private struct CoverPhotoPickerTransfer: Transferable, Sendable {
    let data: Data

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .image) { received in
            let values = try received.file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            if let fileSize = values.fileSize, fileSize > 0 {
                try CoverPhotoCapturePolicy.validateTransfer(
                    byteCount: fileSize,
                    isRegularFile: values.isRegularFile
                )
            } else if values.isRegularFile == false {
                throw CoverPhotoCaptureInputError.notARegularFile
            }

            let handle = try FileHandle(forReadingFrom: received.file)
            defer { try? handle.close() }
            let data = try handle.read(
                upToCount: CoverPhotoCapturePolicy.maximumTransferBytes + 1
            ) ?? Data()
            try CoverPhotoCapturePolicy.validateTransfer(
                byteCount: data.count,
                isRegularFile: values.isRegularFile
            )
            return CoverPhotoPickerTransfer(data: data)
        }
    }
}

private struct CoverPhotoUncheckedImage: @unchecked Sendable {
    let value: UIImage

    init(_ value: UIImage) {
        self.value = value
    }
}

private enum CoverPhotoCameraInputEncoder {
    static func encode(_ image: UIImage) throws -> Data {
        let pixelWidth = Int((image.size.width * image.scale).rounded(.up))
        let pixelHeight = Int((image.size.height * image.scale).rounded(.up))
        let target = try CoverPhotoCapturePolicy.cameraTargetSize(
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight
        )

        let targetSize = CGSize(width: target.width, height: target.height)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let normalized = UIGraphicsImageRenderer(size: targetSize, format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: targetSize))
            image.draw(in: CGRect(origin: .zero, size: targetSize))
        }
        guard let data = normalized.jpegData(compressionQuality: 0.84) else {
            throw CoverPhotoCaptureInputError.encodingFailed
        }
        try CoverPhotoCapturePolicy.validateTransfer(byteCount: data.count)
        return data
    }
}
