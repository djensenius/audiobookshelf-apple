import Testing

@testable import ABSAppModel

private struct PlayFailed: Error {}

@MainActor
@Suite struct PlayItemActionTests {
    @Test func forwardsTheItemAndEpisode() async throws {
        let calls = Locked<[String]>([])
        let play = PlayItemAction { itemID, episodeID in
            calls.value.append("\(itemID) \(episodeID ?? "-")")
        }

        try await play(itemID: "li_1")
        try await play(itemID: "li_2", episodeID: "ep_1")

        #expect(calls.value == ["li_1 -", "li_2 ep_1"])
    }

    @Test func rethrowsTheActionsError() async {
        let play = PlayItemAction { _, _ in throw PlayFailed() }

        await #expect(throws: PlayFailed.self) {
            try await play(itemID: "li_1")
        }
    }
}
