import SwiftData
import SwiftUI

@main
struct HomeLibraryApp: App {
    private let modelContainer: ModelContainer = {
        let schema = Schema([
            Publication.self,
            OwnedItem.self
        ])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)

        do {
            return try ModelContainer(for: schema, configurations: [configuration])
        } catch {
            fatalError("Nie udało się utworzyć bazy SwiftData: \(error)")
        }
    }()

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(modelContainer)
    }
}
