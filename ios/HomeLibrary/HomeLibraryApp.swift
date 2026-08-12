import SwiftData
import SwiftUI

@main
struct HomeLibraryApp: App {
    private let pilotMetricsStore = PilotMetricsStore()
    private let modelContainer: ModelContainer = {
        let schema = Schema([
            Publication.self,
            OwnedItem.self
        ])
        let isUITesting = ProcessInfo.processInfo.arguments.contains("-ui-testing")
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: isUITesting)

        do {
            let container = try ModelContainer(for: schema, configurations: [configuration])
#if DEBUG
            HomeLibraryUITestFixture.seedIfRequested(in: container)
#endif
            return container
        } catch {
            fatalError("Nie udało się utworzyć bazy SwiftData: \(error)")
        }
    }()

    var body: some Scene {
        WindowGroup {
            ContentView(pilotMetricsStore: pilotMetricsStore)
        }
        .modelContainer(modelContainer)
    }
}

#if DEBUG
@MainActor
private enum HomeLibraryUITestFixture {
    static func seedIfRequested(in container: ModelContainer) {
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains("-ui-testing"),
              let routeIndex = arguments.firstIndex(of: "-ui-route"),
              arguments.indices.contains(routeIndex + 1),
              ["library-populated", "pilot-dashboard"].contains(arguments[routeIndex + 1]) else {
            return
        }

        let context = container.mainContext
        let fixtures: [(Publication, String, String)] = [
            (
                Publication(
                    type: .book,
                    title: "Sto lat samotności",
                    authorsText: "Gabriel García Márquez",
                    language: "pl",
                    publisher: "Muza",
                    publicationYear: 2024,
                    isbn13: "9788328728646",
                    metadataSource: "nationalLibrary"
                ),
                "Dom / Gabinet / Regał 2 / Półka 3",
                ""
            ),
            (
                Publication(
                    type: .book,
                    title: "The Left Hand of Darkness",
                    authorsText: "Ursula K. Le Guin",
                    language: "en",
                    publisher: "Orbit",
                    publicationYear: 2018,
                    isbn13: "9781473221628",
                    metadataSource: "openLibrary"
                ),
                "Dom / Salon / Regał A",
                "Wydanie angielskie"
            ),
            (
                Publication(
                    type: .periodical,
                    title: "Monocle",
                    language: "en",
                    issn: "1753-2434",
                    ean: "9771753243008",
                    issueNumber: "178",
                    issueDate: "2024-11",
                    metadataSource: "scan"
                ),
                "Dom / Salon / Stolik",
                ""
            ),
            (
                Publication(
                    type: .book,
                    title: "Solaris",
                    authorsText: "Stanisław Lem",
                    language: "pl",
                    publisher: "Wydawnictwo Literackie",
                    publicationYear: 2019,
                    isbn13: "9788308068854",
                    metadataSource: "nationalLibrary"
                ),
                "Dom / Gabinet / Regał 2 / Półka 3",
                ""
            ),
            (
                Publication(
                    type: .periodical,
                    title: "National Geographic Polska",
                    language: "pl",
                    issn: "1507-5966",
                    issueNumber: "8/2026",
                    issueDate: "2026-08",
                    metadataSource: "manual"
                ),
                "Dom / Sypialnia / Półka dolna",
                ""
            ),
            (
                Publication(
                    type: .book,
                    title: "Der Zauberberg",
                    authorsText: "Thomas Mann",
                    language: "de",
                    publisher: "Fischer",
                    publicationYear: 2012,
                    isbn13: "9783596904334",
                    metadataSource: "manual"
                ),
                "Dom / Gabinet / Regał 1",
                "Wersja niemiecka"
            )
        ]

        for (publication, location, notes) in fixtures {
            context.insert(publication)
            context.insert(OwnedItem(
                publication: publication,
                locationPathText: location,
                notes: notes
            ))
        }
        try? context.save()
    }
}
#endif
