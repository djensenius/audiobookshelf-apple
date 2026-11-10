import ABSData
import Foundation

/// What to do with a `play/` link (ADR 0004, "Play links never start playback silently").
///
/// Any app or web page can open a URL, so a play link only ever opens the item screen, and
/// at most asks the user to confirm. Nothing starts, resumes, replaces the session or seeks
/// until the user confirms.
public enum PlayLinkDecision: Hashable, Sendable {
    /// The item (and episode) is already playing: open its screen and nothing else. This
    /// never seeks, even when the link has a start time.
    case openOnly
    /// Ask "Play *title*?", showing the start time ("from 1:23:45") when there is one. On
    /// confirmation, play from `startTime`, or from the saved progress when it's `nil`.
    case confirmPlay(startTime: TimeInterval?)
    /// The item is loaded but paused: ask "Resume *title*?" and resume where it is.
    case confirmResume

    /// Decides how to handle `link`, given what the shared player has loaded.
    ///
    /// - Parameters:
    ///   - nowPlaying: the media loaded in the player, if any. ``Router/open(_:)`` only sets
    ///     ``Router/pendingPlayLink`` for the active server, so the item and episode are
    ///     compared, not the connection.
    ///   - isPlaying: whether that media is playing rather than paused.
    ///
    /// A paused link target with a start time asks to play from that time, since resuming
    /// would ignore it; without one it asks to resume.
    public static func decide(_ link: PlayLink, nowPlaying: MediaKey?, isPlaying: Bool) -> PlayLinkDecision {
        guard let nowPlaying, nowPlaying.libraryItemId == link.itemID, nowPlaying.episodeId == link.episodeID
        else { return .confirmPlay(startTime: link.startTime) }
        if isPlaying { return .openOnly }
        if let startTime = link.startTime { return .confirmPlay(startTime: startTime) }
        return .confirmResume
    }
}
