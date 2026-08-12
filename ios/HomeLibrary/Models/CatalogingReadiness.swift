import Foundation

enum CatalogingReadinessFailure: Equatable, Sendable {
    case missingShelf
    case missingTitle
    case missingPeriodicalIssue

    var message: String {
        switch self {
        case .missingShelf:
            return "Wybierz bieżącą półkę przed rozpoczęciem seryjnego katalogowania."
        case .missingTitle:
            return "Tytuł jest wymagany. Katalogi ISBN nie uzupełniają automatycznie tytułów prasy."
        case .missingPeriodicalIssue:
            return "Uzupełnij numer, datę albo dodatek EAN, aby zapisać konkretny numer prasy."
        }
    }
}

/// Pure validation shared by the editorial form and tests. It deliberately
/// keeps manual one-off entries permissive while making a shelf session and a
/// concrete periodical issue explicit.
enum CatalogingReadiness {
    static func failure(
        serialMode: Bool,
        locationText: String,
        publicationType: PublicationType,
        title: String,
        hasExistingPublicationMatch: Bool,
        issueNumber: String,
        issueDate: String,
        eanSupplement: String
    ) -> CatalogingReadinessFailure? {
        if serialMode, LocationPath(locationText).isEmpty {
            return .missingShelf
        }

        if !hasExistingPublicationMatch,
           title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .missingTitle
        }

        if publicationType == .periodical,
           !hasExistingPublicationMatch,
           issueNumber.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           issueDate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           eanSupplement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .missingPeriodicalIssue
        }

        return nil
    }

    static func canStartShelfSession(locationText: String) -> Bool {
        !LocationPath(locationText).isEmpty
    }
}
