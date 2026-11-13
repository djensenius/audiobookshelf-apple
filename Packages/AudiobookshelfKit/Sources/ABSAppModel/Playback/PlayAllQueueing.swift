import ABSData
import ABSPlayback
import Foundation

/// One play-all (#354) on a session's queue. Only the newest one may replace the queue.
public struct PlayAllRequest: Sendable, Hashable {
    public let id: Int

    public init(id: Int) {
        self.id = id
    }
}

/// The queue a group's Play replaces after its start (``PlaybackQueueControl``).
@MainActor
public protocol PlayAllQueueing: AnyObject {
    /// Begins a play-all before its start is awaited; any earlier request stops being current.
    func beginPlayAll() -> PlayAllRequest
    /// Replaces the queue with `items` once the start of `started` has succeeded, if `request` is still the newest.
    @discardableResult
    func replace(with items: [QueueItem], afterStarting started: MediaKey, request: PlayAllRequest) async -> Bool
}
