import Foundation

/// Transient state shared by consecutive saves while cataloging one shelf.
struct CatalogingSession: Equatable, Sendable {
    struct LastSaved: Equatable, Sendable {
        let itemID: UUID
        let savedAt: Date
        let location: LocationPath
    }

    /// Editable value. It remains exactly as typed until `commitLocation()`.
    private(set) var locationText: String

    /// Last committed, normalized location.
    private(set) var canonicalLocation: LocationPath

    private(set) var savedCount: Int
    private(set) var lastSaved: LastSaved?

    init(locationText: String = "") {
        let initialLocation = LocationPath(locationText)
        self.locationText = initialLocation.canonical
        canonicalLocation = initialLocation
        savedCount = 0
        lastSaved = nil
    }

    mutating func updateLocationText(_ text: String) {
        locationText = text
    }

    /// Commits the editor contents and returns the normalized path.
    @discardableResult
    mutating func commitLocation() -> LocationPath {
        let location = LocationPath(locationText)
        canonicalLocation = location
        locationText = location.canonical
        return location
    }

    /// Records a successful save without ending the shelf session. The current
    /// location is committed once and retained for the next publication.
    @discardableResult
    mutating func recordSaved(
        itemID: UUID,
        savedAt: Date = .now
    ) -> LastSaved {
        let location = commitLocation()
        savedCount += 1

        let saved = LastSaved(
            itemID: itemID,
            savedAt: savedAt,
            location: location
        )
        lastSaved = saved
        return saved
    }

    mutating func reset() {
        self = CatalogingSession()
    }
}
