import ABSData
import Foundation

extension PlayerViewModel {
    /// The current item's key, loaded or not; `nil` without a session. The full player publishes it
    /// for Handoff (``DeepLink/handoffUserInfo(playing:position:active:)``).
    public var mediaKey: MediaKey? { hasSession ? playback.mediaKey : nil }

    /// The playback position in media seconds, for the Handoff activity; `nil` without a session.
    /// It changes on every playback tick, so read it when the activity is saved, not in a view's
    /// body.
    public var handoffPosition: TimeInterval? { hasSession ? playback.currentTime : nil }

    /// The full player's Handoff `userInfo` for the account `active`, with the current position
    /// (``DeepLink/handoffUserInfo(playing:position:active:)``); `nil` without a session, or when
    /// the playing media isn't `active`'s.
    public func handoffUserInfo(active: ServerConnectionDTO?) -> [String: Any]? {
        mediaKey.flatMap { DeepLink.handoffUserInfo(playing: $0, position: handoffPosition, active: active) }
    }
}
