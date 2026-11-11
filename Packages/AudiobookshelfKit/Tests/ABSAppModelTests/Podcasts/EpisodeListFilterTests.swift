import ABSCore
import Foundation
import Testing

@testable import ABSAppModel

/// Six episodes in server order, covering ties, blanks, case, diacritics and numbers in titles.
///
/// | ID | Title                | Published | Season | Episode | Progress           |
/// |----|----------------------|-----------|--------|---------|--------------------|
/// | e1 | Episode 10: Finale   | 5000      | 1      | 10      | finished           |
/// | e2 | episode 9: Penultimate | 4000    | 1      | 9       | half listened      |
/// | e3 | Épisode bonus        | none      | none   | none    | none               |
/// | e4 | Episode 1: Pilot     | 1000      | 2      | 1       | record, nothing listened |
/// | e5 | Episode 2: Trailer   | 1000      | 2      | 2       | finished           |
/// | e6 | Episode 1: Pilot     | 3000      | 1      | 1       | none               |
private enum Fixture {
    static let episodes: [PodcastEpisode] = [
        PodcastEpisode(id: "e1", season: "1", episode: "10", title: "Episode 10: Finale", publishedAt: 5000),
        PodcastEpisode(id: "e2", season: "1", episode: " 9 ", title: "episode 9: Penultimate", publishedAt: 4000),
        PodcastEpisode(id: "e3", season: " ", title: "Épisode bonus"),
        PodcastEpisode(id: "e4", season: "2", episode: "1", title: "Episode 1: Pilot", publishedAt: 1000),
        PodcastEpisode(id: "e5", season: "2", episode: "2", title: "Episode 2: Trailer", publishedAt: 1000),
        PodcastEpisode(id: "e6", season: "1", episode: "1", title: "Episode 1: Pilot", publishedAt: 3000),
    ]

    static let progress: [String: ItemProgress] = [
        "e1": ItemProgress(fraction: 1, isFinished: true),
        "e2": ItemProgress(fraction: 0.5),
        "e4": ItemProgress(fraction: 0),
        "e5": ItemProgress(fraction: 0.2, isFinished: true),
    ]

    static let locale = Locale(identifier: "en_US")

    static let members: [EpisodeListFilter: Set<String>] = [
        .all: ["e1", "e2", "e3", "e4", "e5", "e6"],
        .incomplete: ["e2", "e3", "e4", "e6"],
        .inProgress: ["e2"],
        .complete: ["e1", "e5"],
    ]

    /// Every episode in each sort's ascending order. Every tie is broken by a key, except e4 and
    /// e5's published date, which keeps the server's order in both directions.
    static let ascending: [EpisodeSortKey: [String]] = [
        .publishedAt: ["e3", "e4", "e5", "e6", "e2", "e1"],
        .title: ["e4", "e6", "e5", "e2", "e1", "e3"],
        .season: ["e6", "e2", "e1", "e4", "e5", "e3"],
        .episode: ["e6", "e4", "e5", "e2", "e1", "e3"],
    ]

    static let descending: [EpisodeSortKey: [String]] = [
        .publishedAt: ["e1", "e2", "e6", "e4", "e5", "e3"],
        .title: ["e3", "e1", "e2", "e5", "e6", "e4"],
        .season: ["e3", "e5", "e4", "e1", "e2", "e6"],
        .episode: ["e3", "e1", "e2", "e5", "e4", "e6"],
    ]

    static func arrange(
        filter: EpisodeListFilter = .all, search: String = "", sort: EpisodeSortKey = .publishedAt,
        descending: Bool = false, episodes: [PodcastEpisode] = episodes
    ) -> [String] {
        EpisodeList.arrange(
            episodes, filter: filter, search: search, sort: sort, descending: descending, locale: locale,
            progress: { progress[$0.id] }
        ).map(\.id)
    }
}

/// One filter, sort and direction, named in the test report.
struct EpisodeListCombination: Sendable, CustomTestStringConvertible {
    let filter: EpisodeListFilter
    let sort: EpisodeSortKey
    let descending: Bool

    var testDescription: String { "\(filter) by \(sort) \(descending ? "descending" : "ascending")" }

    static let all: [EpisodeListCombination] = EpisodeListFilter.allCases.flatMap { filter in
        EpisodeSortKey.allCases.flatMap { sort in
            [false, true].map { EpisodeListCombination(filter: filter, sort: sort, descending: $0) }
        }
    }
}

@Suite struct EpisodeListFilterTests {
    @Test(
        arguments: [
            (EpisodeListFilter.all, nil, true),
            (.all, ItemProgress(fraction: 1, isFinished: true), true),
            (.incomplete, nil, true),
            (.incomplete, ItemProgress(fraction: 0), true),
            (.incomplete, ItemProgress(fraction: 0.4), true),
            (.incomplete, ItemProgress(fraction: 0, isFinished: true), false),
            (.inProgress, nil, false),
            (.inProgress, ItemProgress(fraction: 0), false),
            (.inProgress, ItemProgress(fraction: 0.4), true),
            (.inProgress, ItemProgress(fraction: 0.4, isFinished: true), false),
            (.complete, nil, false),
            (.complete, ItemProgress(fraction: 0.4), false),
            (.complete, ItemProgress(fraction: 0, isFinished: true), true),
        ] as [(EpisodeListFilter, ItemProgress?, Bool)])
    func filterMapsProgress(filter: EpisodeListFilter, progress: ItemProgress?, included: Bool) {
        #expect(filter.includes(progress) == included)
    }

    @Test(arguments: EpisodeListCombination.all)
    func everyFilterAndSortCombination(_ combination: EpisodeListCombination) throws {
        let order = try #require(
            (combination.descending ? Fixture.descending : Fixture.ascending)[combination.sort])
        let members = try #require(Fixture.members[combination.filter])
        #expect(
            Fixture.arrange(filter: combination.filter, sort: combination.sort, descending: combination.descending)
                == order.filter(members.contains))
    }

    @Test func tiesKeepTheServersOrderInBothDirections() {
        let tied = [
            PodcastEpisode(id: "a", title: "Same", publishedAt: 7),
            PodcastEpisode(id: "b", title: "same", publishedAt: 7),
            PodcastEpisode(id: "c", title: "Same", publishedAt: 7),
        ]
        for sort in EpisodeSortKey.allCases {
            #expect(Fixture.arrange(sort: sort, episodes: tied) == ["a", "b", "c"])
            #expect(Fixture.arrange(sort: sort, descending: true, episodes: tied) == ["a", "b", "c"])
        }
    }

    @Test func aZeroPublishedDateCountsAsMissing() {
        let episodes = [
            PodcastEpisode(id: "dated", publishedAt: 1), PodcastEpisode(id: "zero", publishedAt: 0),
            PodcastEpisode(id: "none"),
        ]
        #expect(Fixture.arrange(episodes: episodes) == ["zero", "none", "dated"])
        #expect(Fixture.arrange(descending: true, episodes: episodes) == ["dated", "zero", "none"])
    }

    @Test(arguments: [
        ("", ["e1", "e2", "e3", "e4", "e5", "e6"]),
        ("   ", ["e1", "e2", "e3", "e4", "e5", "e6"]),
        ("EPISODE", ["e1", "e2", "e3", "e4", "e5", "e6"]),
        ("épisode 1", ["e1", "e4", "e6"]),
        ("  pilot \n", ["e4", "e6"]),
        ("Bonus", ["e3"]),
        ("nothing like this", []),
    ])
    func searchMatchesTitlesIgnoringCaseDiacriticsAndWhitespace(search: String, ids: [String]) {
        #expect(Set(Fixture.arrange(search: search)) == Set(ids))
    }

    @Test func searchCombinesWithTheFilterAndKeepsTheSort() {
        #expect(Fixture.arrange(filter: .incomplete, search: "pilot", sort: .publishedAt) == ["e4", "e6"])
        #expect(Fixture.arrange(filter: .incomplete, search: "pilot", descending: true) == ["e6", "e4"])
        #expect(Fixture.arrange(filter: .complete, search: "pilot").isEmpty)
        #expect(Fixture.arrange(filter: .complete, search: "episode", sort: .title) == ["e5", "e1"])
    }

    @Test func nextEpisodeIsTheFirstUnfinishedInThePodcastsOrder() {
        func next(_ type: String?, _ progress: [String: ItemProgress] = Fixture.progress) -> String? {
            EpisodeList.nextEpisode(Fixture.episodes, podcastType: type, locale: Fixture.locale) { progress[$0.id] }?
                .id
        }
        // Newest first: e1 is finished.
        #expect(next("episodic") == "e2")
        #expect(next(nil) == "e2")
        // Oldest first: e3 has no date, so it counts as the oldest.
        #expect(next("serial") == "e3")
        let allFinished = Dictionary(
            uniqueKeysWithValues: Fixture.episodes.map { ($0.id, ItemProgress(fraction: 1, isFinished: true)) })
        #expect(next("episodic", allFinished) == "e1")
        #expect(next("serial", allFinished) == "e3")
        #expect(EpisodeList.nextEpisode([], podcastType: "serial", locale: Fixture.locale) { _ in nil } == nil)
    }
}

@Suite struct EpisodeListPreferencesTests {
    @Test func defaultsMatchLegacy() {
        let preferences = EpisodeListPreferences()
        #expect(preferences.filter == .incomplete)
        #expect(preferences.sort == .publishedAt)
        #expect(preferences.descending == nil)
        #expect(preferences.isDescending(podcastType: "episodic"))
        #expect(!preferences.isDescending(podcastType: "serial"))
        #expect(!preferences.isDescending(podcastType: nil))
        #expect(EpisodeListPreferences(descending: false).isDescending(podcastType: "episodic") == false)
        #expect(EpisodeListPreferences(descending: true).isDescending(podcastType: "serial"))
    }

    @Test func roundTripsThroughJSON() throws {
        let preferences = EpisodeListPreferences(filter: .inProgress, sort: .season, descending: false)
        #expect(preferences.json == #"{"descending":false,"filter":"inProgress","sort":"season"}"#)
        #expect(EpisodeListPreferences(json: preferences.json) == preferences)
        #expect(EpisodeListPreferences().json == #"{"filter":"incomplete","sort":"publishedAt"}"#)
        #expect(EpisodeListPreferences(json: EpisodeListPreferences().json) == EpisodeListPreferences())
    }

    @Test(arguments: [
        // Legacy-only values: downloaded episodes and the file name.
        (
            #"{"filter":"downloaded","sort":"audioFile.metadata.filename","descending":true}"#,
            EpisodeListPreferences(descending: true)
        ),
        (#"{"filter":3,"sort":null,"descending":"yes"}"#, EpisodeListPreferences()),
        (#"{"filter":"complete"}"#, EpisodeListPreferences(filter: .complete)),
        ("{}", EpisodeListPreferences()),
    ])
    func decodingReplacesUnusableFieldsWithDefaults(json: String, expected: EpisodeListPreferences) {
        #expect(EpisodeListPreferences(json: json) == expected)
    }

    @Test(arguments: ["", "[]", "\"text\"", "not json", "{"])
    func decodingTextThatIsNotAnObjectFails(json: String) {
        #expect(EpisodeListPreferences(json: json) == nil)
    }
}
