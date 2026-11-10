// Scrubbed server responses (Audiobookshelf 2.26), minified.
enum Fixtures {
    /// `GET /api/libraries` → `libraries[0]`.
    static let library = """
        {"id":"lib-books","name":"Audiobooks","folders":[{"id":"fol-1","fullPath":"/audiobooks","libraryId":"lib-books",\
        "addedAt":1700000000000}],"displayOrder":1,"icon":"audiobookshelf","mediaType":"book","provider":"audible",\
        "settings":{"coverAspectRatio":1,"disableWatcher":false,"skipMatchingMediaWithAsin":false,\
        "skipMatchingMediaWithIsbn":false,"autoScanCronExpression":null,"audiobooksOnly":false,\
        "epubsAllowScriptedContent":false,"hideSingleBookSeries":false,"onlyShowLaterBooksInContinueSeries":false,\
        "metadataPrecedence":["folderStructure","audioMetatags","nfoFile","txtFiles","opfFile","absMetadata"],\
        "markAsFinishedPercentComplete":null,"markAsFinishedTimeRemaining":10},"lastScan":1700000500000,\
        "lastScanVersion":"2.26.0","createdAt":1700000000000,"lastUpdate":1700000600000}
        """

    /// `GET /api/items/:id?expanded=1` for a single-file M4B book with an ebook.
    static let singleFileBook = """
        {"id":"li-book-1","ino":"649644248522215260","oldLibraryItemId":null,"libraryId":"lib-books",\
        "folderId":"fol-1","path":"/audiobooks/Author One/Book One.m4b","relPath":"Author One/Book One.m4b",\
        "isFile":true,"mtimeMs":1700000001000,"ctimeMs":1700000002000,"birthtimeMs":0,"addedAt":1700000003000,\
        "updatedAt":1700000004000,"lastScan":1700000005000,"scanVersion":"2.26.0","isMissing":false,\
        "isInvalid":false,"mediaType":"book","media":{"id":"book-1","libraryItemId":"li-book-1","metadata":\
        {"title":"The First Book","titleIgnorePrefix":"First Book, The","subtitle":null,"authors":[{"id":"au-1",\
        "name":"Author One"}],"narrators":["Narrator One"],"series":[{"id":"se-1","name":"Saga","sequence":"1"}],\
        "genres":["Fantasy"],"publishedYear":"2020","publishedDate":null,"publisher":"Pub","description":\
        "<p>A book.</p>","descriptionPlain":"A book.","isbn":null,"asin":"B000000001","language":"English",\
        "explicit":false,"abridged":false,"authorName":"Author One","authorNameLF":"One, Author",\
        "narratorName":"Narrator One","seriesName":"Saga #1"},"coverPath":"/metadata/items/li-book-1/cover.jpg",\
        "tags":["favourite"],"audioFiles":[{"index":1,"ino":"649644248522215260","metadata":{"filename":\
        "Book One.m4b","ext":".m4b","path":"/audiobooks/Author One/Book One.m4b","relPath":"Book One.m4b",\
        "size":104857600,"mtimeMs":1700000001000,"ctimeMs":1700000002000,"birthtimeMs":0},"addedAt":1700000003000,\
        "updatedAt":1700000004000,"trackNumFromMeta":1,"discNumFromMeta":null,"trackNumFromFilename":null,\
        "discNumFromFilename":null,"manuallyVerified":false,"exclude":false,"error":null,"format":"MP4A",\
        "duration":3725.5,"bitRate":128000,"language":null,"codec":"aac","timeBase":"1/44100","channels":2,\
        "channelLayout":"stereo","chapters":[],"embeddedCoverArt":"mjpeg","metaTags":{"tagTitle":"The First Book"},\
        "mimeType":"audio/mp4"}],"chapters":[{"id":0,"start":0,"end":1800.25,"title":"Chapter 1"},{"id":1,\
        "start":1800.25,"end":3725.5,"title":"Chapter 2"}],"ebookFile":{"ino":"649644248522215261","metadata":\
        {"filename":"Book One.epub","ext":".epub","path":"/audiobooks/Author One/Book One.epub","relPath":\
        "Book One.epub","size":524288},"ebookFormat":"epub","addedAt":1700000003000,"updatedAt":1700000004000},\
        "duration":3725.5,"size":104857600,"tracks":[{"index":1,"startOffset":0,"duration":3725.5,"title":\
        "Book One.m4b","contentUrl":"/api/items/li-book-1/file/649644248522215260","mimeType":"audio/mp4",\
        "codec":"aac","metadata":{"filename":"Book One.m4b","ext":".m4b","path":\
        "/audiobooks/Author One/Book One.m4b","relPath":"Book One.m4b","size":104857600}}]},"libraryFiles":\
        [{"ino":"649644248522215260","metadata":{"filename":"Book One.m4b","ext":".m4b","path":\
        "/audiobooks/Author One/Book One.m4b","relPath":"Book One.m4b","size":104857600},"isSupplementary":null,\
        "addedAt":1700000003000,"updatedAt":1700000004000,"fileType":"audio"}],"size":105381888}
        """

    /// `GET /api/items/:id?expanded=1` for a multi-file MP3 book, with fields the server may omit dropped.
    static let multiFileBook = """
        {"id":"li-book-2","ino":"1","libraryId":"lib-books","folderId":"fol-1","path":"/audiobooks/Two",\
        "relPath":"Two","isFile":false,"addedAt":1700000003000,"updatedAt":1700000004000,"isMissing":false,\
        "isInvalid":false,"mediaType":"book","media":{"id":"book-2","libraryItemId":"li-book-2","metadata":\
        {"title":"Book Two","authors":[],"narrators":[],"series":[],"genres":[],"explicit":false},"coverPath":null,\
        "tags":[],"audioFiles":[{"index":1,"ino":"11","metadata":{"filename":"01.mp3","ext":".mp3","path":\
        "/audiobooks/Two/01.mp3","relPath":"01.mp3","size":1000},"duration":600,"mimeType":"audio/mpeg"},\
        {"index":2,"ino":"12","metadata":{"filename":"02.mp3","ext":".mp3","path":"/audiobooks/Two/02.mp3",\
        "relPath":"02.mp3","size":1000},"duration":400.5,"mimeType":"audio/mpeg"}],"chapters":[],\
        "ebookFile":null,"duration":1000.5,"size":2000,"tracks":[{"index":1,"startOffset":0,"duration":600,\
        "title":"01.mp3","contentUrl":"/api/items/li-book-2/file/11","mimeType":"audio/mpeg","codec":"mp3"},\
        {"index":2,"startOffset":600,"duration":400.5,"title":"02.mp3","contentUrl":"/api/items/li-book-2/file/12",\
        "mimeType":"audio/mpeg","codec":"mp3"}]},"libraryFiles":[],"size":2000}
        """

    /// A minified book item, as in library lists and shelves.
    static let minifiedBook = """
        {"id":"li-book-1","ino":"649644248522215260","oldLibraryItemId":null,"libraryId":"lib-books",\
        "folderId":"fol-1","path":"/audiobooks/Author One/Book One.m4b","relPath":"Author One/Book One.m4b",\
        "isFile":true,"mtimeMs":1700000001000,"ctimeMs":1700000002000,"birthtimeMs":0,"addedAt":1700000003000,\
        "updatedAt":1700000004000,"isMissing":false,"isInvalid":false,"mediaType":"book","media":{"id":"book-1",\
        "metadata":{"title":"The First Book","titleIgnorePrefix":"First Book, The","subtitle":null,\
        "authorName":"Author One","authorNameLF":"One, Author","narratorName":"Narrator One","seriesName":"Saga #1",\
        "genres":["Fantasy"],"publishedYear":"2020","publishedDate":null,"publisher":"Pub","description":null,\
        "isbn":null,"asin":"B000000001","language":"English","explicit":false,"abridged":false},"coverPath":\
        "/metadata/items/li-book-1/cover.jpg","tags":[],"numTracks":1,"numAudioFiles":1,"numChapters":2,\
        "duration":3725.5,"size":104857600,"ebookFormat":"epub"},"numFiles":2,"size":105381888}
        """

    static let podcastEpisode = """
        {"libraryItemId":"li-pod-1","podcastId":"pod-1","id":"ep-1","oldEpisodeId":null,"index":1,"season":"1",\
        "episode":"12","episodeType":"full","title":"Episode Twelve","subtitle":"Sub","description":"<p>Ep</p>",\
        "enclosure":{"url":"https://feed.example.com/ep12.mp3","type":"audio/mpeg","length":"3000000"},\
        "guid":"guid-12","pubDate":"Mon, 06 Nov 2023 10:00:00 GMT","chapters":[{"id":0,"start":0,"end":60,\
        "title":"Intro"}],"audioFile":{"index":1,"ino":"21","metadata":{"filename":"ep12.mp3","ext":".mp3",\
        "path":"/podcasts/Show/ep12.mp3","relPath":"ep12.mp3","size":3000000},"duration":1500,\
        "mimeType":"audio/mpeg"},"audioTrack":{"index":1,"startOffset":0,"duration":1500,"title":"ep12.mp3",\
        "contentUrl":"/api/items/li-pod-1/file/21","mimeType":"audio/mpeg"},"publishedAt":1699264800000,\
        "addedAt":1699300000000,"updatedAt":1699300000000,"size":3000000,"duration":1500}
        """

    /// `GET /api/items/:id?expanded=1` for a podcast. The second episode has an unknown type, no title,
    /// and an untitled chapter; the third is malformed (no `id`).
    static let podcast = """
        {"id":"li-pod-1","ino":"2","libraryId":"lib-pods","folderId":"fol-2","path":"/podcasts/Show",\
        "relPath":"Show","isFile":false,"addedAt":1699000000000,"updatedAt":1699300000000,"isMissing":false,\
        "isInvalid":false,"mediaType":"podcast","media":{"id":"pod-1","libraryItemId":"li-pod-1","metadata":\
        {"title":"The Show","titleIgnorePrefix":"Show, The","author":"Host","description":"A show",\
        "releaseDate":"2023-11-06T10:00:00Z","genres":["Technology"],"feedUrl":"https://feed.example.com/rss",\
        "imageUrl":"https://feed.example.com/art.jpg","itunesPageUrl":null,"itunesId":"123","itunesArtistId":null,\
        "explicit":false,"language":"en","type":"episodic"},"coverPath":"/metadata/items/li-pod-1/cover.jpg",\
        "tags":[],"episodes":[\(podcastEpisode),{"libraryItemId":"li-pod-1","podcastId":"pod-1","id":"ep-2",\
        "episodeType":"teaser","chapters":[{"id":0,"start":0,"end":5}]},{"title":"Broken"}],"autoDownloadEpisodes":true,\
        "autoDownloadSchedule":"0 * * * *","lastEpisodeCheck":1699300000000,"maxEpisodesToKeep":0,\
        "maxNewEpisodesToDownload":3,"size":3000000},"libraryFiles":[],"size":3000000}
        """

    /// `GET /api/libraries/:id/personalized?minified=1` (podcast and book shelves, trimmed). The first
    /// shelf has a malformed entity (no `libraryId`).
    static let shelves = """
        [{"id":"continue-listening","label":"Continue Listening","labelStringKey":"LabelContinueListening",\
        "type":"book","entities":[\(minifiedBook),{"id":"li-bad","mediaType":"book"}],"total":1,"category":"recentlyListened"},\
        {"id":"newest-episodes","label":"Newest Episodes","labelStringKey":"LabelNewestEpisodes","type":"episode",\
        "entities":[{"id":"li-pod-1","libraryId":"lib-pods","mediaType":"podcast","media":{"id":"pod-1",\
        "metadata":{"title":"The Show","author":"Host"},"coverPath":null,"tags":[],"numEpisodes":2},\
        "recentEpisode":\(podcastEpisode),"numEpisodesIncomplete":1}],"total":1},\
        {"id":"recent-series","label":"Recent Series","labelStringKey":"LabelRecentSeries","type":"series",\
        "entities":[{"id":"se-1","name":"Saga","nameIgnorePrefix":"Saga","addedAt":1700000003000,\
        "books":[\(minifiedBook)],"inProgress":true}],"total":1},\
        {"id":"newest-authors","label":"Newest Authors","labelStringKey":"LabelNewestAuthors","type":"authors",\
        "entities":[{"id":"au-1","asin":null,"name":"Author One","description":null,"imagePath":null,\
        "libraryId":"lib-books","addedAt":1700000003000,"updatedAt":1700000004000,"numBooks":1}],"total":1},\
        {"id":"future-shelf","label":"Future","type":"carousel","entities":[{"anything":1}],"total":1}]
        """

    /// `POST /api/items/:id/play`.
    static let session = """
        {"id":"ps-1","userId":"user-1","libraryId":"lib-books","libraryItemId":"li-book-1","bookId":"book-1",\
        "episodeId":null,"mediaType":"book","mediaMetadata":{"title":"The First Book","subtitle":null,\
        "authors":[{"id":"au-1","name":"Author One"}],"narrators":["Narrator One"],"series":[{"id":"se-1",\
        "name":"Saga","sequence":"1"}],"genres":[],"publishedYear":"2020","explicit":false},"chapters":[{"id":0,\
        "start":0,"end":1800.25,"title":"Chapter 1"},{"id":1,"start":1800.25,"end":3725.5,"title":"Chapter 2"}],\
        "displayTitle":"The First Book","displayAuthor":"Author One","coverPath":"/metadata/items/li-book-1/cover.jpg",\
        "duration":3725.5,"playMethod":0,"mediaPlayer":"AVPlayer","deviceInfo":{"id":"dev-1","userId":"user-1",\
        "deviceId":"ABCD","ipAddress":"192.0.2.1","osName":"iOS","osVersion":"27.0","deviceType":null,\
        "manufacturer":"Apple","model":"iPhone18,1","sdkVersion":null,"clientName":"Abs iOS",\
        "clientVersion":"0.1.0"},"serverVersion":"2.26.0","date":"2023-11-14","dayOfWeek":"Tuesday",\
        "timeListening":0,"startTime":120.5,"currentTime":120.5,"startedAt":1700000100000,\
        "updatedAt":1700000100000,"audioTracks":[{"index":1,"startOffset":0,"duration":3725.5,"title":\
        "Book One.m4b","contentUrl":"/public/session/ps-1/track/1","mimeType":"audio/mp4","codec":"aac"}],\
        "videoTrack":null,"libraryItem":\(singleFileBook)}
        """

    /// `GET /api/playlists/:id`.
    static let playlist = """
        {"id":"pl-1","libraryId":"lib-pods","userId":"user-1","name":"Commute","description":null,\
        "coverPath":null,"items":[{"libraryItemId":"li-pod-1","episodeId":"ep-1","episode":\(podcastEpisode),\
        "libraryItem":{"id":"li-pod-1","libraryId":"lib-pods","mediaType":"podcast","media":{"id":"pod-1",\
        "metadata":{"title":"The Show"},"numEpisodes":2}}},{"libraryItemId":"li-book-1","libraryItem":\
        \(minifiedBook)}],"lastUpdate":1700000200000,"createdAt":1700000100000}
        """

    /// `GET /api/collections/:id`.
    static let collection = """
        {"id":"col-1","libraryId":"lib-books","name":"Favourites","description":"Best","cover":null,\
        "coverFullPath":null,"books":[\(singleFileBook)],"lastUpdate":1700000200000,"createdAt":1700000100000}
        """

    /// `GET /api/libraries/:id/items?collapseseries=1&filter=series.<id>` (one item, trimmed).
    static let collapsedSeriesItem = """
        {"id":"li-book-3","libraryId":"lib-books","mediaType":"book","media":{"id":"book-3","metadata":\
        {"title":"Saga Omnibus","seriesName":"Saga"},"numTracks":0},"series":{"id":"se-1","name":"Saga",\
        "sequence":"1-3"},"collapsedSeries":{"id":"se-2","name":"The Subseries","nameIgnorePrefix":"Subseries",\
        "sequence":"4","numBooks":2,"libraryItemIds":["li-book-4","li-book-5"]}}
        """

    /// An expanded episode whose track has `index: null` (servers 2.26.0–2.26.2).
    static let nullIndexEpisode = """
        {"libraryItemId":"li-pod-1","podcastId":"pod-1","id":"ep-3","index":null,"title":"Episode Three",\
        "audioFile":{"index":null,"ino":"23","metadata":{"filename":"ep3.mp3","ext":".mp3","path":\
        "/podcasts/Show/ep3.mp3","relPath":"ep3.mp3","size":2000000},"duration":900,"mimeType":"audio/mpeg"},\
        "audioTrack":{"index":null,"startOffset":0,"duration":900,"title":"ep3.mp3","contentUrl":\
        "/api/items/li-pod-1/file/23","mimeType":"audio/mpeg"},"duration":900,"size":2000000}
        """

    /// `POST /api/items/:id/play/:episodeId` on a 2.26.0–2.26.2 server: the track has `index: null`.
    static let nullIndexEpisodeSession = """
        {"id":"ps-3","userId":"user-1","libraryId":"lib-pods","libraryItemId":"li-pod-1","episodeId":"ep-3",\
        "mediaType":"podcast","mediaMetadata":{"title":"The Show","author":"Host"},"chapters":[],\
        "displayTitle":"Episode Three","displayAuthor":"Host","duration":900,"playMethod":0,"timeListening":0,\
        "startTime":0,"currentTime":0,"startedAt":1700000100000,"updatedAt":1700000100000,"audioTracks":\
        [{"index":null,"startOffset":0,"duration":900,"title":"ep3.mp3","contentUrl":\
        "/api/items/li-pod-1/file/23","mimeType":"audio/mpeg"}],"libraryItem":{"id":"li-pod-1",\
        "libraryId":"lib-pods","mediaType":"podcast","media":{"id":"pod-1","metadata":{"title":"The Show"},\
        "episodes":[\(nullIndexEpisode)]}}}
        """

    /// A session started by the Android app, as the server returns it: `sdkVersion` is a string.
    static let androidSession = """
        {"id":"ps-4","userId":"user-1","libraryItemId":"li-book-1","mediaType":"book","playMethod":0,\
        "deviceInfo":{"id":"dev-2","userId":"user-1","deviceId":"android-1","ipAddress":"192.0.2.2",\
        "clientVersion":"0.9.81","manufacturer":"Google","model":"Pixel 9","sdkVersion":"35",\
        "clientName":"Abs Android","deviceName":"Google Pixel 9"}}
        """

    /// A session whose device info has a numeric `sdkVersion`, as older servers stored it.
    static let numericSDKVersionSession = """
        {"id":"ps-5","libraryItemId":"li-book-1","mediaType":"book","deviceInfo":{"deviceId":"android-2",\
        "sdkVersion":34,"clientName":"Abs Android"}}
        """

    /// An expanded book whose file-system times have fractional milliseconds, at the top level and in
    /// nested file metadata.
    static let fractionalTimestampsItem = """
        {"id":"li-book-6","libraryId":"lib-books","path":"/audiobooks/Six","isFile":false,\
        "mtimeMs":1650621074299.0059,"ctimeMs":1650621074299.5,"birthtimeMs":1650621070000.25,\
        "addedAt":1700000003000,"mediaType":"book","media":{"id":"book-6","metadata":{"title":"Six"},\
        "audioFiles":[{"index":1,"ino":"61","metadata":{"filename":"01.mp3","ext":".mp3","path":\
        "/audiobooks/Six/01.mp3","relPath":"01.mp3","size":1000,"mtimeMs":1650621074299.0059,\
        "ctimeMs":1650621074299.0059,"birthtimeMs":1650621070000.123},"duration":60}],"tracks":[{"index":1,\
        "startOffset":0,"duration":60,"metadata":{"filename":"01.mp3","path":"/audiobooks/Six/01.mp3",\
        "mtimeMs":1650621074299.0059}}]},"libraryFiles":[{"ino":"61","metadata":{"filename":"01.mp3",\
        "path":"/audiobooks/Six/01.mp3","size":1000,"mtimeMs":1650621074299.0059,"ctimeMs":1650621074299.0059,\
        "birthtimeMs":1650621070000.123}}]}
        """
}
