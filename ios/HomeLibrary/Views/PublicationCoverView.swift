import SwiftUI
import UIKit

/// Okładka publikacji oparta wyłącznie na prawdziwym obrazie z lokalnego cache
/// lub z zaufanego źródła obsługiwanego przez `CoverImageStore`.
struct PublicationCoverView: View {
    enum Mode: Hashable {
        /// Wiersze kolekcji nigdy nie uruchamiają pobierania z sieci.
        case thumbnail
        /// Elastyczna okładka kafelka kolekcji. Uzupełnia trwały cache na miss.
        case collection
        /// Podgląd podczas rozpoznawania publikacji może pobrać obraz.
        case lookup
        /// Duża okładka na karcie publikacji może pobrać obraz.
        case detail

        fileprivate var allowsNetwork: Bool {
            self != .thumbnail
        }

        fileprivate var showsSource: Bool {
            self == .lookup || self == .detail
        }
    }

    let url: URL?
    let title: String
    let source: String?
    let mode: Mode

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var phase = Phase.idle
    @State private var retryGeneration = 0

    init(
        url: URL?,
        title: String,
        source: String? = nil,
        mode: Mode
    ) {
        self.url = url
        self.title = title
        self.source = source
        self.mode = mode
    }

    var body: some View {
        Group {
            if mode == .thumbnail {
                thumbnail
            } else if mode == .collection {
                collectionCover
            } else {
                fullCover
            }
        }
        .task(id: requestID) {
            await loadCover()
        }
    }

    @ViewBuilder
    private var thumbnail: some View {
        if case .loaded(let image) = phase {
            coverCanvas {
                coverImage(image)
            }
            .accessibilityHidden(true)
        } else {
            Color.clear
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private var collectionCover: some View {
        if case .loaded(let image) = phase {
            coverCanvas {
                coverImage(image)
            }
            .accessibilityLabel("Okładka publikacji \(displayTitle)")
        } else {
            // Kafelek kolekcji ma własny editorial fallback. Przezroczysta
            // warstwa zachowuje geometrię i pozwala mu pozostać widocznym,
            // dopóki prawdziwa okładka nie trafi do cache.
            Color.clear
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .aspectRatio(3 / 4.15, contentMode: .fit)
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private var fullCover: some View {
        if case .unavailable = phase {
            if mode == .lookup {
                Text("Brak okładki w katalogu")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(LibraryPalette.mutedInk)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .accessibilityLabel("Brak okładki publikacji \(displayTitle)")
            }
        } else {
            VStack(alignment: .leading, spacing: LibrarySpacing.xSmall) {
                coverCanvas {
                    fullCoverContent
                }

                if mode.showsSource, phase.isLoaded, let sourceCaption {
                    Text(sourceCaption)
                        .font(.caption2.weight(.bold))
                        .tracking(1.25)
                        .foregroundStyle(LibraryPalette.mutedInk)
                        .accessibilityHidden(true)
                }
            }
        }
    }

    @ViewBuilder
    private var fullCoverContent: some View {
        switch phase {
        case .idle, .loading:
            ProgressView()
                .tint(LibraryPalette.orangeText)
                .controlSize(mode == .detail ? .regular : .small)
                .accessibilityLabel("Pobieranie okładki publikacji \(displayTitle)")

        case .loaded(let image):
            coverImage(image)
                .accessibilityLabel("Okładka publikacji \(displayTitle)")
                .accessibilityValue(accessibleSource)

        case .unavailable:
            Text("Brak okładki")
                .font(.caption.weight(.semibold))
                .foregroundStyle(LibraryPalette.mutedInk)
                .multilineTextAlignment(.center)
                .padding(LibrarySpacing.xSmall)
                .accessibilityLabel("Brak okładki publikacji \(displayTitle)")

        case .failed:
            VStack(spacing: LibrarySpacing.xSmall) {
                Text("Nie udało się pobrać okładki")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(LibraryPalette.mutedInk)
                    .multilineTextAlignment(.center)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 2)

                Button("Ponów") {
                    retryGeneration += 1
                }
                .buttonStyle(.plain)
                .font(.caption.weight(.bold))
                .foregroundStyle(LibraryPalette.ink)
                .frame(minWidth: 44, minHeight: 44)
                .padding(.horizontal, LibrarySpacing.xSmall)
                .overlay {
                    RoundedRectangle(cornerRadius: 3)
                        .stroke(LibraryPalette.controlBorder, lineWidth: 1)
                }
                .contentShape(Rectangle())
                .accessibilityLabel("Ponów pobieranie okładki publikacji \(displayTitle)")
            }
            .padding(LibrarySpacing.xSmall)
        }
    }

    private func coverCanvas<Content: View>(
        @ViewBuilder content: () -> Content
    ) -> some View {
        Group {
            if mode == .collection {
                content()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .aspectRatio(3 / 4.15, contentMode: .fit)
            } else {
                content()
                    .frame(width: coverWidth, height: coverHeight)
            }
        }
            .background(LibraryPalette.warmPaper)
            .clipShape(RoundedRectangle(cornerRadius: 3))
            .overlay {
                RoundedRectangle(cornerRadius: 3)
                    .stroke(LibraryPalette.controlBorder, lineWidth: 1)
            }
            .shadow(
                color: mode == .detail ? LibraryPalette.ink.opacity(0.16) : .clear,
                radius: mode == .detail ? 10 : 0,
                x: 0,
                y: mode == .detail ? 5 : 0
            )
    }

    private func coverImage(_ image: UIImage) -> some View {
        Image(uiImage: image)
            .resizable()
            .interpolation(.high)
            .antialiased(true)
            .scaledToFit()
            .modifier(CoverImageFrame(mode: mode, width: coverWidth, height: coverHeight))
    }

    private var coverWidth: CGFloat {
        switch mode {
        case .thumbnail:
            return horizontalSizeClass == .regular ? 72 : 58
        case .collection:
            return 0
        case .lookup:
            if dynamicTypeSize.isAccessibilitySize {
                return 132
            }
            return horizontalSizeClass == .regular ? 104 : 88
        case .detail:
            return horizontalSizeClass == .regular && !dynamicTypeSize.isAccessibilitySize ? 260 : 210
        }
    }

    private var coverHeight: CGFloat {
        coverWidth * 4.15 / 3
    }

    private var requestID: RequestID {
        RequestID(url: url, mode: mode, retryGeneration: retryGeneration)
    }

    @MainActor
    private func loadCover() async {
        guard let url else {
            phase = .unavailable
            return
        }
        guard let store = PublicationCoverStore.shared else {
            phase = mode == .thumbnail ? .unavailable : .failed
            return
        }

        if mode.allowsNetwork {
            phase = .loading
        } else {
            phase = .idle
        }

        do {
            let payload: CoverImagePayload?
            if mode.allowsNetwork {
                payload = try await store.image(for: url)
            } else {
                payload = try await store.cachedImage(for: url)
            }

            try Task.checkCancellation()
            guard let payload else {
                phase = .unavailable
                return
            }
            guard let image = UIImage(data: payload.data) else {
                phase = mode == .thumbnail ? .unavailable : .failed
                return
            }
            phase = .loaded(image)
        } catch is CancellationError {
            return
        } catch {
            phase = mode == .thumbnail ? .unavailable : .failed
        }
    }

    private var displayTitle: String {
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty ? "bez tytułu" : clean
    }

    private var sourceCaption: String? {
        guard let source = source?.trimmingCharacters(in: .whitespacesAndNewlines),
              !source.isEmpty else {
            return nil
        }

        if source.lowercased() == BookMetadataSource.openLibrary.rawValue {
            return "OKŁADKA · OPEN LIBRARY"
        }
        return "OKŁADKA · \(source.uppercased())"
    }

    private var accessibleSource: String {
        guard let sourceCaption else { return "" }
        return sourceCaption.replacingOccurrences(of: " · ", with: ", ").lowercased()
    }
}

private enum PublicationCoverStore {
    /// Awaria inicjalizacji cache nie może uniemożliwić uruchomienia aplikacji.
    static let shared: CoverImageStore? = try? CoverImageStore()
}

private extension PublicationCoverView {
    enum Phase {
        case idle
        case loading
        case loaded(UIImage)
        case unavailable
        case failed

        var isLoaded: Bool {
            if case .loaded = self { return true }
            return false
        }
    }

    struct RequestID: Hashable {
        let url: URL?
        let mode: Mode
        let retryGeneration: Int
    }

    struct CoverImageFrame: ViewModifier {
        let mode: Mode
        let width: CGFloat
        let height: CGFloat

        func body(content: Content) -> some View {
            if mode == .collection {
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .aspectRatio(3 / 4.15, contentMode: .fit)
            } else {
                content.frame(width: width, height: height)
            }
        }
    }
}
