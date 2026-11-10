import Foundation
import Testing

@testable import ABSAppModel

private func link(_ string: String) -> DeepLink? {
    URL(string: string).flatMap(DeepLink.init(url:))
}

@Suite struct DeepLinkTests {
    struct Case: Sendable, CustomTestStringConvertible {
        let url: String
        let expected: DeepLink?
        var testDescription: String { url }

        init(_ url: String, _ expected: DeepLink?) {
            self.url = url
            self.expected = expected
        }
    }

    static let kinds: [Case] = [
        Case("audiobookshelf://item/li_1", DeepLink(.item(id: "li_1", episodeID: nil))),
        Case("audiobookshelf://item/li_1?episode=ep_1", DeepLink(.item(id: "li_1", episodeID: "ep_1"))),
        Case("audiobookshelf://play/li_1", DeepLink(.play(PlayLink(itemID: "li_1")))),
        Case(
            "audiobookshelf://play/li_1?episode=ep_1&t=90",
            DeepLink(.play(PlayLink(itemID: "li_1", episodeID: "ep_1", startTime: 90)))),
        Case("audiobookshelf://series/se_1", DeepLink(.series(id: "se_1"))),
        Case("audiobookshelf://author/au_1", DeepLink(.author(id: "au_1"))),
        Case("audiobookshelf://collection/co_1", DeepLink(.collection(id: "co_1"))),
        Case("audiobookshelf://playlist/pl_1", DeepLink(.playlist(id: "pl_1"))),
        Case("audiobookshelf://library/lib_1", DeepLink(.library(id: "lib_1"))),
        Case("audiobookshelf://search?q=dune", DeepLink(.search(query: "dune"))),
        Case("audiobookshelf://search", DeepLink(.search(query: nil))),
        Case("audiobookshelf://search?q=", DeepLink(.search(query: nil))),
        Case("audiobookshelf://downloads", DeepLink(.downloads)),
        Case("audiobookshelf://downloads/", DeepLink(.downloads)),
        // Trailing slash, upper-case scheme, kind and query names, and a fragment.
        Case("audiobookshelf://item/li_1/", DeepLink(.item(id: "li_1", episodeID: nil))),
        Case("AudioBookShelf://ITEM/li_1?EPISODE=ep_1", DeepLink(.item(id: "li_1", episodeID: "ep_1"))),
        Case("audiobookshelf://item/li_1#ep_9", DeepLink(.item(id: "li_1", episodeID: nil))),
        Case("audiobookshelf://item/li_1?episode=", DeepLink(.item(id: "li_1", episodeID: nil))),
        Case("audiobookshelf://item/a.b", DeepLink(.item(id: "a.b", episodeID: nil))),
        Case(
            "audiobookshelf://item/\(String(repeating: "x", count: 256))",
            DeepLink(.item(id: String(repeating: "x", count: 256), episodeID: nil))),
        Case(
            "audiobookshelf://search?q=\(String(repeating: "q", count: 1_024))",
            DeepLink(.search(query: String(repeating: "q", count: 1_024)))),
    ]

    static let encoding: [Case] = [
        Case("audiobookshelf://item/li%2F1", DeepLink(.item(id: "li/1", episodeID: nil))),
        Case("audiobookshelf://item/li%201?episode=ep%26x", DeepLink(.item(id: "li 1", episodeID: "ep&x"))),
        Case("audiobookshelf://search?q=the+left%20hand%2B", DeepLink(.search(query: "the left hand+"))),
        Case("audiobookshelf://search?q=%C3%A9t%C3%A9", DeepLink(.search(query: "été"))),
    ]

    static let rejected: [Case] = [
        Case("audiobookshelf://item", nil),
        Case("audiobookshelf://item/", nil),
        Case("audiobookshelf://item//", nil),
        Case("audiobookshelf://item//li_1", nil),
        Case("audiobookshelf://item/li_1//", nil),
        Case("audiobookshelf://item/.", nil),
        Case("audiobookshelf://item/..", nil),
        Case("audiobookshelf://item/%2E%2E", nil),
        Case("audiobookshelf://item/%20%20", nil),
        Case("audiobookshelf://item/li%0A1", nil),
        Case("audiobookshelf://item/li%001", nil),
        Case("audiobookshelf://item/li%FF", nil),
        Case("audiobookshelf://item/\(String(repeating: "x", count: 257))", nil),
        Case("audiobookshelf://item/li_1?episode=..", nil),
        Case("audiobookshelf://item/li_1?episode=%09", nil),
        Case("audiobookshelf://item/li_1?episode=%FF", nil),
        Case("audiobookshelf://search?q=\(String(repeating: "q", count: 1_025))", nil),
        Case("audiobookshelf://play", nil),
        Case("audiobookshelf://series", nil),
        Case("audiobookshelf://author/", nil),
        Case("audiobookshelf://collection", nil),
        Case("audiobookshelf://playlist", nil),
        Case("audiobookshelf://library", nil),
        Case("audiobookshelf://item/li_1/extra", nil),
        Case("audiobookshelf://search/dune", nil),
        Case("audiobookshelf://downloads/li_1", nil),
        Case("audiobookshelf://", nil),
        Case("audiobookshelf:", nil),
        Case("audiobookshelf://settings", nil),
        Case("audiobookshelf://unknown/li_1", nil),
        Case("audiobookshelf://oauth?code=abc&state=xyz", nil),
        Case("audiobookshelf://oauth", nil),
        Case("audiobookshelf:oauth?code=abc", nil),
        Case("audiobookshelf:///oauth?code=abc", nil),
        Case("AUDIOBOOKSHELF://OAuth?code=abc", nil),
        Case("audiobookshelf://oauth/item?code=abc", nil),
        // No host: no legacy source produces these.
        Case("audiobookshelf:item/li_1", nil),
        Case("audiobookshelf:///item/li_1", nil),
        Case("https://item/li_1", nil),
        Case("https://abs.example.com/item/li_1", nil),
        Case("audiobook://item/li_1", nil),
    ]

    static let servers: [Case] = [
        Case(
            "audiobookshelf://item/li_1?server=conn-1",
            DeepLink(.item(id: "li_1", episodeID: nil), serverID: "conn-1")),
        Case("audiobookshelf://downloads?server=conn-1", DeepLink(.downloads, serverID: "conn-1")),
        Case("audiobookshelf://library/lib_1?Server=conn-1", DeepLink(.library(id: "lib_1"), serverID: "conn-1")),
        Case("audiobookshelf://library/lib_1?SERVER=conn-1", DeepLink(.library(id: "lib_1"), serverID: "conn-1")),
        Case(
            "audiobookshelf://play/li_1?server=conn-1&t=5&episode=ep_1",
            DeepLink(.play(PlayLink(itemID: "li_1", episodeID: "ep_1", startTime: 5)), serverID: "conn-1")),
        // The first value of a repeated parameter wins.
        Case("audiobookshelf://series/se_1?server=a&server=b", DeepLink(.series(id: "se_1"), serverID: "a")),
    ]

    // A server the link names but we can't read must not fall back to the active server.
    static let unreadableServers: [String] = [
        "audiobookshelf://library/lib_1?server=",
        "audiobookshelf://library/lib_1?server",
        "audiobookshelf://library/lib_1?server=%20",
        "audiobookshelf://library/lib_1?server=%FF",
        "audiobookshelf://library/lib_1?Server=%0A",
        "audiobookshelf://library/lib_1?SERVER=..",
        "audiobookshelf://library/lib_1?server=\(String(repeating: "s", count: 257))",
    ]

    @Test(arguments: unreadableServers) func rejectsUnreadableServer(_ url: String) {
        #expect(link(url) == nil)
    }

    @Test(arguments: kinds) func parsesEveryKind(_ test: Case) {
        #expect(link(test.url) == test.expected)
    }

    @Test(arguments: encoding) func decodesPercentEncoding(_ test: Case) {
        #expect(link(test.url) == test.expected)
    }

    @Test(arguments: rejected) func rejectsInvalidLinks(_ test: Case) {
        #expect(link(test.url) == nil)
    }

    @Test(arguments: servers) func parsesServer(_ test: Case) {
        #expect(link(test.url) == test.expected)
    }

    @Test(
        arguments: [
            ("0", 0.0), ("90", 90), ("90.5", 90.5), ("1:30", 90), ("01:23:45", 5025), ("83:45", 5025),
            ("120:00", 7200), ("10000000", 10_000_000), ("2777:46:40", 10_000_000),
        ] as [(String, TimeInterval)])
    func parsesStartTimes(_ text: String, _ seconds: TimeInterval) {
        #expect(
            link("audiobookshelf://play/li_1?t=\(text)")
                == DeepLink(.play(PlayLink(itemID: "li_1", startTime: seconds))))
    }

    @Test(arguments: [
        "", "-5", "-1:00", "abc", "1e3", "inf", "nan", "1:60", "1:5:60", "1:2:3:4", ":30", "1:", "1::2", "1:-1",
        "1.5:00", "٣", "%2B5", "10000000.5", "2777:46:41", "99999999999999999999", "1e308",
        "9223372036854775807:00:00",
    ])
    func ignoresInvalidStartTimes(_ text: String) {
        // The link still opens the item; only the start time is dropped.
        #expect(link("audiobookshelf://play/li_1?t=\(text)") == DeepLink(.play(PlayLink(itemID: "li_1"))))
    }

    @Test func startTimeOnlyAppliesToPlayLinks() {
        #expect(link("audiobookshelf://item/li_1?t=90") == DeepLink(.item(id: "li_1", episodeID: nil)))
    }
}
