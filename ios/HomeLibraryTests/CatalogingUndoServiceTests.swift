import SwiftData
import XCTest
@testable import HomeLibrary

@MainActor
final class CatalogingUndoServiceTests: XCTestCase {
    func testUndoingOnlyCopyDeletesItemAndPublication() throws {
        let context = try makeContext()
        let publication = Publication(type: .book, title: "Solaris")
        let item = OwnedItem(
            publication: publication,
            locationPathText: "Dom / Gabinet / Regał 2"
        )
        context.insert(publication)
        context.insert(item)
        try context.save()

        let result = try CatalogingUndoService.undo(itemID: item.id, in: context)

        XCTAssertTrue(result.didUndo)
        XCTAssertEqual(result.title, "Solaris")
        XCTAssertEqual(result.location, "Dom / Gabinet / Regał 2")
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<OwnedItem>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Publication>()), 0)
    }

    func testUndoingOneOfTwoCopiesKeepsPublicationAndOtherItem() throws {
        let context = try makeContext()
        let publication = Publication(type: .book, title: "Solaris")
        let removedItem = OwnedItem(
            publication: publication,
            locationPathText: "Dom / Gabinet / Półka 1"
        )
        let retainedItem = OwnedItem(
            publication: publication,
            locationPathText: "Dom / Salon / Półka 2"
        )
        context.insert(publication)
        context.insert(removedItem)
        context.insert(retainedItem)
        try context.save()

        let result = try CatalogingUndoService.undo(itemID: removedItem.id, in: context)
        let remainingItems = try context.fetch(FetchDescriptor<OwnedItem>())
        let remainingPublications = try context.fetch(FetchDescriptor<Publication>())

        XCTAssertTrue(result.didUndo)
        XCTAssertEqual(remainingItems.map(\.id), [retainedItem.id])
        XCTAssertEqual(remainingItems.first?.publication?.persistentModelID, publication.persistentModelID)
        XCTAssertEqual(remainingPublications.map(\.persistentModelID), [publication.persistentModelID])
    }

    func testUnknownItemIDDoesNotChangeCollection() throws {
        let context = try makeContext()
        let publication = Publication(type: .book, title: "Solaris")
        let item = OwnedItem(publication: publication, locationPathText: "Gabinet")
        context.insert(publication)
        context.insert(item)
        try context.save()

        let result = try CatalogingUndoService.undo(itemID: UUID(), in: context)

        XCTAssertFalse(result.didUndo)
        XCTAssertNil(result.title)
        XCTAssertNil(result.location)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<OwnedItem>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Publication>()), 1)
    }

    func testUndoTargetsExactOwnedItemByUUID() throws {
        let context = try makeContext()
        let firstPublication = Publication(type: .book, title: "Ten sam tytuł")
        let secondPublication = Publication(type: .book, title: "Ten sam tytuł")
        let retainedItem = OwnedItem(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            publication: firstPublication,
            locationPathText: "Gabinet / Półka 1"
        )
        let removedItem = OwnedItem(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
            publication: secondPublication,
            locationPathText: "Gabinet / Półka 2"
        )
        context.insert(firstPublication)
        context.insert(secondPublication)
        context.insert(retainedItem)
        context.insert(removedItem)
        try context.save()

        let result = try CatalogingUndoService.undo(itemID: removedItem.id, in: context)
        let remainingItems = try context.fetch(FetchDescriptor<OwnedItem>())
        let remainingPublications = try context.fetch(FetchDescriptor<Publication>())

        XCTAssertTrue(result.didUndo)
        XCTAssertEqual(result.location, "Gabinet / Półka 2")
        XCTAssertEqual(remainingItems.map(\.id), [retainedItem.id])
        XCTAssertEqual(remainingPublications.map(\.persistentModelID), [firstPublication.persistentModelID])
    }

    private func makeContext() throws -> ModelContext {
        let schema = Schema([Publication.self, OwnedItem.self])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        return ModelContext(container)
    }
}
