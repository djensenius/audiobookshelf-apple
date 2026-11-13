import ABSAPI
import ABSAppModel
import ABSCore
import ABSData
import ABSUI
import Foundation
import Testing

@testable import Audiobookshelf

/// Serves no libraries and no shelves: these tests only read the state Home resolves.
private struct EmptyLibraryService: LibraryService {
    struct Unused: Error {}

    func libraries() async throws -> [Library] { [] }
    func library(id: String) async throws -> LibraryWithFilterData { throw Unused() }
    func personalizedShelves(libraryID: String) async throws -> [Shelf] { [] }
    func items(libraryID: String, query: LibraryQuery) async throws -> PagedResults<LibraryItem> { throw Unused() }
}

/// Home's downloaded shelves and its disconnected state (#76): which shelves show online and
/// offline, the message and Retry when nothing is downloaded, and the app's live downloads
/// feeding the shelf.
@MainActor
@Suite(.timeLimit(.minutes(1))) struct HomeDownloadedShelfTests {
    private typealias Inputs = HomeScreenState.Inputs

    private let connectionID = UUID()
    private let date = Date(timeIntervalSince1970: 1_800_000_000)
    private let unreachable = ConnectionBannerStatus.serverUnreachable(retryAt: Date(timeIntervalSince1970: 1))
    private let server = [
        HomeSection(
            id: "recently-added", titleKey: "LabelRecentlyAdded", label: "Recently Added", kind: .book,
            entries: [.item(ItemSummary(id: "li_server", itemID: "li_server", kind: .book, title: "Server"))])
    ]

    private func item(_ title: String, _ mediaType: MediaType = .book) -> LocalLibraryItemDTO {
        LocalLibraryItemDTO(
            id: UUID(), serverConnectionID: connectionID, serverAddress: "https://abs.example.com",
            serverUserId: "usr_1", libraryItemId: "li_\(title)", mediaType: mediaType, title: title,
            relativeDirectory: title, addedAt: date, updatedAt: date,
            media: LocalMediaSnapshot(metadata: .init(title: title)),
            files: [
                LocalFileDTO(
                    kind: .audio, relativePath: "\(title)/a.mp3", filename: "a.mp3", mimeType: "audio/mpeg", size: 1)
            ])
    }

    /// A shelf model showing `items`, read once.
    private func shelf(_ items: [LocalLibraryItemDTO]) async -> DownloadedShelfModel {
        let (stream, continuation) = AsyncStream.makeStream(of: [LocalLibraryItemDTO].self)
        let model = DownloadedShelfModel { _ in stream }
        continuation.yield(items)
        continuation.finish()
        await model.observe(connectionID: connectionID)
        return model
    }

    private func ids(_ sections: [HomeSection]) -> [String] { sections.map(\.id) }

    @Test func withoutDownloadsTheShelfIsHidden() async {
        let empty = await shelf([])
        let downloads = HomePresentation.downloadedSections(of: empty, libraryKind: .book, isConnected: true)
        #expect(empty.isLoaded && downloads.isEmpty)
        #expect(HomePresentation.downloadedSections(of: nil, libraryKind: .book, isConnected: false).isEmpty)
        #expect(HomePresentation.sections(server: server, downloaded: downloads, isConnected: true) == server)

        #expect(HomeScreenState.resolve(Inputs(hasLoaded: true, isEmpty: false)) == .shelves(refreshFailed: false))
        #expect(HomeScreenState.resolve(Inputs(hasLoaded: true)) == .empty)
        #expect(HomeScreenState.resolve(Inputs(librariesLoaded: true, libraryID: nil)) == .empty)
    }

    @Test func offlineWithDownloadsShowsOnlyTheDownloads() async {
        let model = await shelf([item("Book"), item("Show", .podcast)])
        // Every kind, whatever the library: the server's library can't be browsed.
        let downloads = HomePresentation.downloadedSections(of: model, libraryKind: .book, isConnected: false)
        #expect(ids(downloads) == ["local-books", "local-podcasts"])
        #expect(HomePresentation.sections(server: server, downloaded: downloads, isConnected: false) == downloads)

        for connection in [ConnectionBannerStatus.offline, .checking, unreachable] {
            // Even over shelves loaded before the connection went.
            #expect(
                HomeScreenState.resolve(
                    Inputs(hasLoaded: true, isEmpty: false, connection: connection, hasDownloads: true))
                    == .shelves(refreshFailed: false))
            // And an offline start that never loaded the libraries.
            #expect(
                HomeScreenState.resolve(
                    Inputs(librariesLoaded: false, libraryID: nil, connection: connection, hasDownloads: true))
                    == .shelves(refreshFailed: false))
        }
    }

    @Test func onlineWithDownloadsAddsTheLibrarysShelfAfterTheServers() async {
        let model = await shelf([item("Book"), item("Show", .podcast)])
        let books = HomePresentation.downloadedSections(of: model, libraryKind: .book, isConnected: true)
        #expect(ids(books) == ["local-books"])
        #expect(
            ids(HomePresentation.downloadedSections(of: model, libraryKind: .podcast, isConnected: true))
                == ["local-podcasts"])
        #expect(
            ids(HomePresentation.downloadedSections(of: model, libraryKind: nil, isConnected: true))
                == ["local-books", "local-podcasts"])
        #expect(HomePresentation.sections(server: server, downloaded: books, isConnected: true) == server + books)

        #expect(
            HomeScreenState.resolve(Inputs(hasLoaded: true, isEmpty: false, hasDownloads: true))
                == .shelves(refreshFailed: false))
        #expect(
            HomeScreenState.resolve(Inputs(hasLoaded: true, hasError: true, isEmpty: false, hasDownloads: true))
                == .shelves(refreshFailed: true))
        // A library without shelves, or none at all, still shows the downloads.
        #expect(HomeScreenState.resolve(Inputs(hasLoaded: true, hasDownloads: true)) == .shelves(refreshFailed: false))
        #expect(
            HomeScreenState.resolve(Inputs(librariesLoaded: true, libraryID: nil, hasDownloads: true))
                == .shelves(refreshFailed: false))
        // Loading and failing are still the server's to show.
        #expect(HomeScreenState.resolve(Inputs(hasDownloads: true)) == .loading)
        #expect(HomeScreenState.resolve(Inputs(hasLoaded: true, hasError: true, hasDownloads: true)) == .failed)
    }

    @Test func disconnectedWithoutDownloadsSaysWhyWithRetryOnlyWhenUnreachable() {
        for connection in [ConnectionBannerStatus.offline, .checking, unreachable] {
            #expect(HomeScreenState.resolve(Inputs(connection: connection)) == .disconnected(connection))
            #expect(
                HomeScreenState.resolve(Inputs(hasLoaded: true, isEmpty: false, connection: connection))
                    == .disconnected(connection))
            #expect(
                HomeScreenState.resolve(Inputs(isSignedIn: false, connection: connection)) == .signedOut)
        }

        var retried = 0
        #expect(HomePresentation.connectionRetry(for: .offline) { retried += 1 } == nil)
        #expect(HomePresentation.connectionRetry(for: .checking) { retried += 1 } == nil)
        let retry = HomePresentation.connectionRetry(for: unreachable) { retried += 1 }
        retry?()
        #expect(retried == 1)
    }

    /// Shelves loaded, then a refresh failed as the connection went, within ``HomeRefreshSchedule/maxAge``:
    /// when the server answers again, the load trigger retries it at once instead of leaving its
    /// error up; fresh shelves without an error aren't fetched again.
    @Test func reconnectingRetriesAFailedRefreshAtOnce() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        var schedule = HomeRefreshSchedule()
        schedule.markLoaded(libraryID: "lib", at: start)
        let failed = HomeRefreshSchedule.ModelState(libraryID: "lib", hasLoaded: true, isLoading: false, hasError: true)
        let recorded = schedule.recordCompletion(of: "lib", model: failed, isCancelled: false, at: start + 60)
        #expect(!recorded)
        let reconnected = start.addingTimeInterval(120)
        #expect(reconnected.timeIntervalSince(start) < HomeRefreshSchedule.maxAge)

        func request(_ trigger: HomeRefreshSchedule.Trigger, hasError: Bool) -> HomeRefreshSchedule.Request? {
            schedule.request(
                for: trigger, libraryID: "lib", hasLoaded: true, hasError: hasError, isConnected: true, now: reconnected
            )
        }
        #expect(request(.loadTrigger, hasError: true) == .refresh)
        #expect(request(.loadTrigger, hasError: false) == nil)
        #expect(request(.sceneActivation, hasError: true) == nil)
        #expect(request(.userRefresh, hasError: false) == .refresh)
    }

    /// Losing the connection runs Home's load trigger again: no trigger, not even pull to refresh,
    /// loads or refreshes the shelves without the server, whether they're loaded, stale or failed.
    @Test func offlineNoTriggerLoadsOrRefreshesTheShelves() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        var schedule = HomeRefreshSchedule()
        schedule.markLoaded(libraryID: "lib", at: start)
        let fresh = start.addingTimeInterval(60)
        let stale = start.addingTimeInterval(HomeRefreshSchedule.maxAge + 1)

        for trigger in HomeRefreshSchedule.Trigger.allCases {
            func request(
                hasLoaded: Bool, hasError: Bool, isConnected: Bool, at now: Date, libraryID: String = "lib"
            ) -> HomeRefreshSchedule.Request? {
                schedule.request(
                    for: trigger, libraryID: libraryID, hasLoaded: hasLoaded, hasError: hasError,
                    isConnected: isConnected, now: now)
            }
            for hasLoaded in [false, true] {
                for hasError in [false, true] {
                    for now in [fresh, stale] {
                        #expect(
                            request(hasLoaded: hasLoaded, hasError: hasError, isConnected: false, at: now) == nil,
                            "\(trigger), loaded \(hasLoaded), error \(hasError), stale \(now == stale)")
                    }
                }
            }
            #expect(request(hasLoaded: true, hasError: false, isConnected: false, at: fresh, libraryID: "other") == nil)
            // With the server, the same trigger asks for what's missing or stale.
            #expect(request(hasLoaded: false, hasError: false, isConnected: true, at: fresh) == .load)
            #expect(request(hasLoaded: true, hasError: false, isConnected: true, at: stale) == .refresh)
        }
    }

    /// The downloads couldn't be read: Home says its shelves couldn't load rather than that
    /// nothing is downloaded, offline and online, and Retry reads them again and shows them.
    @Test func aDownloadReadErrorShowsAndRetryShowsTheDownloads() async throws {
        for connection in [ConnectionBannerStatus.offline, .checking, unreachable] {
            #expect(HomeScreenState.resolve(Inputs(connection: connection, downloadsFailed: true)) == .failed)
        }
        #expect(HomeScreenState.resolve(Inputs(hasLoaded: true, downloadsFailed: true)) == .failed)
        #expect(
            HomeScreenState.resolve(Inputs(librariesLoaded: true, libraryID: nil, downloadsFailed: true)) == .failed)
        #expect(
            HomeScreenState.resolve(Inputs(hasLoaded: true, isEmpty: false, downloadsFailed: true))
                == .shelves(refreshFailed: true))
        #expect(
            HomeScreenState.resolve(Inputs(connection: .offline, hasDownloads: true, downloadsFailed: true))
                == .shelves(refreshFailed: true))

        struct ReadFailed: Error {}
        @MainActor final class Reads {
            var count = 0
        }
        let reads = Reads()
        let (stream, continuation) = AsyncStream.makeStream(of: [LocalLibraryItemDTO].self)
        let model = DownloadedShelfModel { @MainActor _ in
            reads.count += 1
            if reads.count == 1 { throw ReadFailed() }
            return stream
        }
        func state() -> HomeScreenState {
            let downloads = HomePresentation.downloadedSections(of: model, libraryKind: nil, isConnected: false)
            return HomeScreenState.resolve(
                Inputs(
                    connection: .offline, hasDownloads: !downloads.isEmpty, downloadsLoaded: model.isLoaded,
                    downloadsFailed: model.loadError != nil))
        }
        let task = Task { await model.observe(connectionID: connectionID) }
        defer { task.cancel() }
        while model.loadError == nil, !Task.isCancelled { await Task.yield() }
        #expect(state() == .failed)

        continuation.yield([item("Book")])
        model.retry()
        while model.books.isEmpty, !Task.isCancelled { await Task.yield() }
        #expect(state() == .shelves(refreshFailed: false))
        #expect(
            ids(HomePresentation.downloadedSections(of: model, libraryKind: nil, isConnected: false)) == ["local-books"]
        )
        #expect(reads.count == 2)
    }

    @Test func homeWaitsForTheDownloadsBeforeSayingThereAreNone() {
        #expect(HomeScreenState.resolve(Inputs(connection: .offline, downloadsLoaded: false)) == .loading)
        #expect(HomeScreenState.resolve(Inputs(hasLoaded: true, downloadsLoaded: false)) == .loading)
        // The server's shelves don't wait.
        #expect(
            HomeScreenState.resolve(Inputs(hasLoaded: true, isEmpty: false, downloadsLoaded: false))
                == .shelves(refreshFailed: false))
    }

    @Test func theStoresStateTakesTheConnectionAndDownloads() async throws {
        let suiteName = "HomeDownloadedShelfTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = LibraryStore(settings: AppSettings(defaults: defaults))
        await store.connect(
            client: EmptyLibraryService(), connectionKey: LibraryConnectionKey(connectionID: connectionID, userID: "u"))
        let model = HomeModel(store: store, libraryID: "lib")
        let downloads = HomePresentation.downloadedSections(
            of: await shelf([item("Book")]), libraryKind: nil, isConnected: false)

        func state(_ downloads: [HomeSection], loaded: Bool = true) -> HomeScreenState {
            HomeScreenState.resolve(
                store: store, model: model, libraryID: "lib", sections: [], connection: .offline,
                downloads: downloads, downloadsLoaded: loaded)
        }
        #expect(state(downloads) == .shelves(refreshFailed: false))
        #expect(state([]) == .disconnected(.offline))
        #expect(state(downloads, loaded: false) == .loading)
        #expect(HomeScreenState.resolve(store: store, model: model, libraryID: "lib", sections: []) == .loading)
    }

    /// The host's `\.downloads` stream, from the app's download stack, feeds the shelf live.
    @Test func theAppsDownloadsFeedTheShelf() async throws {
        let suiteName = "HomeDownloadedShelfTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        let testDownloads = TestDownloads()
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            testDownloads.cleanUp()
        }
        let environment = AppEnvironment(
            settings: AppSettings(defaults: defaults), storeLocation: .inMemory, keychain: ConnectTestKeychain(),
            downloadsRoot: testDownloads.root, makeDownloadSession: testDownloads.makeSession)
        let container = try #require(environment.dataStack?.container)
        let writer = try #require(environment.downloads?.localItems)
        let updates = try #require(environment.makeDownloadsServices()?.localItemUpdates)
        let connection = try await ServerConnectionStore(modelContainer: container).upsertLogin(
            address: try #require(ServerAddress("https://abs.example.com")), userId: "usr_1", username: "user",
            authMethod: .local, serverVersion: nil)

        let model = DownloadedShelfModel(updates: updates)
        let task = Task { await model.observe(connectionID: connection.id) }
        defer { task.cancel() }
        while !model.isLoaded, !Task.isCancelled { await Task.yield() }
        #expect(HomePresentation.downloadedSections(of: model, libraryKind: nil, isConnected: false).isEmpty)

        let part = DownloadPartDTO(
            kind: .audio, serverPath: "/api/items/li_1/file", filename: "a.mp3", mimeType: "audio/mpeg",
            destinationRelativePath: "li_1/a.mp3", state: .completed)
        _ = try await writer.upsertFromDownload(
            DownloadRecordDTO(
                key: MediaKey(serverConnectionID: connection.id, libraryItemId: "li_1"), mediaType: .book,
                title: "The Book", relativeDirectory: "li_1",
                media: LocalMediaSnapshot(metadata: .init(title: "The Book")), parts: [part]))
        while model.books.isEmpty, !Task.isCancelled { await Task.yield() }
        let sections = HomePresentation.downloadedSections(of: model, libraryKind: nil, isConnected: false)
        #expect(ids(sections) == ["local-books"])
        #expect(sections.first?.entries.map(\.id) == ["li_1"])
    }
}
