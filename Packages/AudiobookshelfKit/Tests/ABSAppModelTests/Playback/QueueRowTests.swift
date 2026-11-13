import ABSCore
import Foundation
import Testing

@testable import ABSAppModel
@testable import ABSPlayback

/// A queue store that keeps nothing.
@MainActor
private final class NoQueueStore: PlaybackQueueStoring {
    func load(serverConnectionID: UUID) -> [QueueItem] { [] }
    func save(_ items: [QueueItem], serverConnectionID: UUID) {}
    func removeQueue(serverConnectionID: UUID) {}
}

/// Records each play.
@MainActor
private final class Plays {
    var all: [(itemID: String, episodeID: String?, startTime: Double?)] = []
}

@MainActor
@Suite struct QueueRowTests {
    private let connection = UUID()

    private func queue(_ items: QueueItem...) -> PlaybackQueue {
        let queue = PlaybackQueue(serverConnectionID: connection, store: NoQueueStore())
        for item in items { queue.addToEnd(item) }
        return queue
    }

    @Test func rowsFollowTheQueuesOrderAndText() {
        let book = QueueItem(
            libraryItemID: "book", title: "Book", subtitle: "Author", coverPath: "/metadata/items/book/cover.jpg",
            duration: 3600)
        let episode = QueueItem(
            libraryItemID: "podcast", episodeID: "episode", title: "Episode", subtitle: "Podcast",
            coverPath: "https://example.com/cover.jpg", duration: 61)

        let rows = QueueRow.rows(of: queue(episode, book))

        #expect(rows.map(\.id) == [episode.id, book.id])
        #expect(rows.map(\.title) == ["Episode", "Book"])
        #expect(rows.map(\.subtitle) == ["Podcast", "Author"])
        #expect(rows.map(\.duration) == [61, 3600])
        #expect(rows.map(\.isPodcastEpisode) == [true, false])
        // The cover is the item's, on the queue's connection; an absolute path loads from its URL.
        #expect(rows[1].coverKey?.serverID == connection)
        #expect(rows[1].coverKey?.entityID == "book")
        #expect(rows[1].coverKey?.externalURL == nil)
        #expect(rows[0].coverKey?.externalURL == URL(string: "https://example.com/cover.jpg"))
    }

    /// Like the player: no cover without a path, and nothing shown for an empty subtitle or a
    /// zero or unknown duration.
    @Test func missingDetailsShowNothing() {
        let rows = QueueRow.rows(
            of: queue(
                QueueItem(libraryItemID: "a", title: "A", subtitle: "", coverPath: "", duration: 0),
                QueueItem(libraryItemID: "b", title: "B")))

        #expect(rows.map(\.subtitle) == [nil, nil])
        #expect(rows.map(\.duration) == [nil, nil])
        #expect(rows.map(\.coverKey) == [nil, nil])
    }

    @Test func rowsTrackTheQueue() {
        let queue = queue(QueueItem(libraryItemID: "a", title: "A"), QueueItem(libraryItemID: "b", title: "B"))

        queue.move(fromOffsets: [1], toOffset: 0)
        #expect(QueueRow.rows(of: queue).map(\.libraryItemID) == ["b", "a"])

        queue.clear()
        #expect(QueueRow.rows(of: queue).isEmpty)
    }

    /// Playing a row plays its item or episode from the saved progress.
    @Test func playingARowPlaysItsMedia() async throws {
        let plays = Plays()
        let play = PlayItemAction { plays.all.append(($0, $1, $2)) }
        let rows = QueueRow.rows(
            of: queue(
                QueueItem(libraryItemID: "podcast", episodeID: "episode", title: "Episode"),
                QueueItem(libraryItemID: "book", title: "Book")))

        for row in rows { try await row.play(with: play) }

        #expect(plays.all.map(\.itemID) == ["podcast", "book"])
        #expect(plays.all.map(\.episodeID) == ["episode", nil])
        #expect(plays.all.map(\.startTime) == [nil, nil])
    }
}
