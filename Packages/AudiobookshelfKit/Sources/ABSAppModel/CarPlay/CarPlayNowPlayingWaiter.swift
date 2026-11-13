/// The plays a CarPlay connection waits on to push Now Playing (``CarPlayRootModel/play(_:)``).
///
/// A play is waited on once, so a tap that joins it doesn't push Now Playing twice. A play may
/// outlive its connection: playback goes on, but once the scene disconnects (``disconnect()``)
/// its start shows nothing, not even on a connection made before it ends.
@MainActor
public final class CarPlayNowPlayingWaiter {
    /// The current connection's number; each disconnection starts the next.
    private var connection = 0
    private var waiting: Set<Task<CarPlayPlayOutcome, Never>> = []

    public init() {}

    /// Starts waiting for `play`, on the current connection: the wait says whether to push Now
    /// Playing, which is when it started and its connection is still the current one. `nil` for a
    /// play already waited on.
    public func wait(for play: Task<CarPlayPlayOutcome, Never>) -> Task<Bool, Never>? {
        guard waiting.insert(play).inserted else { return nil }
        let connection = connection
        return Task {
            let outcome = await play.value
            guard connection == self.connection else { return false }
            waiting.remove(play)
            return outcome == .started
        }
    }

    /// The scene disconnected: the plays waited on so far push nothing.
    public func disconnect() {
        connection += 1
        waiting = []
    }
}
