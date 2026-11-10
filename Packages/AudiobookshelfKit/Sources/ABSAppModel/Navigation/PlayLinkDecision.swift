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
    ///
    /// A `play/{podcastID}` link without an episode also gives this, with nothing to play:
    /// ``PlayLink`` doesn't know the media type, so the item screen, which does, treats it as
    /// ``openOnly``.
    case confirmPlay(startTime: TimeInterval?)
    /// The item is loaded but paused: ask "Resume *title*?". With a `startTime`, show it
    /// ("from 1:23:45") and resume from there on confirmation; the UI may also offer "Resume at
    /// current position", since the item is already loaded. Without one, resume where it is.
    case confirmResume(startTime: TimeInterval?)

    /// Decides how to handle `link`, given what the shared player has loaded.
    ///
    /// - Parameters:
    ///   - nowPlaying: the media loaded in the player, if any. Only the item and episode are
    ///     compared, not the server connection: ``Router/open(_:)`` sets
    ///     ``Router/pendingPlayLink`` only for the active server, and the playback scope (S8)
    ///     stops playback when the account switches, so loaded media always belongs to it.
    ///   - isPlaying: whether playback is requested (playing or buffering), not paused.
    public static func decide(_ link: PlayLink, nowPlaying: MediaKey?, isPlaying: Bool) -> PlayLinkDecision {
        guard let nowPlaying, nowPlaying.libraryItemId == link.itemID, nowPlaying.episodeId == link.episodeID
        else { return .confirmPlay(startTime: link.startTime) }
        return isPlaying ? .openOnly : .confirmResume(startTime: link.startTime)
    }
}
