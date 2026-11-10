// Scrubbed server responses (Audiobookshelf 2.26+ unless noted), minified.
enum UserFixtures {
    /// `POST /login` with `x-return-tokens: true` (2.26+). The user has one malformed progress
    /// entry (`libraryItemId: null`), one malformed bookmark (no `time`), a bookmark whose `time`
    /// is a numeric string, and one malformed e-reader device (no `name`).
    static let loginResponse = """
        {"user":{"id":"usr-1","username":"david","email":null,"type":"admin","token":null,"isOldToken":false,\
        "mediaProgress":[{"id":"mp-1","userId":"usr-1","libraryItemId":"li-book-1","episodeId":null,\
        "mediaItemId":"book-1","mediaItemType":"book","duration":3725.5,"progress":0.5,"currentTime":1862.75,\
        "isFinished":false,"hideFromContinueListening":false,"ebookLocation":"epubcfi(/6/4!/4/2/1:0)",\
        "ebookProgress":0.25,"lastUpdate":1700000100000,"startedAt":1700000000000,"finishedAt":null},\
        {"id":"mp-2","userId":"usr-1","libraryItemId":null,"episodeId":null,"mediaItemId":"book-x",\
        "mediaItemType":"book","duration":10,"progress":0,"currentTime":0,"isFinished":false,\
        "hideFromContinueListening":false,"ebookLocation":null,"ebookProgress":null,"lastUpdate":1700000100000,\
        "startedAt":1700000000000,"finishedAt":null},{"id":"mp-3","userId":"usr-1","libraryItemId":"li-pod-1",\
        "episodeId":"ep-1","mediaItemId":"ep-1","mediaItemType":"podcastEpisode","duration":1800,"progress":1,\
        "currentTime":1800,"isFinished":true,"hideFromContinueListening":true,"ebookLocation":null,\
        "ebookProgress":null,"lastUpdate":1700000300000,"startedAt":1700000200000,"finishedAt":1700000300000}],\
        "seriesHideFromContinueListening":["se-1"],"bookmarks":[{"libraryItemId":"li-book-1","title":"Good bit",\
        "time":1234.5,"createdAt":1700000050000},{"libraryItemId":"li-book-1","title":"Broken"},\
        {"libraryItemId":"li-book-1","title":"Stringy","time":"42.5","createdAt":1700000060000}],\
        "isActive":true,"isLocked":false,"lastSeen":1700000400000,"createdAt":1690000000000,"permissions":\
        {"download":true,"update":true,"delete":false,"upload":true,"createEreader":true,\
        "accessAllLibraries":false,"accessAllTags":false,"accessExplicitContent":true,\
        "selectedTagsNotAccessible":true},"librariesAccessible":["lib-books"],"itemTagsSelected":["spoilers"],\
        "hasOpenIDLink":false,"refreshToken":"refresh-abc","accessToken":"access-abc"},\
        "userDefaultLibraryId":"lib-books","serverSettings":{"id":"server-settings","scannerFindCovers":false,\
        "sortingIgnorePrefix":true,"sortingPrefixes":["the","a"],"chromecastEnabled":false,\
        "dateFormat":"MM/dd/yyyy","timeFormat":"HH:mm","language":"en-us","logLevel":2,"version":"2.26.0",\
        "buildNumber":1,"authActiveAuthMethods":["local"],"timeZone":"America/Toronto"},\
        "ereaderDevices":[{"name":"Kindle","email":"me@kindle.example","availabilityOption":"specificUsers",\
        "users":["usr-1"]},{"email":"broken@example.com"},{"name":"Kobo","email":"kobo@example.com",\
        "availabilityOption":"everyone","users":null}],"Source":"docker"}
        """

    /// `GET /status` with local sign-in only.
    static let statusLocal = """
        {"app":"audiobookshelf","serverVersion":"2.26.0","isInit":true,"language":"en-us",\
        "authMethods":["local"],"authFormData":{"authLoginCustomMessage":null}}
        """

    /// `GET /status` with OpenID and an auth method this client doesn't know.
    static let statusOpenID = """
        {"app":"audiobookshelf","serverVersion":"2.30.0","isInit":true,"language":"en-us",\
        "authMethods":["local","openid","passkey"],"authFormData":{"authLoginCustomMessage":"<p>Hi</p>",\
        "authOpenIDButtonText":"Sign in with SSO","authOpenIDAutoLaunch":true}}
        """

    /// `GET /status` before the root user exists.
    static let statusUninitialised = """
        {"app":"audiobookshelf","serverVersion":"2.26.0","isInit":false,"language":"en-us","authMethods":[],\
        "authFormData":{"authLoginCustomMessage":null},"ConfigPath":"/config","MetadataPath":"/metadata"}
        """

    /// `GET /api/me/listening-stats`. The second recent session has a null `libraryItemId`.
    static let listeningStats = """
        {"totalTime":5400.5,"items":{"li-book-1":{"id":"li-book-1","timeListening":3600,"mediaMetadata":\
        {"title":"The First Book","subtitle":null,"authors":[{"id":"au-1","name":"Author One"}],\
        "narrators":["Narrator One"],"series":[],"genres":["Fantasy"]}},"li-pod-1":{"id":"li-pod-1",\
        "timeListening":1800.5,"mediaMetadata":{"title":"The Show","author":"Host"}}},\
        "days":{"2024-03-01":3600,"2024-03-02":1800.5},"dayOfWeek":{"Friday":3600,"Saturday":1800.5},\
        "today":1800.5,"recentSessions":[{"id":"ps-1","userId":"usr-1","libraryId":"lib-books",\
        "libraryItemId":"li-book-1","bookId":"book-1","episodeId":null,"mediaType":"book","mediaMetadata":\
        {"title":"The First Book","authors":[{"id":"au-1","name":"Author One"}]},"chapters":[],\
        "displayTitle":"The First Book","displayAuthor":"Author One","coverPath":null,"duration":3725.5,\
        "playMethod":0,"mediaPlayer":"html5","deviceInfo":null,"serverVersion":"2.26.0","date":"2024-03-01",\
        "dayOfWeek":"Friday","timeListening":3600,"startTime":0,"currentTime":3600,"startedAt":1709280000000,\
        "updatedAt":1709283600000},{"id":"ps-2","libraryItemId":null,"mediaType":"book","timeListening":1}]}
        """

    /// `GET /api/me/listening-stats` with values old rows can produce: a `"null"` item key with a
    /// null `id`, malformed `mediaMetadata`, numeric strings, and null or non-numeric day totals.
    static let lenientListeningStats = """
        {"totalTime":"12.5","items":{"null":{"id":null,"timeListening":"7.5","mediaMetadata":"oops"},\
        "li-1":{"id":"li-1","timeListening":5,"mediaMetadata":{"title":5}}},"days":{"2024-03-01":"7.5",\
        "2024-03-02":null,"2024-03-03":"abc","2024-03-04":5},"dayOfWeek":{"Friday":7.5,"Saturday":null},\
        "today":null,"recentSessions":[]}
        """

    /// `GET /api/me/stats/year/2024` with a string total and objects whose NaN times became null.
    static let lenientUserYearStats = """
        {"totalListeningSessions":2,"totalListeningTime":"100","mostListenedNarrator":{"name":"N","time":null},\
        "mostListenedMonth":{"month":1,"time":null},"longestAudiobookFinished":{"id":null}}
        """

    /// `GET /api/me/stats/year/2024`.
    static let userYearStats = """
        {"totalListeningSessions":42,"totalListeningTime":90000,"totalBookListeningTime":80000,\
        "totalPodcastListeningTime":10000,"topAuthors":[{"name":"Author One","time":50000},\
        {"name":"Author Two","time":30000}],"topGenres":[{"genre":"Fantasy","time":60000}],\
        "mostListenedNarrator":{"time":40000,"name":"Narrator One"},"mostListenedMonth":{"month":2,\
        "time":20000},"numBooksFinished":3,"numBooksListened":5,"longestAudiobookFinished":{"id":"book-1",\
        "title":"The First Book","duration":3726,"finishedAt":"2024-03-01T12:00:00.000Z"},\
        "booksWithCovers":["li-book-2"],"finishedBooksWithCovers":["li-book-1"]}
        """

    /// `GET /api/me/stats/year/2023` for a year without listening.
    static let emptyUserYearStats = """
        {"totalListeningSessions":0,"totalListeningTime":0,"totalBookListeningTime":0,\
        "totalPodcastListeningTime":0,"topAuthors":[],"topGenres":[],"mostListenedNarrator":null,\
        "mostListenedMonth":null,"numBooksFinished":0,"numBooksListened":0,"longestAudiobookFinished":null,\
        "booksWithCovers":[],"finishedBooksWithCovers":[]}
        """

    /// `GET /api/stats/year/2024`.
    static let serverYearStats = """
        {"numListeningSessions":120,"numBooksAdded":10,"numAuthorsAdded":4,"totalBooksAddedSize":5368709120,\
        "totalBooksAddedDuration":360000,"booksAddedWithCovers":["li-book-1","li-book-2"],\
        "totalBooksSize":10737418240,"totalBooksDuration":720000.75,"totalListeningTime":250000.5,"numBooks":20,\
        "topAuthors":[{"name":"Author One","time":100000}],"topNarrators":[{"name":"Narrator One","time":90000}],\
        "topGenres":[{"genre":"Fantasy","time":80000}]}
        """
}
