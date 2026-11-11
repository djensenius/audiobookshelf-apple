/// Starts playing a library item or podcast episode. Screens call it through an environment value
/// (`playItem`, `nil` while signed out) instead of holding the playback coordinator.
///
/// The app shell builds it over `PlaybackCoordinator.play(itemID:episodeID:startTime:allowingMeteredNetwork:)`
/// for the signed-in account; a test or preview passes any closure.
@MainActor
public struct PlayItemAction: Sendable {
    private let action: @MainActor @Sendable (_ itemID: String, _ episodeID: String?) async throws -> Void

    /// - Parameter action: Plays the item with the given ID, or its episode when one is given.
    public init(_ action: @escaping @MainActor @Sendable (_ itemID: String, _ episodeID: String?) async throws -> Void)
    {
        self.action = action
    }

    /// Plays the item, or its episode when `episodeID` is given.
    public func callAsFunction(itemID: String, episodeID: String? = nil) async throws {
        try await action(itemID, episodeID)
    }
}
