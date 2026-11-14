import ABSCore
import ABSData
import Foundation
import Testing

@testable import ABSAppModel

private let downloadLabels = CarPlayLabels(
    continueListening: "Continue", libraries: "Libraries", books: "Books", podcasts: "Podcasts", series: "Series",
    authors: "Authors", latest: "Latest", downloads: "Downloads", more: "More")
private let accountA = SessionIdentity(
    connectionID: UUID(uuidString: "00000000-0000-0000-0000-0000000000DA") ?? UUID(), userID: "user-1")
private let accountB = SessionIdentity(
    connectionID: UUID(uuidString: "00000000-0000-0000-0000-0000000000DB") ?? UUID(), userID: "user-1")
private let downloadDate = Date(timeIntervalSince1970: 1_800_000_000)

/// A downloaded book, with an audio file unless `files` says otherwise.
private func downloadedBook(
    _ id: String, author: String? = "Author", connection: SessionIdentity = accountA, addedAt offset: TimeInterval = 0,
    files: [LocalFileDTO]? = nil
) -> LocalLibraryItemDTO {
    LocalLibraryItemDTO(
        id: UUID(), serverConnectionID: connection.connectionID, serverAddress: "https://abs.example.com",
        serverUserId: "usr_1", libraryItemId: id, mediaType: .book, title: "Title \(id)", authorName: author,
        relativeDirectory: id, coverUpdatedAt: Date(timeIntervalSince1970: 1_700_000_000),
        addedAt: downloadDate.addingTimeInterval(offset), updatedAt: downloadDate,
        media: LocalMediaSnapshot(metadata: .init(title: "Title \(id)")),
        files: files ?? [audioFile("\(id)/a.mp3", episodeID: nil)])
}

/// A downloaded podcast with `episodes` downloaded, each with its audio file; `published` dates
/// them in days.
private func downloadedPodcast(
    _ id: String, episodes: [(id: String, published: Double?)], connection: SessionIdentity = accountA,
    addedAt offset: TimeInterval = 0
) -> LocalLibraryItemDTO {
    LocalLibraryItemDTO(
        id: UUID(), serverConnectionID: connection.connectionID, serverAddress: "https://abs.example.com",
        serverUserId: "usr_1", libraryItemId: id, mediaType: .podcast, title: "Show \(id)",
        relativeDirectory: id, addedAt: downloadDate.addingTimeInterval(offset), updatedAt: downloadDate,
        media: LocalMediaSnapshot(
            metadata: .init(title: "Show \(id)"),
            episodes: episodes.map {
                .init(
                    id: $0.id, title: "Episode \($0.id)",
                    publishedAt: $0.published.map { downloadDate.addingTimeInterval($0 * 86_400) })
            }),
        files: episodes.map { audioFile("\(id)/\($0.id).mp3", episodeID: $0.id) })
}

private func audioFile(_ path: String, episodeID: String?) -> LocalFileDTO {
    LocalFileDTO(
        kind: .audio, relativePath: path, filename: path, mimeType: "audio/mpeg", size: 1, episodeId: episodeID)
}

private func downloadsBuilder(items: Int = 12, serverID: UUID? = accountA.connectionID) -> CarPlayContentBuilder {
    CarPlayContentBuilder(
        limits: CarPlayLimits(maximumItemCount: items), labels: downloadLabels, serverID: serverID)
}

/// The local item store's snapshots of one connection, fed by the tests.
@MainActor
private final class LocalItemFeed {
    let stream: AsyncStream<[LocalLibraryItemDTO]>
    let continuation: AsyncStream<[LocalLibraryItemDTO]>.Continuation
    private(set) var connections: [UUID] = []

    init() {
        (stream, continuation) = AsyncStream.makeStream(of: [LocalLibraryItemDTO].self)
    }

    func model(_ identity: SessionIdentity = accountA, items: Int = 12) -> CarPlayDownloadsModel {
        CarPlayDownloadsModel(
            identity: identity,
            updates: { @MainActor connectionID in
                self.connections.append(connectionID)
                return self.stream
            }, limits: CarPlayLimits(maximumItemCount: items), labels: downloadLabels)
    }
}

/// Waits, a bounded number of turns, until `condition` holds.
@MainActor
private func until(_ condition: () -> Bool) async {
    for _ in 0..<1_000 where !condition() { await Task.yield() }
}

@MainActor
@Suite(.timeLimit(.minutes(1))) struct CarPlayDownloadsTests {
    // MARK: Builder

    @Test func downloadedBooksAndEpisodesOfTheAccountPlayWithAuthorOrPodcastAndLocalCovers() throws {
        let book = downloadedBook("b1")
        let podcast = downloadedPodcast("p1", episodes: [("old", 1), ("new", 3), ("undated", nil)])
        let list = downloadsBuilder().downloads([book, podcast])

        #expect(list.destination == .downloads && list.title == "Downloads" && list.depth == 1)
        #expect(list.rows.map(\.id) == ["b1", "p1-new", "p1-old", "p1-undated"])
        #expect(list.rows.map(\.text) == ["Title b1", "Episode new", "Episode old", "Episode undated"])
        #expect(list.rows.map(\.detail) == ["Author", "Show p1", "Show p1", "Show p1"])
        #expect(
            list.rows.map(\.action) == [
                .play(itemID: "b1", episodeID: nil), .play(itemID: "p1", episodeID: "new"),
                .play(itemID: "p1", episodeID: "old"), .play(itemID: "p1", episodeID: "undated"),
            ])
        #expect(list.rows.allSatisfy { $0.isEnabled })
        // The cover is keyed as the Downloaded shelf's, which the pipeline serves from the file.
        let image = try #require(list.rows.first?.image)
        #expect(image.serverID == accountA.connectionID && image.entityID == "b1" && image.kind == .itemCover)
        #expect(image.updatedAt == LocalDownloadedCovers.version(of: book.coverUpdatedAt))
        #expect(list.rows[1].image?.entityID == "p1")
    }

    @Test func aBooksAuthorFallsBackToItsMetadata() {
        var book = downloadedBook("b1", author: nil)
        book.media.metadata.authors = ["Ann", "Bo"]
        #expect(downloadsBuilder().downloads([book]).rows.first?.detail == "Ann, Bo")
        #expect(downloadsBuilder().downloads([downloadedBook("b2", author: nil)]).rows.first?.detail == nil)
    }

    @Test func anotherConnectionsDownloadsAreLeftOut() {
        let mine = downloadedBook("mine")
        let theirs = downloadedBook("theirs", connection: accountB)
        let theirShow = downloadedPodcast("show", episodes: [("e1", 1)], connection: accountB)
        #expect(downloadsBuilder().downloads([theirs, mine, theirShow]).rows.map(\.id) == ["mine"])
        // Without an account, nothing.
        #expect(downloadsBuilder(serverID: nil).downloads([mine]).rows.isEmpty)
    }

    /// A local item exists once a download completed; one without its audio (an ebook-only book,
    /// an item whose last file went, an episode not in the snapshot) can't play from downloads.
    @Test func mediaWithoutACompletedAudioDownloadIsLeftOut() {
        let ebookOnly = downloadedBook(
            "ebook",
            files: [
                LocalFileDTO(
                    kind: .ebook, relativePath: "ebook/b.epub", filename: "b.epub", mimeType: "application/epub+zip",
                    size: 1)
            ])
        let emptied = downloadedBook("emptied", files: [])
        var show = downloadedPodcast("show", episodes: [("done", 1)])
        // An episode file whose download hasn't been recorded in the snapshot yet.
        show.files.append(audioFile("show/partial.mp3", episodeID: "partial"))
        let rows = downloadsBuilder().downloads([ebookOnly, emptied, show, downloadedBook("ok")]).rows
        #expect(rows.map(\.id) == ["show-done", "ok"])
    }

    @Test func aLongListPagesWithMore() {
        let items = (0..<5).map { downloadedBook("b\($0)") }
        let builder = downloadsBuilder(items: 3)
        let first = builder.downloads(items)
        #expect(first.rows.map(\.id) == ["b0", "b1", "more-2"])
        #expect(first.rows.last?.action == .more(.downloads, offset: 2))
        #expect(builder.downloads(items, offset: 2).rows.map(\.id) == ["b2", "b3", "b4"])
    }

    // MARK: Model

    @Test func theListFollowsTheStoreAsDownloadsCompleteAndAreDeleted() async {
        let feed = LocalItemFeed()
        let model = feed.model()
        #expect(model.status == .loading && model.list().rows.isEmpty)
        let task = Task { await model.observe() }
        defer { task.cancel() }

        // Empty once read: the template shows its empty-state text, with no rows.
        feed.continuation.yield([])
        await until { model.status == .loaded }
        #expect(model.status == .loaded && model.list().sections.isEmpty)
        #expect(feed.connections == [accountA.connectionID])

        // Downloads complete: books first (newest download first), then episodes.
        let book = downloadedBook("b1")
        let show = downloadedPodcast("p1", episodes: [("e1", 1)], addedAt: 10)
        let other = downloadedBook("theirs", connection: accountB)
        feed.continuation.yield([show, book, other])
        await until { !model.list().rows.isEmpty }
        #expect(model.list().rows.map(\.id) == ["b1", "p1-e1"])

        // Another episode completes, then the book is deleted.
        feed.continuation.yield([downloadedPodcast("p1", episodes: [("e1", 1), ("e2", 2)], addedAt: 10), book])
        await until { model.list().rows.count == 3 }
        #expect(model.list().rows.map(\.id) == ["b1", "p1-e2", "p1-e1"])
        feed.continuation.yield([show])
        await until { model.list().rows.count == 1 }
        #expect(model.list().rows.map(\.id) == ["p1-e1"])
    }

    @Test func aPageEmptiedByDeletionsGoesBackToTheFirstPage() async {
        let feed = LocalItemFeed()
        let model = feed.model(items: 3)
        let task = Task { await model.observe() }
        defer { task.cancel() }
        feed.continuation.yield((0..<5).map { downloadedBook("b\($0)", addedAt: -Double($0)) })
        await until { model.list(offset: 2).rows.count == 3 }
        #expect(model.offset(afterChangeFrom: 2) == 2)

        feed.continuation.yield([downloadedBook("b0")])
        await until { model.list().rows.count == 1 }
        #expect(model.offset(afterChangeFrom: 2) == 0)
    }

    // MARK: Playing

    /// Offline, with no server client and the Continue tab's shelves never loaded, a tapped row
    /// plays its book or episode through the account's play action, which plays it from its files.
    @Test func aTappedRowPlaysItsItemOrEpisodeOffline() async throws {
        try await withLibrarySettings { settings in
            let store = LibraryStore(settings: settings)
            store.attach(
                client: nil, connectionKey: LibraryConnectionKey(connectionID: accountA.connectionID, userID: "user-1"),
                isOffline: true)
            let plays = Locked<[String]>([])
            let gate = Locked<AuthGate>(.ready(accountA, isOffline: true))
            let root = CarPlayRootModel(
                gate: { gate.value }, store: store,
                playItem: { identity in
                    PlayItemAction { itemID, episodeID, _ in
                        plays.value.append("\(identity == accountA ? "A" : "B"):\(itemID)/\(episodeID ?? "-")")
                    }
                },
                playing: { nil }, labels: downloadLabels)

            let feed = LocalItemFeed()
            let downloads = feed.model()
            let task = Task { await downloads.observe() }
            defer { task.cancel() }
            feed.continuation.yield([downloadedBook("b1"), downloadedPodcast("p1", episodes: [("e1", 1)])])
            await until { downloads.list().rows.count == 2 }
            let rows = downloads.list().rows
            #expect(rows.count == 2)

            for row in rows { #expect(await root.play(row, offset: 0, of: downloads)?.value == .started) }
            #expect(plays.value == ["A:b1/-", "A:p1/e1"])

            // Negative controls: a row the tab doesn't show, a deleted download's row, another
            // account's model, and a signed-out account play nothing.
            let foreign = CarPlayRow(id: "x", text: "X", action: .play(itemID: "x", episodeID: nil))
            #expect(root.play(foreign, offset: 0, of: downloads) == nil)
            feed.continuation.yield([downloadedBook("b1")])
            await until { downloads.list().rows.count == 1 }
            #expect(root.play(rows[1], offset: 0, of: downloads) == nil)
            #expect(root.play(rows[0], offset: 0, of: LocalItemFeed().model(accountB)) == nil)
            gate.value = .connect
            #expect(root.play(rows[0], offset: 0, of: downloads) == nil)
            #expect(plays.value.count == 2)
        }
    }
}
