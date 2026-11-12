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
public final class PlaybackQueueControl: PlaybackQueueReading {
    public let serverConnectionID: UUID
    private let reader: any PlaybackQueueReading
    private weak var scope: (any PlaybackScopeHandle)?

    /// `nil` when the scope has no queue.
    init?(scope: any PlaybackScopeHandle) {
        guard let reader = scope.queue else { return nil }
        self.reader = reader
        self.scope = scope
        serverConnectionID = reader.serverConnectionID
    }

    public var items: [QueueItem] { reader.items }

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
}
