import ABSAPI
import ABSCore
import ABSData
import Foundation

/// Identifies one ``BackgroundActivity/begin(name:)``.
public struct BackgroundActivityToken: Sendable, Hashable {
    public let id: UUID

    public init(id: UUID = UUID()) {
        self.id = id
    }
}

/// Keeps the app running while playback work happens with no audio playing, such as starting
/// the next item after one ends on the lock screen. The app backs it with
/// `UIApplication.beginBackgroundTask` on iOS; the package stays UIKit-free.
///
/// Every `begin` is ended exactly once by the caller. An implementation whose system grant expires
/// ends it itself, so `end` must ignore a token it already ended.
@MainActor
public protocol BackgroundActivity: AnyObject, Sendable {
    func begin(name: String) -> BackgroundActivityToken
    func end(_ token: BackgroundActivityToken)
}

/// Holds nothing: the default, and the right choice on macOS, which doesn't suspend the app.
@MainActor
public final class NoBackgroundActivity: BackgroundActivity {
    public init() {}

    public func begin(name: String) -> BackgroundActivityToken { BackgroundActivityToken() }
    public func end(_ token: BackgroundActivityToken) {}
}

/// The next item, with everything a start fetches before `/play` already fetched, so that after
/// the end only `/play` and loading the stream remain.
struct PreparedNextItem: Sendable {
    let key: MediaKey
    let decision: NetworkDecision
    /// The server progress, fetched as a start does (`GET /api/me/progress/…`).
    let serverProgress: Result<MediaProgress?, any Error>
    /// Taken before `serverProgress` was fetched, so admitting it checks local changes since.
    let progressCapture: PlaybackStartProgressCapture?
}

/// Picks and prepares what plays when an item ends (``PlaybackQueueAdvancer``).
@MainActor
protocol NextItemProvider: AnyObject {
    /// The item prepared to follow `key`, or `nil` when there is none ready.
    func preparedNext(after key: MediaKey) -> PreparedNextItem?
    /// Waits for (or starts) the preparation of the item to follow `key`; `nil` stays at the end.
    func prepareNext(after key: MediaKey) async -> PreparedNextItem?
}
