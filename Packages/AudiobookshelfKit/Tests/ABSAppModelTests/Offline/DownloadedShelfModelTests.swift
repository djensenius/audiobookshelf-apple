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

    /// The first read fails: the shelf says so and waits; Retry reads the same connection's items
    /// again and follows them from then on.
    @Test func aFailedReadIsReadAgainOnRetryAndThenFollowed() async throws {
        struct ReadFailed: Error {}
        @MainActor final class Reads {
            var connections: [UUID] = []
        }
        let reads = Reads()
        let (stream, continuation) = AsyncStream.makeStream(of: [LocalLibraryItemDTO].self)
        let model = DownloadedShelfModel { @MainActor connectionID in
            reads.connections.append(connectionID)
            if reads.connections.count == 1 { throw ReadFailed() }
            return stream
        }
        let task = Task { await model.observe(connectionID: connectionID) }
        defer { task.cancel() }
        while model.loadError == nil, !Task.isCancelled { await Task.yield() }
        #expect(model.loadError is ReadFailed)
        #expect(model.isLoaded && model.isEmpty)

        let book = item("Book")
        continuation.yield([book])
        model.retry()
        while model.books.isEmpty, !Task.isCancelled { await Task.yield() }
        #expect(model.books == [book] && model.isLoaded && model.loadError == nil)
        #expect(reads.connections == [connectionID, connectionID])

        let podcast = item("Show", .podcast, addedAt: 5)
        continuation.yield([podcast, book])
        while model.podcasts.isEmpty, !Task.isCancelled { await Task.yield() }
        #expect(model.podcasts == [podcast])
        // Retry while following does nothing.
        model.retry()
        for _ in 0..<50 { await Task.yield() }
        #expect(reads.connections.count == 2)
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

    /// Wi-Fi to cellular, with no offline path between: the new route may not reach the server.
    @Test func changedOnlineRouteChecksTheServerAgain() async throws {
        let pings = Pings()
        let (paths, pathFeed) = AsyncStream.makeStream(of: NetworkPath.self)
        let model = ConnectionBannerModel(
            paths: { paths }, ping: { try await pings.ping() }, clock: ManualClock(), now: { [date] in date })
        let run = Task { await model.run() }
        var calls = pings.calls.makeAsyncIterator()
        try #require(await calls.next()).resume()
        pathFeed.yield(.wifi)
        pathFeed.yield(.wifi)
        pathFeed.yield(.cellular)
        try #require(await calls.next()).resume(throwing: Down())
        await waitFor(model, .serverUnreachable(retryAt: date.addingTimeInterval(5)))
        run.cancel()
        await run.value
    }

    /// The old run, finishing after a new one started, leaves the new run's ping alone.
    @Test func aReplacedRunKeepsTheNewRunsPing() async throws {
        let clock = ManualClock()
        let pings = Pings()
        let model = ConnectionBannerModel(
            paths: { AsyncStream { _ in } }, ping: { try await pings.ping() }, clock: clock, now: { [date] in date })
        var calls = pings.calls.makeAsyncIterator()
        let old = Task { await model.run() }
        let first = try #require(await calls.next())
        let current = Task { await model.run() }
        let second = try #require(await calls.next())
        old.cancel()
        await old.value
        first.resume(throwing: Down())

        second.resume(throwing: Down())
        var sleeps = clock.sleeps.makeAsyncIterator()
        #expect(await sleeps.next() == .seconds(5))
        #expect(model.state == .serverUnreachable(retryAt: date.addingTimeInterval(5)))
        current.cancel()
        await current.value
    }

    /// A ping still running when the run ends neither changes the state nor schedules a retry.
    @Test func aStoppedRunIgnoresItsLastPing() async throws {
        let clock = ManualClock()
        let pings = Pings()
        let model = ConnectionBannerModel(
            paths: { AsyncStream { _ in } }, ping: { try await pings.ping() }, clock: clock)
        var calls = pings.calls.makeAsyncIterator()
        let run = Task { await model.run() }
        let ping = try #require(await calls.next())
        run.cancel()
        await run.value

        ping.resume(throwing: Down())
        for _ in 0..<100 { await Task.yield() }
        #expect(model.state == .online)
        #expect(clock.sleeperCount == 0)
    }
}
