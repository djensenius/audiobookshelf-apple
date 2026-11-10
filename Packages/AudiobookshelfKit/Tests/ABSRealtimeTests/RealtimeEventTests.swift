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

    @Test func decodesPlaylistAdded() throws {
        guard case .playlistAdded(let playlist) = try decode(#"["playlist_added",\#(RealtimeFixtures.playlist)]"#)
        else {
            Issue.record("Expected playlistAdded")
            return
        }
        #expect(playlist.id == "pl-1")
        #expect(playlist.items.map(\.libraryItemId) == ["li-1"])
    }

    @Test func ignoresUnknownEvents() throws {
        #expect(try decode(#"["item_updated",{"id":"li-1"}]"#) == nil)
        #expect(try decode(#"["pong"]"#) == nil)
    }

    @Test func throwsOnMalformedPayloads() {
        #expect(throws: (any Error).self) { try decode(#"["user_updated",{"id":"usr-1"}]"#) }
        #expect(throws: (any Error).self) { try decode(#"["user_item_progress_updated",{"id":"mp-1"}]"#) }
        #expect(throws: (any Error).self) { try decode(#"["init"]"#) }
    }
}
