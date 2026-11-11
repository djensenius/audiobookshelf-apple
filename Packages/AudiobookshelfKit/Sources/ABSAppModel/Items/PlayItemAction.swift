/// Starts playing a library item or podcast episode. Screens call it through an environment value
/// (`playItem`, `nil` while signed out) instead of holding the playback coordinator.
///
/// The app shell builds it over `PlaybackCoordinator.play(itemID:episodeID:startTime:allowingMeteredNetwork:)`
/// for the signed-in account; a test or preview passes any closure.
///
/// Metered-network confirmation isn't surfaced to the caller: `PlaybackCoordinator.play` blocks
/// with `.streamingNeedsConfirmation` and the shell's player owns the confirm-and-retry UI, so a
/// feature doesn't handle it.
@MainActor
public struct PlayItemAction: Sendable {
    public typealias Action =
        @MainActor @Sendable (_ itemID: String, _ episodeID: String?, _ startTime: Double?) async throws -> Void

    private let action: Action

    /// - Parameter action: Plays the item with the given ID, or its episode when one is given,
    ///   from the start time in seconds when one is given.
    public init(_ action: @escaping Action) {
        self.action = action
    }

    /// Plays the item, or its episode when `episodeID` is given. `startTime` is in seconds; `nil`
    /// resumes from the saved progress.
    public func callAsFunction(itemID: String, episodeID: String? = nil, startTime: Double? = nil) async throws {
        try await action(itemID, episodeID, startTime)
    }
}
