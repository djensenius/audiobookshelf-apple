import ABSCore
import ABSData
import Foundation
import Testing

@testable import ABSAppModel

@MainActor
@Suite(.timeLimit(.minutes(1))) struct DownloadedShelfModelTests {
    private let connectionID = UUID()
    private let date = Date(timeIntervalSince1970: 1_800_000_000)

    private func item(
        _ title: String, _ mediaType: MediaType = .book, connection: UUID? = nil, addedAt offset: TimeInterval = 0,
        hasFiles: Bool = true
    ) -> LocalLibraryItemDTO {
        let file = LocalFileDTO(
            kind: .audio, relativePath: "\(title)/a.mp3", filename: "a.mp3", mimeType: "audio/mpeg", size: 1)
        return LocalLibraryItemDTO(
            id: UUID(), serverConnectionID: connection ?? connectionID, serverAddress: "https://abs.example.com",
            serverUserId: "usr_1", libraryItemId: "li_\(title)", mediaType: mediaType, title: title,
            relativeDirectory: title, addedAt: date.addingTimeInterval(offset), updatedAt: date,
            media: LocalMediaSnapshot(metadata: .init(title: title)), files: hasFiles ? [file] : [])
    }

    @Test func shelvesListOnlyThisConnectionsDownloadedMedia() {
        let book = item("Book")
        let podcast = item("Show", .podcast)
        let other = item("Other", connection: UUID())
        let empty = item("Emptied", .podcast, hasFiles: false)

        let shelf = DownloadedShelfModel.shelf([book, podcast, other, empty], connectionID: connectionID)
        #expect(shelf.books == [book])
        #expect(shelf.podcasts == [podcast])
        #expect(DownloadedShelfModel.shelf([book], connectionID: nil).books.isEmpty)
    }

    @Test func newestDownloadsComeFirstThenTitles() {
        let old = item("Old", addedAt: -60)
        let newest = item("Newest", addedAt: 60)
        let b10 = item("Book 10")
        let b9 = item("Book 9")

        let shelf = DownloadedShelfModel.shelf([old, b10, newest, b9], connectionID: connectionID)
        #expect(shelf.books.map(\.title) == ["Newest", "Book 9", "Book 10", "Old"])
    }

    @Test func shelvesFollowTheStoreAndDropAnotherConnectionsSnapshots() async throws {
        let (stream, continuation) = AsyncStream.makeStream(of: [LocalLibraryItemDTO].self)
        let model = DownloadedShelfModel { _ in stream }
        let task = Task { await model.observe(connectionID: connectionID) }
        defer { task.cancel() }

        let book = item("Book")
        continuation.yield([book])
        while !model.isLoaded, !Task.isCancelled { await Task.yield() }
        #expect(model.books == [book] && model.podcasts.isEmpty)

        let podcast = item("Show", .podcast, addedAt: 5)
        continuation.yield([podcast, book])
        while model.podcasts.isEmpty, !Task.isCancelled { await Task.yield() }
        #expect(model.books == [book])

        continuation.yield([podcast])
        while !model.books.isEmpty, !Task.isCancelled { await Task.yield() }
        #expect(model.podcasts == [podcast])

        // Switching connections clears the shelves; the old stream's snapshots no longer show.
        let other = Task { await model.observe(connectionID: nil) }
        await other.value
        continuation.yield([book])
        continuation.finish()
        await task.value
        #expect(model.isEmpty && !model.isLoaded && model.connectionID == nil)
    }

    /// Through a real store: a finished download appears, a deleted one disappears.
    @Test func storeDownloadsAndDeletionsShowLive() async throws {
        let container = try DataStack(location: .inMemory).container
        let connection = try await ServerConnectionStore(modelContainer: container).upsertLogin(
            address: try #require(ServerAddress("https://abs.example.com")), userId: "usr_1", username: "user",
            authMethod: .local, serverVersion: nil)
        let store = LocalItemStore(modelContainer: container)
        let model = DownloadedShelfModel { try await store.updates(serverConnectionID: $0) }
        let task = Task { await model.observe(connectionID: connection.id) }
        defer { task.cancel() }
        while !model.isLoaded, !Task.isCancelled { await Task.yield() }
        #expect(model.isEmpty)

        let part = DownloadPartDTO(
            kind: .audio, serverPath: "/api/items/li_1/file", filename: "a.mp3", mimeType: "audio/mpeg",
            destinationRelativePath: "li_1/a.mp3", state: .completed)
        let item = try await store.upsertFromDownload(
            DownloadRecordDTO(
                key: MediaKey(serverConnectionID: connection.id, libraryItemId: "li_1"), mediaType: .book,
                title: "The Book", relativeDirectory: "li_1",
                media: LocalMediaSnapshot(metadata: .init(title: "The Book")),
                parts: [part]))
        while model.books.isEmpty, !Task.isCancelled { await Task.yield() }
        #expect(model.books.map(\.id) == [item.id])

        try await store.deleteItem(id: item.id)
        while !model.books.isEmpty, !Task.isCancelled { await Task.yield() }
        #expect(model.isEmpty)
    }
}

@MainActor
@Suite(.timeLimit(.minutes(1))) struct ConnectionBannerModelTests {
    private struct Down: Error {}
    private let date = Date(timeIntervalSince1970: 1_800_000_000)

    /// Pings the test answers one at a time through ``calls``.
    private final class Pings: Sendable {
        let calls: AsyncStream<CheckedContinuation<Void, any Error>>
        private let continuation: AsyncStream<CheckedContinuation<Void, any Error>>.Continuation
        init() { (calls, continuation) = AsyncStream.makeStream() }

        func ping() async throws {
            try await withCheckedThrowingContinuation { continuation.yield($0) }
        }
    }

    private func waitFor(_ model: ConnectionBannerModel, _ state: ConnectionBannerState) async {
        while model.state != state, !Task.isCancelled { await Task.yield() }
    }

    @Test func failedPingsBackOffAndRetryPingsAtOnce() async throws {
        let clock = ManualClock()
        let pings = Pings()
        let (paths, pathFeed) = AsyncStream.makeStream(of: NetworkPath.self)
        let model = ConnectionBannerModel(
            paths: { paths }, ping: { try await pings.ping() }, clock: clock, now: { [date] in date })
        let run = Task { await model.run() }
        var calls = pings.calls.makeAsyncIterator()
        var sleeps = clock.sleeps.makeAsyncIterator()

        try #require(await calls.next()).resume(throwing: Down())
        #expect(await sleeps.next() == .seconds(5))
        #expect(model.state == .serverUnreachable(retryAt: date.addingTimeInterval(5)))

        clock.advance(by: .seconds(5))
        try #require(await calls.next()).resume(throwing: Down())
        #expect(await sleeps.next() == .seconds(10))

        model.retry()
        #expect(model.state == .serverUnreachable(retryAt: nil))
        try #require(await calls.next()).resume()
        await waitFor(model, .online)
        #expect(clock.sleeperCount == 0)

        pathFeed.yield(NetworkPath.offline)
        await waitFor(model, .offline(.noNetwork))
        run.cancel()
        await run.value
    }

    @Test func lostNetworkCancelsTheScheduledPing() async throws {
        let clock = ManualClock()
        let pings = Pings()
        let (paths, pathFeed) = AsyncStream.makeStream(of: NetworkPath.self)
        let model = ConnectionBannerModel(paths: { paths }, ping: { try await pings.ping() }, clock: clock)
        let run = Task { await model.run() }
        var calls = pings.calls.makeAsyncIterator()
        var sleeps = clock.sleeps.makeAsyncIterator()
        try #require(await calls.next()).resume(throwing: Down())
        _ = await sleeps.next()

        pathFeed.yield(NetworkPath.offline)
        await waitFor(model, .offline(.noNetwork))
        while clock.sleeperCount > 0, !Task.isCancelled { await Task.yield() }

        pathFeed.yield(NetworkPath.wifi)
        await waitFor(model, .online)
        try #require(await calls.next()).resume()

        // A flap the stream coalesced into one online path still checks the server.
        var flapped = NetworkPath.wifi
        flapped.onlineEpoch = 1
        pathFeed.yield(flapped)
        try #require(await calls.next()).resume()
        run.cancel()
        await run.value
    }
}
