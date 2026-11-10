import Foundation

/// Deterministic public-domain sample data for previews, tests and demo mode. IDs are stable
/// and nothing here reads the clock or a random source.
public enum SampleLibrary {
    public static let libraryID = "lib_sample"

    // MARK: Authors

    public static let authors: [Author] = [
        Author(id: "aut_austen", name: "Jane Austen", libraryId: libraryID, updatedAt: 1, numBooks: 2),
        Author(id: "aut_shelley", name: "Mary Shelley", libraryId: libraryID, numBooks: 1),
        Author(id: "aut_burroughs", name: "Edgar Rice Burroughs", libraryId: libraryID, numBooks: 3),
        Author(id: "aut_doyle", name: "Arthur Conan Doyle", libraryId: libraryID, numBooks: 1),
    ]

    // MARK: Series

    private static let barsoom = Series(id: "ser_barsoom", name: "Barsoom", libraryId: libraryID)

    // MARK: Books

    public static let prideAndPrejudice = book(
        "li_pride", "Pride and Prejudice", author: "Jane Austen", hours: 11.6, updatedAt: 10)
    public static let emma = book("li_emma", "Emma", author: "Jane Austen", hours: 16.2, updatedAt: 11)
    public static let frankenstein = book(
        "li_frankenstein", "Frankenstein; or, The Modern Prometheus", author: "Mary Shelley", hours: 8.4,
        updatedAt: 12, abridged: true)
    public static let sherlock = book(
        "li_sherlock", "The Adventures of Sherlock Holmes", author: "Arthur Conan Doyle", hours: 10.2, updatedAt: 13)
    public static let noCover = book(
        "li_nocover", "A Book Without a Cover", author: "Anonymous", hours: 1.5, updatedAt: nil, hasCover: false)
    public static let princessOfMars = book(
        "li_barsoom_1", "A Princess of Mars", author: "Edgar Rice Burroughs", hours: 9.1, updatedAt: 14,
        series: barsoom, sequence: "1")
    public static let godsOfMars = book(
        "li_barsoom_2", "The Gods of Mars", author: "Edgar Rice Burroughs", hours: 9.9, updatedAt: 15,
        series: barsoom, sequence: "2")
    public static let warlordOfMars = book(
        "li_barsoom_3", "The Warlord of Mars", author: "Edgar Rice Burroughs", hours: 8.7, updatedAt: 16,
        series: barsoom, sequence: "3", explicit: true)
    public static let missing = book(
        "li_missing", "A Missing Book", author: "Anonymous", hours: 2, updatedAt: 17, isMissing: true)

    public static let books: [LibraryItem] = [
        prideAndPrejudice, emma, frankenstein, sherlock, princessOfMars, godsOfMars, warlordOfMars, noCover,
    ]

    // MARK: Podcast

    public static let episodes: [PodcastEpisode] = [
        PodcastEpisode(id: "ep_2", title: "Episode 2: A Scandal in Bohemia", duration: 1_800),
        PodcastEpisode(id: "ep_1", title: "Episode 1: The Red-Headed League", duration: 2_100),
    ]

    public static let podcast = LibraryItem(
        id: "li_podcast", libraryId: libraryID, updatedAt: 20, mediaType: .podcast,
        media: .podcast(
            Podcast(
                id: "pod_1",
                metadata: PodcastMetadata(title: "Classic Tales", author: "Public Domain Players"),
                coverPath: "/metadata/items/li_podcast/cover.jpg", numEpisodes: 2)))

    /// The podcast as it appears on an episode shelf.
    public static let episodeItems: [LibraryItem] = episodes.map { episode in
        LibraryItem(
            id: "li_podcast", libraryId: libraryID, updatedAt: 20, mediaType: .podcast,
            media: podcast.media, recentEpisode: episode)
    }

    // MARK: Series, collections, playlists

    public static let series: [Series] = [
        Series(
            id: "ser_barsoom", name: "Barsoom", libraryId: libraryID,
            books: [princessOfMars, godsOfMars, warlordOfMars], totalDuration: 27.7 * 3_600),
        Series(
            id: "ser_austen", name: "Austen Novels", libraryId: libraryID, books: [prideAndPrejudice, emma],
            totalDuration: 27.8 * 3_600),
    ]

    public static let collections: [LibraryCollection] = [
        LibraryCollection(
            id: "col_classics", libraryId: libraryID, name: "Classics", books: [prideAndPrejudice, frankenstein]),
        LibraryCollection(id: "col_empty", libraryId: libraryID, name: "Empty Collection", books: []),
    ]

    public static let playlists: [Playlist] = [
        Playlist(
            id: "pl_commute", libraryId: libraryID, name: "Commute",
            items: [
                PlaylistItem(libraryItemId: sherlock.id, libraryItem: sherlock),
                PlaylistItem(
                    libraryItemId: "li_podcast", episodeId: "ep_1", episode: episodes[1], libraryItem: podcast),
            ])
    ]

    // MARK: Progress

    /// Progress by ``ItemSummary/progressKey``: one finished, one in progress, one in progress
    /// and hidden from continue listening.
    public static let progress: [String: ItemProgress] = [
        prideAndPrejudice.id: ItemProgress(fraction: 1, isFinished: true),
        frankenstein.id: ItemProgress(fraction: 0.42),
        sherlock.id: ItemProgress(fraction: 0.15, isHiddenFromContinue: true),
        "li_podcast-ep_1": ItemProgress(fraction: 0.6),
    ]

    // MARK: Shelves

    public static let shelves: [Shelf] = [
        Shelf(
            id: "continue-listening", label: "Continue Listening", labelStringKey: "LabelContinueListening",
            type: .book, entities: .libraryItems([frankenstein, sherlock])),
        Shelf(
            id: "recent-episodes", label: "Newest Episodes", labelStringKey: "LabelNewestEpisodes",
            type: .episode, entities: .libraryItems(episodeItems)),
        Shelf(
            id: "recently-added", label: "Recently Added", labelStringKey: "LabelRecentlyAdded", type: .book,
            entities: .libraryItems(books)),
        Shelf(id: "recent-series", label: "Recent Series", type: .series, entities: .series(series)),
        Shelf(id: "newest-authors", label: "Newest Authors", type: .authors, entities: .authors(authors)),
    ]

    // MARK: Builder

    private static func book(
        _ id: String, _ title: String, author: String, hours: Double, updatedAt: Int?, hasCover: Bool = true,
        abridged: Bool = false, series: Series? = nil, sequence: String? = nil, explicit: Bool = false,
        isMissing: Bool = false
    ) -> LibraryItem {
        let seriesName = series.map { "\($0.name) #\(sequence ?? "")" }
        return LibraryItem(
            id: id, libraryId: libraryID, updatedAt: updatedAt, isMissing: isMissing, mediaType: .book,
            media: .book(
                Book(
                    id: "book_\(id)",
                    metadata: BookMetadata(
                        title: title, explicit: explicit, abridged: abridged, authorName: author,
                        seriesName: seriesName),
                    coverPath: hasCover ? "/metadata/items/\(id)/cover.jpg" : nil, duration: hours * 3_600,
                    numTracks: 1)))
    }
}
