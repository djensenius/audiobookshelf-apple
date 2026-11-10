import ABSCore
import Foundation
import Testing

private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
    try JSONDecoder().decode(type, from: Data(json.utf8))
}

@Suite struct UserModelTests {
    @Test func decodesLoginResponseWithAccessAndRefreshTokens() throws {
        let response = try decode(AuthResponse.self, UserFixtures.loginResponse)
        #expect(response.tokens == AuthTokens(accessToken: "access-abc", refreshToken: "refresh-abc"))
        #expect(response.userDefaultLibraryId == "lib-books")
        #expect(response.serverSettings?.version == "2.26.0")
        #expect(response.serverSettings?.sortingIgnorePrefix == true)
        #expect(response.serverSettings?.sortingPrefixes == ["the", "a"])
        #expect(response.serverSettings?.timeZone == "America/Toronto")

        let user = response.user
        #expect(user.id == "usr-1")
        #expect(user.type == .admin)
        #expect(user.email == nil)
        #expect(user.lastSeen == 1_700_000_400_000)
        #expect(user.seriesHideFromContinueListening == ["se-1"])
        #expect(user.librariesAccessible == ["lib-books"])
        #expect(user.itemTagsSelected == ["spoilers"])
        #expect(user.hasOpenIDLink == false)
        #expect(user.permissions.update)
        #expect(!user.permissions.delete)
        #expect(!user.permissions.accessAllLibraries)
        #expect(user.permissions.selectedTagsNotAccessible)
    }

    @Test func decodesLegacyLoginResponseToken() throws {
        let response = try decode(AuthResponse.self, UserFixtures.legacyLoginResponse)
        #expect(response.tokens == AuthTokens(accessToken: "legacy-jwt", refreshToken: nil))
        #expect(response.userDefaultLibraryId == nil)
        #expect(response.serverSettings?.language == "de")
        #expect(response.user.type == .guest)
        #expect(response.user.lastSeen == nil)
        #expect(response.user.permissions.accessAllLibraries)
        // Omitted flags default to false.
        #expect(!response.user.permissions.createEreader)
        #expect(!response.user.permissions.selectedTagsNotAccessible)
    }

    @Test func tokensAreNilWithoutAnyToken() throws {
        let json = #"{"user":{"id":"usr-3","username":"x","token":null},"userDefaultLibraryId":"lib-1"}"#
        let response = try decode(AuthResponse.self, json)
        #expect(response.tokens == nil)
        #expect(response.user.mediaProgress.isEmpty)
        #expect(response.user.permissions == UserPermissions())
    }

    @Test func prefersAccessTokenOverLegacyToken() throws {
        let json = #"{"user":{"id":"u","username":"x","token":"old","accessToken":"new","refreshToken":null}}"#
        let response = try decode(AuthResponse.self, json)
        #expect(response.tokens == AuthTokens(accessToken: "new", refreshToken: nil))
    }

    @Test func skipsMalformedProgressAndBookmarks() throws {
        let user = try decode(AuthResponse.self, UserFixtures.loginResponse).user
        #expect(user.mediaProgress.map(\.id) == ["mp-1", "mp-3"])
        #expect(
            user.bookmarks == [
                AudioBookmark(libraryItemId: "li-book-1", title: "Good bit", time: 1234.5, createdAt: 1_700_000_050_000)
            ])

        let book = user.mediaProgress[0]
        #expect(book.mediaItemType == .book)
        #expect(book.progress == 0.5)
        #expect(book.currentTime == 1862.75)
        #expect(book.ebookLocation == "epubcfi(/6/4!/4/2/1:0)")
        #expect(book.ebookProgress == 0.25)
        #expect(book.finishedAt == nil)
        #expect(book.progressKey == "li-book-1")

        let episode = user.mediaProgress[1]
        #expect(episode.mediaItemType == .podcastEpisode)
        #expect(episode.isFinished)
        #expect(episode.hideFromContinueListening)
        #expect(episode.finishedAt == 1_700_000_300_000)
        #expect(episode.progressKey == "li-pod-1-ep-1")
    }

    @Test(
        arguments: [
            ("li-1", nil, "li-1"),
            ("li-1", "", "li-1"),
            ("li-1", "ep-1", "li-1-ep-1"),
        ] as [(String, String?, String)])
    func progressKey(libraryItemID: String, episodeID: String?, expected: String) {
        #expect(MediaProgress.key(libraryItemID: libraryItemID, episodeID: episodeID) == expected)
        let progress = MediaProgress(id: "mp", libraryItemId: libraryItemID, episodeId: episodeID)
        #expect(progress.progressKey == expected)
    }

    @Test func userRoundTrips() throws {
        let user = try decode(AuthResponse.self, UserFixtures.loginResponse).user
        let data = try JSONEncoder().encode(user)
        let decoded = try JSONDecoder().decode(User.self, from: data)
        #expect(decoded == user)
        // Tokens are never stored on the user.
        #expect(String(decoding: data, as: UTF8.self).contains("access-abc") == false)
    }

    @Test func unknownEnumsRoundTrip() throws {
        let json = #"""
            {"id":"u","username":"x","type":"superuser","mediaProgress":[{"id":"mp","libraryItemId":"li",\#
            "mediaItemType":"video"}]}
            """#
        let user = try decode(User.self, json)
        #expect(user.type == .unknown("superuser"))
        #expect(user.mediaProgress.first?.mediaItemType == .unknown("video"))
        let decoded = try JSONDecoder().decode(User.self, from: JSONEncoder().encode(user))
        #expect(decoded.type.rawValue == "superuser")
        #expect(decoded.mediaProgress.first?.mediaItemType?.rawValue == "video")
        #expect(AuthMethod(rawValue: "passkey").rawValue == "passkey")
    }
}

@Suite struct ServerStatusTests {
    @Test func decodesLocalOnlyStatus() throws {
        let status = try decode(ServerStatus.self, UserFixtures.statusLocal)
        #expect(status.isInit)
        #expect(status.serverVersion == "2.26.0")
        #expect(status.language == "en-us")
        #expect(status.authMethods == [.local])
        #expect(status.supportsLocalLogin)
        #expect(!status.supportsOpenID)
        #expect(status.authFormData == AuthFormData())
    }

    @Test func decodesOpenIDStatus() throws {
        let status = try decode(ServerStatus.self, UserFixtures.statusOpenID)
        #expect(status.authMethods == [.local, .openID, .unknown("passkey")])
        #expect(status.supportsLocalLogin)
        #expect(status.supportsOpenID)
        #expect(status.authFormData?.authOpenIDButtonText == "Sign in with SSO")
        #expect(status.authFormData?.authOpenIDAutoLaunch == true)
        #expect(status.authFormData?.authLoginCustomMessage == "<p>Hi</p>")
    }

    @Test func decodesUninitialisedStatus() throws {
        let status = try decode(ServerStatus.self, UserFixtures.statusUninitialised)
        #expect(!status.isInit)
        #expect(status.authMethods.isEmpty)
        #expect(status.supportsLocalLogin)
    }

    @Test func rejectsStatusWithoutIsInit() {
        #expect(throws: DecodingError.self) {
            try decode(ServerStatus.self, #"{"status":"ok"}"#)
        }
    }

    @Test func openIDOnlyStatusDisablesLocalLogin() throws {
        let status = try decode(ServerStatus.self, #"{"isInit":true,"authMethods":["openid"]}"#)
        #expect(!status.supportsLocalLogin)
        #expect(status.supportsOpenID)
        #expect(status.authFormData == nil)
    }
}

@Suite struct StatsModelTests {
    @Test func decodesListeningStats() throws {
        let stats = try decode(ListeningStats.self, UserFixtures.listeningStats)
        #expect(stats.totalTime == 5400.5)
        #expect(stats.today == 1800.5)
        #expect(stats.days["2024-03-01"] == 3600)
        #expect(stats.dayOfWeek["Saturday"] == 1800.5)
        #expect(stats.items.count == 2)
        let book = try #require(stats.items["li-book-1"])
        #expect(book.timeListening == 3600)
        #expect(book.mediaMetadata?.title == "The First Book")
        #expect(book.mediaMetadata?.authors?.map(\.name) == ["Author One"])
        #expect(book.lastUpdate == nil)
        #expect(stats.items["li-pod-1"]?.mediaMetadata?.author == "Host")
        // The session with a null libraryItemId is skipped.
        #expect(stats.recentSessions.map(\.id) == ["ps-1"])
        #expect(stats.recentSessions.first?.dayOfWeek == "Friday")
    }

    @Test func decodesEmptyListeningStats() throws {
        let json = #"{"totalTime":0,"items":{},"days":{},"dayOfWeek":{},"today":0,"recentSessions":[]}"#
        #expect(try decode(ListeningStats.self, json) == ListeningStats())
    }

    @Test func decodesUserYearStats() throws {
        let stats = try decode(UserYearStats.self, UserFixtures.userYearStats)
        #expect(stats.totalListeningSessions == 42)
        #expect(stats.totalPodcastListeningTime == 10000)
        #expect(stats.topAuthors.map(\.name) == ["Author One", "Author Two"])
        #expect(stats.topGenres == [YearStatsGenreTime(genre: "Fantasy", time: 60000)])
        #expect(stats.mostListenedNarrator == YearStatsNameTime(name: "Narrator One", time: 40000))
        #expect(stats.mostListenedMonth == YearStatsMonthTime(month: 2, time: 20000))
        #expect(stats.numBooksFinished == 3)
        #expect(stats.numBooksListened == 5)
        #expect(stats.longestAudiobookFinished?.finishedAt == "2024-03-01T12:00:00.000Z")
        #expect(stats.booksWithCovers == ["li-book-2"])
        #expect(stats.finishedBooksWithCovers == ["li-book-1"])
    }

    @Test func decodesEmptyUserYearStats() throws {
        #expect(try decode(UserYearStats.self, UserFixtures.emptyUserYearStats) == UserYearStats())
    }

    @Test func decodesServerYearStats() throws {
        let stats = try decode(ServerYearStats.self, UserFixtures.serverYearStats)
        #expect(stats.numListeningSessions == 120)
        #expect(stats.numAuthorsAdded == 4)
        #expect(stats.totalBooksAddedSize == 5_368_709_120)
        #expect(stats.totalBooksSize == 10_737_418_240)
        #expect(stats.totalBooksDuration == 720_000.75)
        #expect(stats.totalListeningTime == 250_000.5)
        #expect(stats.numBooks == 20)
        #expect(stats.booksAddedWithCovers.count == 2)
        #expect(stats.topNarrators == [YearStatsNameTime(name: "Narrator One", time: 90000)])
        #expect(stats.topGenres.first?.genre == "Fantasy")
    }
}
