import SwiftUI

/// Wspólny język wizualny aplikacji, przeniesiony z systemu redakcyjnego 5×12.
enum LibraryPalette {
    static let paper = Color(hex: "F4EDDF")
    static let warmPaper = Color(hex: "F0E6D2")
    static let ink = Color(hex: "171713")
    static let mutedInk = Color(hex: "6D685E")
    static let rule = Color.black.opacity(0.24)
    /// Kontrastowa krawędź pól i selektorów; cienkie `rule` służy tylko podziałom treści.
    static let controlBorder = ink.opacity(0.52)
    /// Oryginalny akcent 5×12 — dla dużych plam, reguł i znaków dekoracyjnych.
    static let orange = Color(hex: "DD6B24")
    /// Ciemniejszy wariant dla małego tekstu i ikon (kontrast > 4.5:1 na papierze).
    static let orangeText = Color(hex: "A9470D")
    /// Wariant dla przycisków z białą etykietą (kontrast > 5:1).
    static let orangeAction = Color(hex: "B14E11")
}

enum LibrarySpacing {
    static let xSmall: CGFloat = 6
    static let small: CGFloat = 12
    static let medium: CGFloat = 20
    static let large: CGFloat = 30
    static let xLarge: CGFloat = 44
    static let page: CGFloat = 24
    static let readerWidth: CGFloat = 720
}

enum LibraryRadius {
    static let small: CGFloat = 8
    static let medium: CGFloat = 14
    static let large: CGFloat = 22
}

extension Color {
    init(hex: String) {
        let sanitized = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var value: UInt64 = 0
        Scanner(string: sanitized).scanHexInt64(&value)

        let red: UInt64
        let green: UInt64
        let blue: UInt64
        let alpha: UInt64

        switch sanitized.count {
        case 8:
            red = value >> 24
            green = value >> 16 & 0xFF
            blue = value >> 8 & 0xFF
            alpha = value & 0xFF
        default:
            red = value >> 16
            green = value >> 8 & 0xFF
            blue = value & 0xFF
            alpha = 0xFF
        }

        self.init(
            .sRGB,
            red: Double(red) / 255,
            green: Double(green) / 255,
            blue: Double(blue) / 255,
            opacity: Double(alpha) / 255
        )
    }
}

/// Papierowe tło. Tekstura jest dekoracyjna i nie trafia do drzewa dostępności.
struct PaperBackground: View {
    var color: Color = LibraryPalette.paper

    var body: some View {
        ZStack {
            color
            Image("paper-texture")
                .resizable(resizingMode: .tile)
                .blendMode(.multiply)
                .opacity(0.2)
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}

extension View {
    /// Utrzymuje czytelną szerokość i wspólne 24 pt marginesu na małych ekranach.
    func editorialPage(width: CGFloat = LibrarySpacing.readerWidth) -> some View {
        frame(maxWidth: width)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, LibrarySpacing.page)
    }

    /// Wymusza papierową, jasną prezentację niezależnie od ustawień systemowych.
    func libraryLightAppearance() -> some View {
        preferredColorScheme(.light)
            .tint(LibraryPalette.orangeText)
    }
}
