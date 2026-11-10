import ABSData
import Foundation
import Testing

@testable import ABSAppModel

private let server = UUID(uuidString: "6F1E7C2A-3B4D-4E5F-8A9B-0C1D2E3F4A5B")!
private let otherServer = UUID(uuidString: "0A1B2C3D-4E5F-4A6B-8C7D-9E0F1A2B3C4D")!

@Suite struct PlayLinkDecisionTests {
    static let book = MediaKey(serverConnectionID: server, libraryItemId: "li_1")
    static let episode = MediaKey(serverConnectionID: server, libraryItemId: "li_1", episodeId: "ep_1")
    static let other = MediaKey(serverConnectionID: server, libraryItemId: "li_2")
    static let bookOnOtherServer = MediaKey(serverConnectionID: otherServer, libraryItemId: "li_1")

    struct Case: Sendable, CustomTestStringConvertible {
        let name: String
        let link: PlayLink
        let nowPlaying: MediaKey?
        let isPlaying: Bool
        let expected: PlayLinkDecision
        var testDescription: String { name }
    }

    static let matrix: [Case] = [
        Case(
            name: "nothing loaded", link: PlayLink(itemID: "li_1"), nowPlaying: nil, isPlaying: false,
            expected: .confirmPlay(startTime: nil)),
        Case(
            name: "nothing loaded, t=", link: PlayLink(itemID: "li_1", startTime: 90), nowPlaying: nil,
            isPlaying: false, expected: .confirmPlay(startTime: 90)),
        Case(
            name: "other item playing", link: PlayLink(itemID: "li_1"), nowPlaying: other, isPlaying: true,
            expected: .confirmPlay(startTime: nil)),
        Case(
            name: "other item paused, t=", link: PlayLink(itemID: "li_1", startTime: 90), nowPlaying: other,
            isPlaying: false, expected: .confirmPlay(startTime: 90)),
        Case(
            name: "same item playing", link: PlayLink(itemID: "li_1"), nowPlaying: book, isPlaying: true,
            expected: .openOnly),
        Case(
            name: "same item playing, t= never seeks", link: PlayLink(itemID: "li_1", startTime: 90),
            nowPlaying: book, isPlaying: true, expected: .openOnly),
        Case(
            name: "same item paused", link: PlayLink(itemID: "li_1"), nowPlaying: book, isPlaying: false,
            expected: .confirmResume(startTime: nil)),
        Case(
            name: "same item paused, t=", link: PlayLink(itemID: "li_1", startTime: 90), nowPlaying: book,
            isPlaying: false, expected: .confirmResume(startTime: 90)),
        Case(
            name: "same episode playing", link: PlayLink(itemID: "li_1", episodeID: "ep_1"), nowPlaying: episode,
            isPlaying: true, expected: .openOnly),
        Case(
            name: "same episode playing, t=", link: PlayLink(itemID: "li_1", episodeID: "ep_1", startTime: 5),
            nowPlaying: episode, isPlaying: true, expected: .openOnly),
        Case(
            name: "same episode paused", link: PlayLink(itemID: "li_1", episodeID: "ep_1"), nowPlaying: episode,
            isPlaying: false, expected: .confirmResume(startTime: nil)),
        Case(
            name: "same episode paused, t=", link: PlayLink(itemID: "li_1", episodeID: "ep_1", startTime: 5),
            nowPlaying: episode, isPlaying: false, expected: .confirmResume(startTime: 5)),
        Case(
            name: "other episode playing", link: PlayLink(itemID: "li_1", episodeID: "ep_2"), nowPlaying: episode,
            isPlaying: true, expected: .confirmPlay(startTime: nil)),
        Case(
            name: "podcast without episode, episode playing", link: PlayLink(itemID: "li_1"), nowPlaying: episode,
            isPlaying: true, expected: .confirmPlay(startTime: nil)),
        Case(
            name: "episode link, item without episode playing", link: PlayLink(itemID: "li_1", episodeID: "ep_1"),
            nowPlaying: book, isPlaying: true, expected: .confirmPlay(startTime: nil)),
        // Pins current behaviour: the server isn't compared, because only links for the
        // active server reach the decision and S8 stops playback when the account switches.
        Case(
            name: "same item ID on another server", link: PlayLink(itemID: "li_1"), nowPlaying: bookOnOtherServer,
            isPlaying: true, expected: .openOnly),
    ]

    @Test(arguments: matrix) func decides(_ test: Case) {
        #expect(
            PlayLinkDecision.decide(test.link, nowPlaying: test.nowPlaying, isPlaying: test.isPlaying)
                == test.expected)
    }
}
