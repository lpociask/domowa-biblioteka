import Foundation

/// A normalized, comparable path describing where an owned publication lives.
///
/// The original spelling of every non-empty segment is retained for display,
/// while equality and hashing ignore letter case and Latin diacritics.
struct LocationPath: Codable, Hashable, Sendable {
    let segments: [String]

    init(_ text: String = "") {
        segments = Self.normalizedSegments(from: text)
    }

    init(segments: [String]) {
        self.init(segments.joined(separator: "/"))
    }

    /// Stable form used by persistence and export.
    var canonical: String {
        segments.joined(separator: " / ")
    }

    /// Human-readable form used by the interface.
    var display: String {
        segments.joined(separator: " › ")
    }

    var isEmpty: Bool {
        segments.isEmpty
    }

    /// Stable key suitable for deduplicating locations entered with different
    /// casing or diacritics.
    var deduplicationKey: String {
        comparisonSegments.joined(separator: "/")
    }

    static func == (lhs: LocationPath, rhs: LocationPath) -> Bool {
        lhs.comparisonSegments == rhs.comparisonSegments
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(comparisonSegments)
    }

    private var comparisonSegments: [String] {
        segments.map(Self.comparisonKey(for:))
    }

    private static func normalizedSegments(from text: String) -> [String] {
        text
            .split(whereSeparator: { $0 == "/" || $0 == "›" })
            .map(normalizeWhitespace(in:))
            .filter { !$0.isEmpty }
    }

    private static func normalizeWhitespace(in segment: Substring) -> String {
        segment
            .split(whereSeparator: \Character.isWhitespace)
            .joined(separator: " ")
    }

    private static func comparisonKey(for segment: String) -> String {
        // Foundation's diacritic folding intentionally leaves some Latin
        // letters (for example Polish ł) unchanged. Latin-ASCII handles
        // those consistently before the locale-independent case fold.
        let latinASCII = segment.applyingTransform(
            StringTransform("Latin-ASCII"),
            reverse: false
        ) ?? segment

        return latinASCII.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
    }
}
