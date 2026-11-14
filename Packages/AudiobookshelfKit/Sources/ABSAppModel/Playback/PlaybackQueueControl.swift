import ABSData
import ABSPlayback
import Foundation
import Observation

/// One account session's play queue, as the queue sheet (#156) and "play all" (#354) use it:
/// read-only ``items``, observable as the scope's ``PlaybackQueue``'s, and the changes they make.
/// ``PlaybackSessionParticipant/queue`` publishes one per session.
///
/// The changes go through the scope that owns the queue, so they stop once it retires: a
/// control kept from an earlier session never changes a queue again, and never another
/// account's.
@MainActor
public final class PlaybackQueueControl: PlaybackQueueReading, PlayAllQueueing {
    public let serverConnectionID: UUID
    private let reader: any PlaybackQueueReading
    private weak var scope: (any PlaybackScopeHandle)?
    /// The newest ``beginPlayAll()``'s ID, shared by every window of the session.
    private var playAllRequests = 0
    /// How often, and how long, ``replace(with:afterStarting:request:)`` checks a pending start.
    var startPollInterval: Duration = .milliseconds(100)
    var startTimeout: Duration = .seconds(60)

    /// `nil` when the scope has no queue.
    init?(scope: any PlaybackScopeHandle) {
        guard let reader = scope.queue else { return nil }
        self.reader = reader
        self.scope = scope
        serverConnectionID = reader.serverConnectionID
    }

    public var items: [QueueItem] { reader.items }

    /// The media the scope's player has loaded (playing, paused or restored); `nil` once the scope
    /// is gone.
    public var currentMediaKey: MediaKey? { scope?.playback.mediaKey }

    /// Puts `item` first, so it plays after the current one; moves it if it's already queued.
    public func playNext(_ item: QueueItem) {
        scope?.editQueue { $0.playNext(item) }
    }

    /// Puts `item` last; moves it if it's already queued.
    public func addToEnd(_ item: QueueItem) {
        scope?.editQueue { $0.addToEnd(item) }
    }

    public func remove(id: QueueItem.ID) {
        scope?.editQueue { $0.remove(id: id) }
    }

    public func remove(atOffsets offsets: IndexSet) {
        scope?.editQueue { $0.remove(atOffsets: offsets) }
    }

    /// Moves the items at `source` to just before the item at `destination`, like SwiftUI's `onMove`.
    public func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        scope?.editQueue { $0.move(fromOffsets: source, toOffset: destination) }
    }

    public func clear() {
        scope?.editQueue { $0.clear() }
    }

    public func beginPlayAll() -> PlayAllRequest {
        playAllRequests += 1
        let playback = scope?.playback
        return PlayAllRequest(
            id: playAllRequests, startGeneration: playback?.startGeneration ?? 0,
            playRequest: playback?.playRequestCount ?? 0)
    }

    /// Replaces the queue with `items`, in order, once the start of `started` has succeeded (play-all, #354): it is
    /// the loaded media, without an error. A start still pending (`.starting`, as when another screen began it and
    /// the player's `play` returned at once), or recovering (``PlayerPlaybackControlling/isRecovering``, as before a
    /// direct play's HLS fallback), is waited for, checking every ``startPollInterval`` for up to ``startTimeout``.
    /// Only the play the play-all's own play joined or began counts, held from here on: the start under way at
    /// ``beginPlayAll()`` (the same ``PlayerPlaybackControlling/startGeneration``), or the one its play began
    /// (``PlayerPlaybackControlling/startPlayRequest`` is the play request after the request's). Recovery's rebuilds
    /// keep that play's request, so they count; a start another play began, even of the same media, or one begun
    /// after a stop, doesn't.
    /// The current media isn't queued (``isCurrent(_:)``).
    ///
    /// - Returns: `false`, leaving the queue as it was, when a newer ``beginPlayAll()`` has begun, `started` is
    ///   another connection's, the start failed, was cancelled, timed out, stopped or was replaced by another start,
    ///   the caller was cancelled, or the session's scope is gone or has retired.
    @discardableResult
    public func replace(with items: [QueueItem], afterStarting started: MediaKey, request: PlayAllRequest) async
        -> Bool
    {
        guard started.serverConnectionID == serverConnectionID, let current = scope?.playback,
            current.startGeneration == request.startGeneration
                || current.startPlayRequest == request.playRequest + 1
        else { return false }
        // The play: by its request, which recovery's rebuilds keep; by its start when no play began it.
        let play = current.startPlayRequest
        let generation = current.startGeneration
        func isSamePlay(_ playback: any PlayerPlaybackControlling) -> Bool {
            if let play { playback.startPlayRequest == play } else { playback.startGeneration == generation }
        }
        let deadline = ContinuousClock.now + startTimeout
        while request.id == playAllRequests, let playback = scope?.playback, isSamePlay(playback),
            playback.mediaKey == started, playback.error == nil,
            playback.phase == .starting || (playback.phase == .unloaded && playback.isRecovering)
        {
            guard ContinuousClock.now < deadline, (try? await Task.sleep(for: startPollInterval)) != nil else {
                return false
            }
        }
        guard !Task.isCancelled, request.id == playAllRequests, let playback = scope?.playback,
            isSamePlay(playback), playback.mediaKey == started, playback.error == nil, playback.phase == .loaded
        else { return false }
        return edit { $0.replace(with: items.filter { !isCurrent($0) }) }
    }

    /// Applies `change` through the scope; `false` when it wasn't applied, because the scope is
    /// gone or has retired.
    func edit(_ change: (PlaybackQueue) -> Void) -> Bool {
        var applied = false
        scope?.editQueue {
            change($0)
            applied = true
        }
        return applied
    }
}
