import ABSCore
import Foundation
import Testing

@testable import ABSRealtime

enum RealtimeFixtures {
    static let progress = #"""
        {"id":"mp-1","userId":"usr-1","libraryItemId":"li-1","episodeId":null,"duration":3600,"progress":0.5,
        "currentTime":1800,"isFinished":false,"hideFromContinueListening":false,"lastUpdate":1700000400000}
        """#
    static let user = #"{"id":"usr-1","username":"david","type":"admin","mediaProgress":[\#(progress)]}"#
    static let playlist = #"""
        {"id":"pl-1","libraryId":"lib-1","userId":"usr-1","name":"Road trip","description":null,
        "coverPath":null,"items":[{"libraryItemId":"li-1","episodeId":null}],"lastUpdate":1,"createdAt":1}
        """#
    static let progressUpdate =
        #"{"id":"mp-1","sessionId":"ses-1","deviceDescription":"iPhone","data":\#(progress)}"#
}

@Suite struct RealtimeEventTests {
    private func decode(_ arguments: String) throws -> RealtimeEvent? {
        guard case .event(_, _, let name, let data) = try SocketIOPacket(decoding: "2" + arguments) else {
            Issue.record("Not an event")
            return nil
        }
        return try RealtimeEvent.decode(name: name, arguments: data)
    }

    @Test func decodesInit() throws {
        let event = try decode(#"["init",{"userId":"usr-1","username":"david","usersOnline":[]}]"#)
        #expect(event == .initialized(RealtimeSession(userId: "usr-1", username: "david")))
    }

    @Test func decodesAuthFailed() throws {
        #expect(try decode(#"["auth_failed",{"message":"Token expired"}]"#) == .authFailed(message: "Token expired"))
        #expect(try decode(#"["auth_failed"]"#) == .authFailed(message: nil))
    }

    @Test func decodesUserUpdated() throws {
        guard case .userUpdated(let user) = try decode(#"["user_updated",\#(RealtimeFixtures.user)]"#) else {
            Issue.record("Expected userUpdated")
            return
        }
        #expect(user.id == "usr-1")
        #expect(user.type == .admin)
        #expect(user.mediaProgress.first?.currentTime == 1800)
    }

    @Test func decodesUserItemProgressUpdated() throws {
        let event = try decode(#"["user_item_progress_updated",\#(RealtimeFixtures.progressUpdate)]"#)
        guard case .userItemProgressUpdated(let update) = event else {
            Issue.record("Expected userItemProgressUpdated")
            return
        }
        #expect(update.id == "mp-1")
        #expect(update.sessionId == "ses-1")
        #expect(update.deviceDescription == "iPhone")
        #expect(update.progress.libraryItemId == "li-1")
        #expect(update.progress.progress == 0.5)
        #expect(update.progress.lastUpdate == 1_700_000_400_000)
    }

    @Test func decodesPlaylistChanges() throws {
        guard
            case .playlistChanged(.added(let playlist, let libraryID), let userID) = try decode(
                #"["playlist_added",\#(RealtimeFixtures.playlist)]"#)
        else {
            Issue.record("Expected a playlist addition")
            return
        }
        #expect(playlist.id == "pl-1")
        #expect(playlist.items.map(\.libraryItemId) == ["li-1"])
        #expect(libraryID == "lib-1")
        #expect(userID == "usr-1")
        #expect(
            try decode(#"["playlist_updated",\#(RealtimeFixtures.playlist)]"#)
                == .playlistChanged(.updated(playlist, libraryID: "lib-1"), userID: "usr-1"))
        // Removals send the whole expanded playlist.
        #expect(
            try decode(#"["playlist_removed",\#(RealtimeFixtures.playlist)]"#)
                == .playlistChanged(.removed(id: "pl-1", libraryID: "lib-1"), userID: "usr-1"))
    }

    @Test func decodesCollectionChanges() throws {
        // `toOldJSONExpanded()`: the collection with its books.
        let collection = #"""
            {"id":"col-1","libraryId":"lib-1","userId":"usr-1","name":"Classics","description":null,"cover":null,
            "coverFullPath":null,"books":[],"lastUpdate":1,"createdAt":1}
            """#
        let expected = LibraryCollection(
            id: "col-1", libraryId: "lib-1", userId: "usr-1", name: "Classics", books: [], lastUpdate: 1, createdAt: 1)
        #expect(
            try decode(#"["collection_added",\#(collection)]"#)
                == .collectionChanged(.added(expected, libraryID: "lib-1")))
        #expect(
            try decode(#"["collection_updated",\#(collection)]"#)
                == .collectionChanged(.updated(expected, libraryID: "lib-1")))
        #expect(
            try decode(#"["collection_removed",\#(collection)]"#)
                == .collectionChanged(.removed(id: "col-1", libraryID: "lib-1")))
    }

    @Test func decodesRssFeedChanges() throws {
        // `Feed.toOldJSONMinified()`.
        let json = #"""
            {"id":"feed-1","entityType":"libraryItem","entityId":"li-1","feedUrl":"/feed/my-book",
            "meta":{"title":"My Book","description":null,"preventIndexing":true,"ownerName":null,"ownerEmail":null}}
            """#
        let feed = RssFeed(
            id: "feed-1", entityType: "libraryItem", entityId: "li-1", feedUrl: "/feed/my-book",
            meta: .init(title: "My Book", preventIndexing: true))
        #expect(try decode(#"["rss_feed_open",\#(json)]"#) == .rssFeedChanged(.opened(feed)))
        #expect(try decode(#"["rss_feed_closed",\#(json)]"#) == .rssFeedChanged(.closed(feed)))
        #expect(throws: (any Error).self) { try decode(#"["rss_feed_open",{"id":"feed-1"}]"#) }
    }

    @Test func decodesStreamReset() throws {
        // `HlsRouter`'s `{startTime, streamId}`; the start time is only a signal, so it may be missing.
        #expect(
            try decode(#"["stream_reset",{"startTime":1206,"streamId":"ses-1"}]"#)
                == .streamReset(StreamReset(streamId: "ses-1", startTime: 1206)))
        #expect(try decode(#"["stream_reset",{"streamId":"ses-1"}]"#) == .streamReset(StreamReset(streamId: "ses-1")))
        // Without the stream's ID there is nothing to match, so it's malformed.
        #expect(throws: (any Error).self) { try decode(#"["stream_reset",{"startTime":1206}]"#) }
        #expect(throws: (any Error).self) { try decode(#"["stream_reset",{"streamId":7,"startTime":1206}]"#) }
        #expect(throws: (any Error).self) { try decode(#"["stream_reset","ses-1"]"#) }
        #expect(throws: (any Error).self) { try decode(#"["stream_reset"]"#) }
    }

    @Test func ignoresUnknownEvents() throws {
        #expect(try decode(#"["item_updated",{"id":"li-1"}]"#) == nil)
        #expect(try decode(#"["pong"]"#) == nil)
    }

    @Test func decodesAuthorChanges() throws {
        // `toOldJSON()` for additions, `toOldJSONExpanded(numBooks)` for updates.
        let fields = #"""
            "id":"au-1","asin":null,"name":"Ursula K. Le Guin","description":"Earthsea.",
            "imagePath":"/metadata/authors/au-1.jpg","libraryId":"lib-1","addedAt":1,"updatedAt":2
            """#
        let expected = Author(
            id: "au-1", name: "Ursula K. Le Guin", description: "Earthsea.", imagePath: "/metadata/authors/au-1.jpg",
            libraryId: "lib-1", addedAt: 1, updatedAt: 2)
        #expect(try decode(#"["author_added",{\#(fields)}]"#) == .authorChanged(.added(expected, libraryID: "lib-1")))

        guard
            case .authorChanged(.updated(let updated, let libraryID)) = try decode(
                #"["author_updated",{\#(fields),"numBooks":4}]"#)
        else {
            Issue.record("Expected an author update")
            return
        }
        #expect(updated.numBooks == 4)
        #expect(libraryID == "lib-1")

        // Scans send only the ID and library of a removed author; deletions send the whole author.
        #expect(
            try decode(#"["author_removed",{"id":"au-1","libraryId":"lib-1"}]"#)
                == .authorChanged(.removed(id: "au-1", libraryID: "lib-1")))
        #expect(
            try decode(#"["author_removed",{\#(fields)}]"#)
                == .authorChanged(.removed(id: "au-1", libraryID: "lib-1")))
    }

    @Test func throwsOnMalformedPayloads() {
        #expect(throws: (any Error).self) { try decode(#"["user_updated",{"id":"usr-1"}]"#) }
        #expect(throws: (any Error).self) { try decode(#"["user_item_progress_updated",{"id":"mp-1"}]"#) }
        #expect(throws: (any Error).self) { try decode(#"["init"]"#) }
        // Author changes must name their library.
        #expect(throws: (any Error).self) { try decode(#"["author_added",{"id":"au-1","name":"A"}]"#) }
        #expect(throws: (any Error).self) {
            try decode(#"["author_updated",{"id":"au-1","name":"A","libraryId":null}]"#)
        }
        #expect(throws: (any Error).self) { try decode(#"["author_updated",{"id":"au-1","libraryId":"lib-1"}]"#) }
        #expect(throws: (any Error).self) { try decode(#"["author_removed",{"libraryId":"lib-1"}]"#) }
        #expect(throws: (any Error).self) { try decode(#"["author_removed",{"id":"au-1"}]"#) }
        #expect(throws: (any Error).self) { try decode(#"["author_removed","au-1"]"#) }
        // Group changes must name their library, and playlist changes their owner.
        #expect(throws: (any Error).self) { try decode(#"["collection_added",{"id":"col-1","name":"C"}]"#) }
        #expect(throws: (any Error).self) { try decode(#"["collection_updated",{"id":"col-1","libraryId":"lib-1"}]"#) }
        #expect(throws: (any Error).self) { try decode(#"["collection_removed",{"id":"col-1"}]"#) }
        let ownerless = RealtimeFixtures.playlist.replacingOccurrences(of: #""userId":"usr-1","#, with: "")
        #expect(throws: (any Error).self) { try decode(#"["playlist_added",\#(ownerless)]"#) }
        #expect(throws: (any Error).self) { try decode(#"["playlist_updated",\#(ownerless)]"#) }
        #expect(throws: (any Error).self) { try decode(#"["playlist_removed",\#(ownerless)]"#) }
        #expect(throws: (any Error).self) {
            try decode(#"["playlist_removed",{"id":"pl-1","userId":"usr-1"}]"#)
        }
    }
}
