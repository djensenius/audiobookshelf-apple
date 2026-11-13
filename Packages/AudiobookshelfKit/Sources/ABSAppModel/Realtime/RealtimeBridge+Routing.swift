import ABSCore
import ABSData
import ABSRealtime
import Foundation

extension RealtimeBridge {
    /// Routes the bridge's events into the app's state (#59). Build the bridge over the same
    /// `library`'s ``LibraryStore/progress``.
    ///
    /// - `user_updated` replaces ``AccountManager/authorization``'s user and the session's
    ///   bookmarks.
    /// - Library changes go to ``LibraryStore/applyLibraryChange(_:connectionKey:)``.
    /// - `playback` tells the bridge what the player has open, so echoes of this device's own
    ///   playback sync are recognized, and takes stream resets, which it applies only to its own
    ///   session (``PlaybackCoordinator/handleStreamReset(sessionID:)``).
    /// - `localProgress` takes socket progress for media with a local row (ADR 0003).
    ///
    /// - Parameter bookmarks: The running session's bookmark store, or `nil` between sessions.
    public func route(
        library: LibraryStore, accounts: AccountManager?, bookmarks: @escaping @MainActor () -> BookmarkStore?,
        playback: any PlayerPlaybackControlling, localProgress: LocalProgressStore?
    ) {
        onUserUpdated = { [weak accounts] user in
            accounts?.applyUserUpdate(user)
            bookmarks()?.replaceAll(from: user)
        }
        onLibraryChange = { [weak library] in library?.applyLibraryChange($0, connectionKey: $1) }
        playbackSnapshot = { [weak playback] in playback.flatMap(Self.snapshot(of:)) }
        onStreamReset = { [weak playback] in playback?.handleStreamReset(sessionID: $0.streamId) }
        self.localProgress = localProgress
    }

    /// Reconnects the socket at once when the device moves to another online path, or comes back
    /// online, rather than waiting out its backoff. Runs until `paths` finishes or the calling
    /// task is cancelled; the first path only sets the baseline.
    public func follow(_ paths: AsyncStream<NetworkPath>) async {
        var previous: NetworkPath?
        for await path in paths {
            guard !Task.isCancelled else { return }
            let changed = previous.map { $0 != path } ?? false
            previous = path
            if path.isOnline, changed { await networkChanged() }
        }
    }

    /// What `playback` has open, or `nil` when nothing is.
    static func snapshot(of playback: any PlayerPlaybackControlling) -> RealtimePlaybackSnapshot? {
        guard let key = playback.mediaKey else { return nil }
        return RealtimePlaybackSnapshot(
            libraryItemID: key.libraryItemId, episodeID: key.episodeId, playbackSessionID: playback.session?.id,
            isPlaying: playback.isPlaybackRequested, currentTime: playback.currentTime)
    }
}
