import ABSCore
import Foundation
import Testing

@testable import ABSAPI
@testable import ABSAppModel

@Suite struct LibraryViewPreferencesTests {
    // MARK: Persistence

    @Test func roundTripsThroughJSON() throws {
        let preferences = LibraryViewPreferences(
            sort: .authorLastFirst, descending: false, filter: .init(group: .authors, value: "au 1"),
            viewMode: .list, collapseSeries: true)
        let decoded = try #require(LibraryViewPreferences(json: preferences.json))
        #expect(decoded == preferences)
        #expect(preferences.json == preferences.json)
    }

    @Test func roundTripsEveryFilterGroupAndSortKey() throws {
        for key in LibrarySortKey.allCases {
            let preferences = LibraryViewPreferences(sort: key, descending: key == .title)
            #expect(LibraryViewPreferences(json: preferences.json) == preferences)
        }
        for group in LibraryFilterGroup.allCases {
            let preferences = LibraryViewPreferences(filter: .init(group: group, value: group.needsValue ? "v" : nil))
            #expect(LibraryViewPreferences(json: preferences.json) == preferences)
        }
    }

    @Test func unknownOrMistypedFieldsDecodeToTheDefault() throws {
        let defaults = LibraryViewPreferences()
        let json = """
            {"sort":"media.metadata.bogus","descending":"yes","viewMode":"carousel","collapseSeries":3,
             "filterGroup":"nonsense","filterValue":"x"}
            """
        #expect(LibraryViewPreferences(json: json) == defaults)
        #expect(LibraryViewPreferences(json: "{}") == defaults)
        #expect(LibraryViewPreferences(json: #"{"sort":42,"viewMode":null,"filterGroup":7}"#) == defaults)
    }

    @Test func validFieldsSurviveWhenOthersAreInvalid() throws {
        let json = #"{"sort":"size","descending":false,"viewMode":"???","collapseSeries":true}"#
        let decoded = try #require(LibraryViewPreferences(json: json))
        #expect(decoded.sort == .size)
        #expect(!decoded.descending)
        #expect(decoded.collapseSeries)
        #expect(decoded.viewMode == LibraryViewPreferences().viewMode)
    }

    @Test func textThatIsNotAJSONObjectIsNotPreferences() {
        #expect(LibraryViewPreferences(json: "") == nil)
        #expect(LibraryViewPreferences(json: "garbage") == nil)
        #expect(LibraryViewPreferences(json: "[1,2]") == nil)
        #expect(LibraryViewPreferences(json: "\"title\"") == nil)
    }

    @Test func aFilterNeedingAValueWithoutOneIsDroppedAndOneNotNeedingAValueLosesIt() throws {
        #expect(LibraryViewPreferences(json: #"{"filterGroup":"genres"}"#)?.filter == nil)
        #expect(LibraryViewPreferences(json: #"{"filterGroup":"genres","filterValue":""}"#)?.filter == nil)
        let issues = LibraryViewPreferences(json: #"{"filterGroup":"issues","filterValue":"x"}"#)?.filter
        #expect(issues == LibraryViewPreferences.Filter(group: .issues))
        #expect(issues?.value == nil)
    }

    @MainActor
    @Test func defaultsFollowLegacyAndAreGridWhateverEnableAltViewSays() async throws {
        let preferences = LibraryViewPreferences()
        #expect(preferences.sort == .addedAt)
        #expect(preferences.descending)
        #expect(preferences.filter == nil)
        #expect(!preferences.collapseSeries)
        #expect(preferences.viewMode == .grid)

        try await withLibrarySettings { settings in
            let key = LibraryConnectionKey(connectionID: UUID(), userID: "u")
            for altView in [true, false] {
                settings.enableAltView = altView
                #expect(settings.libraryViewPreferences(for: key, libraryID: "books") == nil)
                #expect(LibraryViewPreferences().viewMode == .grid)
            }
        }
    }

    @MainActor
    @Test func settingsKeepPreferencesPerLibraryAndAccount() async throws {
        try await withLibrarySettings { settings in
            let key = LibraryConnectionKey(connectionID: UUID(), userID: "u")
            let otherUser = LibraryConnectionKey(connectionID: key.connectionID, userID: "v")
            let preferences = LibraryViewPreferences(sort: .size, viewMode: .list)

            settings.saveLibraryViewPreferences(preferences, for: key, libraryID: "books")
            #expect(settings.libraryViewPreferences(for: key, libraryID: "books") == preferences)
            #expect(settings.libraryViewPreferences(for: key, libraryID: "pods") == nil)
            #expect(settings.libraryViewPreferences(for: otherUser, libraryID: "books") == nil)

            settings.setLibraryViewPreferencesJSON(
                "corrupt", serverID: key.serverID, userID: key.userID, libraryID: "pods")
            #expect(settings.libraryViewPreferences(for: key, libraryID: "pods") == nil)

            settings.saveLibraryViewPreferences(nil, for: key, libraryID: "books")
            #expect(settings.libraryViewPreferences(for: key, libraryID: "books") == nil)
        }
    }

    // MARK: Repair

    @Test func bookSortsMoveToTheirPodcastCounterparts() {
        func sort(_ key: LibrarySortKey) -> LibrarySortKey {
            LibraryViewPreferences(sort: key, descending: false).resolved(for: .podcast).sort
        }
        #expect(sort(.authorFirstLast) == .podcastAuthor)
        #expect(sort(.authorLastFirst) == .podcastAuthor)
        #expect(sort(.duration) == .episodeCount)
        #expect(sort(.publishedYear) == .title)
        #expect(sort(.progress) == .title)
        #expect(sort(.progressStarted) == .title)
        #expect(sort(.progressFinished) == .title)
        for key in LibrarySortKey.podcastKeys { #expect(sort(key) == key) }
    }

    @Test func podcastSortsMoveToTheirBookCounterparts() {
        func sort(_ key: LibrarySortKey) -> LibrarySortKey {
            LibraryViewPreferences(sort: key).resolved(for: .book).sort
        }
        #expect(sort(.podcastAuthor) == .authorFirstLast)
        #expect(sort(.episodeCount) == .duration)
        for key in LibrarySortKey.bookKeys { #expect(sort(key) == key) }
    }

    @Test func repairKeepsTheDirectionAndEverythingValid() {
        let stored = LibraryViewPreferences(
            sort: .duration, descending: false, filter: .init(group: .genres, value: "Fantasy"), viewMode: .list,
            collapseSeries: true)
        let podcast = stored.resolved(for: .podcast)
        #expect(podcast.sort == .episodeCount)
        #expect(!podcast.descending)
        #expect(podcast.filter == stored.filter)
        #expect(podcast.viewMode == .list)
        #expect(!podcast.collapseSeries)
        #expect(stored.resolved(for: .book) == stored)
    }

    @Test func podcastLibrariesDropFilterGroupsTheyDoNotOffer() {
        for group in LibraryFilterGroup.allCases {
            let stored = LibraryViewPreferences(filter: .init(group: group, value: group.needsValue ? "v" : nil))
            #expect((stored.resolved(for: .podcast).filter != nil) == LibraryFilterGroup.podcastGroups.contains(group))
            #expect(stored.resolved(for: .book).filter == stored.filter)
        }
    }

    @Test func unknownMediaTypesAreTreatedAsBooks() {
        let stored = LibraryViewPreferences(
            sort: .progress, filter: .init(group: .narrators, value: "N"), collapseSeries: true)
        #expect(stored.resolved(for: .unknown("music")) == stored)
    }

    @Test func repairingIsNotWritingBack() {
        let stored = LibraryViewPreferences(sort: .authorFirstLast)
        _ = stored.resolved(for: .podcast)
        #expect(stored.sort == .authorFirstLast)
    }

    @Test func selectingASortFlipsTheSameKeyAndStartsOthersAscendingExceptAddedAt() {
        var preferences = LibraryViewPreferences(sort: .title, descending: false)
        preferences.selectSort(.title)
        #expect(preferences.descending)
        preferences.selectSort(.size)
        #expect(preferences.sort == .size && !preferences.descending)
        preferences.selectSort(.addedAt)
        #expect(preferences.sort == .addedAt && preferences.descending)
        preferences.selectSort(.addedAt)
        #expect(!preferences.descending)
    }

    // MARK: Query

    @Test func theQueryHasTheServersSortKeyForEverySortAndDirection() {
        for key in LibrarySortKey.allCases {
            for descending in [false, true] {
                let preferences = LibraryViewPreferences(sort: key, descending: descending)
                for mediaType in [MediaType.book, .podcast] where LibrarySortKey.keys(for: mediaType).contains(key) {
                    let query = preferences.query(for: mediaType)
                    #expect(query.sort == key.rawValue)
                    #expect(query.descending == descending)
                    #expect(query.filter == nil)
                    #expect(!query.collapseSeries)
                    #expect(query.page == nil && query.limit == nil)
                }
            }
        }
    }

    @Test func theQueryEncodesEveryFilterGroup() {
        let expected: [LibraryFilterGroup: String] = [
            .genres: "genres.\(LibraryFilter.encode("Sci Fi/Fantasy"))",
            .tags: "tags.\(LibraryFilter.encode("Sci Fi/Fantasy"))",
            .series: "series.\(LibraryFilter.encode("Sci Fi/Fantasy"))",
            .authors: "authors.\(LibraryFilter.encode("Sci Fi/Fantasy"))",
            .narrators: "narrators.\(LibraryFilter.encode("Sci Fi/Fantasy"))",
            .languages: "languages.\(LibraryFilter.encode("Sci Fi/Fantasy"))",
            .progress: "progress.\(LibraryFilter.encode("Sci Fi/Fantasy"))",
            .ebooks: "ebooks.\(LibraryFilter.encode("Sci Fi/Fantasy"))",
            .issues: "issues",
            .feedOpen: "feed-open",
            .explicit: "explicit",
        ]
        #expect(Set(expected.keys) == Set(LibraryFilterGroup.allCases))
        for (group, queryValue) in expected {
            let preferences = LibraryViewPreferences(
                filter: .init(group: group, value: group.needsValue ? "Sci Fi/Fantasy" : nil))
            #expect(preferences.query(for: .book).filter?.queryValue == queryValue)
            let items = preferences.query(for: .book).queryItems
            #expect(items.first == URLQueryItem(name: "filter", value: queryValue))
        }
    }

    @Test func collapseSeriesIsSentForBooksOnly() {
        let preferences = LibraryViewPreferences(collapseSeries: true)
        #expect(preferences.query(for: .book).collapseSeries)
        #expect(preferences.query(for: .book).queryItems.contains(URLQueryItem(name: "collapseseries", value: "1")))
        #expect(!preferences.query(for: .podcast).collapseSeries)
        let bySeries = LibraryViewPreferences(filter: .init(group: .series, value: "s1"), collapseSeries: true)
        #expect(!bySeries.query(for: .book).collapseSeries)
    }

    @Test func theQueryIsRepairedForTheLibraryType() {
        let stored = LibraryViewPreferences(
            sort: .authorFirstLast, descending: false, filter: .init(group: .narrators, value: "N"))
        let query = stored.query(for: .podcast)
        #expect(query.sort == "media.metadata.author")
        #expect(query.filter == nil)
    }
}
