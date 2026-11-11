import Testing

@testable import ABSAppModel

private struct PlayFailed: Error {}

@MainActor
@Suite struct PlayItemActionTests {
    @Test func forwardsTheItemEpisodeAndStartTime() async throws {
        let calls = Locked<[String]>([])
        let play = PlayItemAction { itemID, episodeID, startTime in
            calls.value.append("\(itemID) \(episodeID ?? "-") \(startTime.map { "\($0)" } ?? "-")")
        }

        try await play(itemID: "li_1")
        try await play(itemID: "li_2", episodeID: "ep_1")
        try await play(itemID: "li_3", startTime: 42.5)
        try await play(itemID: "li_4", episodeID: "ep_2", startTime: 0)

        #expect(calls.value == ["li_1 - -", "li_2 ep_1 -", "li_3 - 42.5", "li_4 ep_2 0.0"])
    }

    @Test func rethrowsTheActionsError() async {
        let play = PlayItemAction { _, _, _ in throw PlayFailed() }

        await #expect(throws: PlayFailed.self) {
            try await play(itemID: "li_1")
        }
    }
}
