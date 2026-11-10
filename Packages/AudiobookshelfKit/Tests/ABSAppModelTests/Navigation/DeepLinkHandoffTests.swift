import Foundation
import Testing

@testable import ABSAppModel

@Suite struct DeepLinkHandoffTests {
    private let server = "6F1E7C2A-3B4D-4E5F-8A9B-0C1D2E3F4A5B"

    @Test func activityTypeMatchesTheInfoPlistEntry() {
        // Info.plist lists this string in NSUserActivityTypes; the app's tests check that it does.
        #expect(DeepLink.handoffActivityType == "org.davidjensenius.Audiobookshelf.item")
    }

    @Test func itemActivityOpensTheItem() {
        #expect(DeepLink(handoff: ["item": "li_1"]) == DeepLink(.item(id: "li_1", episodeID: nil)))
    }

    @Test func episodeActivityOpensTheEpisode() {
        let link = DeepLink(handoff: ["item": "li_1", "episode": "ep_1"])
        #expect(link == DeepLink(.item(id: "li_1", episodeID: "ep_1")))
    }

    @Test func positionMakesAPlayLinkThatStillNeedsConfirmation() {
        let link = DeepLink(handoff: ["item": "li_1", "episode": "ep_1", "position": 5_025.5])
        let play = PlayLink(itemID: "li_1", episodeID: "ep_1", startTime: 5_025.5)
        #expect(link == DeepLink(.play(play)))
    }

    @Test func positionFromAPropertyListNumber() {
        // An activity's userInfo holds NSNumbers once it has crossed devices.
        #expect(DeepLink(handoff: ["item": "li_1", "position": NSNumber(value: 90)]) == playLink("li_1", at: 90))
        #expect(DeepLink(handoff: ["item": "li_1", "position": 0]) == playLink("li_1", at: 0))
    }

    @Test func serverIsKept() {
        let link = DeepLink(handoff: ["server": server, "item": "li_1", "library": "lib_1"])
        #expect(link == DeepLink(.item(id: "li_1", episodeID: nil), serverID: server))

        let play = DeepLink(handoff: ["server": server, "item": "li_1", "position": 12])
        #expect(play == DeepLink(.play(PlayLink(itemID: "li_1", startTime: 12)), serverID: server))
    }

    @Test func emptyOptionalEntriesCountAsAbsent() {
        let link = DeepLink(handoff: ["item": "li_1", "episode": "", "server": ""])
        #expect(link == DeepLink(.item(id: "li_1", episodeID: nil)))
    }

    @Test func positionThatIsNotAValidStartTimeIsIgnored() {
        let item = DeepLink(.item(id: "li_1", episodeID: nil))
        let positions: [Any] = [-1, -0.5, 10_000_001, Double.nan, Double.infinity, "90", ["90"]]
        for position in positions {
            #expect(DeepLink(handoff: ["item": "li_1", "position": position]) == item, "\(position)")
        }
    }

    @Test func largestStartTimeIsAccepted() {
        let largest = DeepLink.maxStartTime
        #expect(DeepLink(handoff: ["item": "li_1", "position": largest]) == playLink("li_1", at: largest))
    }

    @Test func missingActivityDataIsRejected() {
        #expect(DeepLink(handoff: nil) == nil)
        #expect(DeepLink(handoff: [:]) == nil)
        #expect(DeepLink(handoff: ["episode": "ep_1", "position": 5]) == nil)
        #expect(DeepLink(handoff: ["item": ""]) == nil)
    }

    @Test(arguments: [" ", ".", "..", "a\u{0}b", "a\nb", String(repeating: "x", count: 257)])
    func invalidIDsAreRejected(id: String) {
        #expect(DeepLink(handoff: ["item": id]) == nil)
        #expect(DeepLink(handoff: ["item": "li_1", "episode": id]) == nil)
        // A server the activity names but we can't read must not fall back to the active one.
        #expect(DeepLink(handoff: ["item": "li_1", "server": id]) == nil)
    }

    @Test func entriesThatAreNotStringsAreRejected() {
        #expect(DeepLink(handoff: ["item": 5]) == nil)
        #expect(DeepLink(handoff: ["item": "li_1", "episode": 5]) == nil)
        #expect(DeepLink(handoff: ["item": "li_1", "server": ["x"]]) == nil)
    }

    @Test func longestIDIsAccepted() {
        let id = String(repeating: "x", count: 256)
        #expect(DeepLink(handoff: ["item": id]) == DeepLink(.item(id: id, episodeID: nil)))
    }

    private func playLink(_ id: String, at seconds: TimeInterval) -> DeepLink {
        DeepLink(.play(PlayLink(itemID: id, startTime: seconds)))
    }
}
