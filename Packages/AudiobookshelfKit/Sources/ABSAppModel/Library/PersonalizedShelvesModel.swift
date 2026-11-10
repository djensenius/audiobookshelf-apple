import ABSCore
import Foundation
import Observation

/// The home page shelves of one library (`GET /api/libraries/:id/personalized`), a port of the
/// shelf loading in the legacy `pages/bookshelf/index.vue`.
@MainActor
@Observable
public final class PersonalizedShelvesModel {
    public let libraryID: String
    /// The shelves in server order; kept while reloading and after a failed reload.
    public private(set) var shelves: [Shelf] = []
    public private(set) var isLoading = false
    /// Shelves have been loaded at least once.
    public private(set) var hasLoaded = false
    /// The error of the last load, cleared by the next successful one.
    public private(set) var error: (any Error)?

    @ObservationIgnored private let client: any LibraryService
    @ObservationIgnored private var sequence = 0

    public init(client: any LibraryService, libraryID: String) {
        self.client = client
        self.libraryID = libraryID
    }

    /// Loads the shelves. When loads overlap, only the last one started is applied.
    public func load() async {
        sequence += 1
        let sequence = sequence
        isLoading = true
        let result: Result<[Shelf], any Error>
        do {
            result = .success(try await client.personalizedShelves(libraryID: libraryID))
        } catch {
            result = .failure(error)
        }
        guard sequence == self.sequence else { return }
        isLoading = false
        switch result {
        case .success(let shelves):
            self.shelves = shelves
            hasLoaded = true
            error = nil
        case .failure(let error):
            if !(error is CancellationError) { self.error = error }
        }
    }
}
