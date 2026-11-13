import ABSAPI
import ABSCore
import ABSData
import ABSRealtime
import Foundation
import SwiftData
import Testing

@testable import ABSAppModel

/// A bridge over a library store's progress, routed as the app routes it, with fake sockets.
@MainActor
private final class RoutedBridge {
    let store: LibraryStore
    let playback = FakePlaybackControl()
    let bookmarks = BookmarkStore()
    let sockets = Recorder<FakeSocket>()
    let handled = Recorder<RealtimeEvent>()
    let tokens = FakeTokenSource(current: "t1")
    let bridge: RealtimeBridge

    init(settings: AppSettings, localProgress: LocalProgressStore? = nil) {
        store = LibraryStore(settings: settings)
        bridge = RealtimeBridge(
            progress: store.progress,
            makeSocket: { [sockets] configuration in
                let socket = FakeSocket(configuration: configuration)
                sockets.append(socket)
                return socket
            },
            makeTokenSource: { [tokens] _ in tokens })
        bridge.route(
            library: store, accounts: nil, bookmarks: { [bookmarks] in bookmarks }, playback: playback,
            localProgress: localProgress)
        bridge.didHandle = { [handled] in handled.append($0) }
    }

    /// Starts `identity`'s session and waits until its socket connects.
    func start(_ identity: SessionIdentity = identityA) async throws -> FakeSocket {
        let count = sockets.values.count
        await bridge.sessionDidStart(
            SessionContext(identity: identity, client: try makeClient(), isOffline: false, sessionID: 1))
        await sockets.wait(count: count + 1)
        let socket = sockets.values[count]
        await socket.calls.wait(for: "connect")
        return socket
    }

    func send(_ event: RealtimeEvent, on socket: FakeSocket) async {
        let count = handled.values.count
        socket.continuation.yield(event)
        await handled.wait(count: count + 1)
    }
}

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct RealtimeRoutingTests {
    @Test func lifecycleOpensASocketPerAccountAndClosesItOnSwitchAndSignOut() async throws {
        try await withLibrarySettings { settings in
            let log = CallLog()
            let source = FakeAccountSource(log: log)
            source.restoredPhase = .active(identityA, isOffline: false)
            source.restoredClient = try makeClient()
            let lifecycle = SessionLifecycle(source: source)
            lifecycle.register(seeder: FakeLibrary(log: log))
            let routed = RoutedBridge(settings: settings)
            lifecycle.register(routed.bridge, stage: .progressSource)

            await lifecycle.start()
            await routed.sockets.wait(count: 1)
            let first = routed.sockets.values[0]
            await first.calls.wait(for: "connect")

            try await lifecycle.switchAccount(to: identityB.connectionID)
            await routed.sockets.wait(count: 2)
            let second = routed.sockets.values[1]
            await second.calls.wait(for: "connect")
            #expect(first.calls.values == ["connect", "disconnect"])

            _ = await lifecycle.signOut()
            await second.calls.wait(for: "disconnect")
            #expect(routed.bridge.connectionState == .idle)
            #expect(routed.sockets.values.count == 2)
        }
    }

    @Test func progressUpdatesReachTheLibraryCache() async throws {
        try await withLibrarySettings { settings in
            let routed = RoutedBridge(settings: settings)
            let socket = try await routed.start()

            await routed.send(progressUpdate("book", currentTime: 30, lastUpdate: 200), on: socket)

            #expect(routed.store.progress.progress(libraryItemID: "book")?.currentTime == 30)
        }
    }

    @Test func echoesOfThePlayersSessionAreIgnored() async throws {
        try await withLibrarySettings { settings in
            let routed = RoutedBridge(settings: settings)
            routed.playback.mediaKey = MediaKey(serverConnectionID: identityA.connectionID, libraryItemId: "book")
            routed.playback.session = PlaybackSession(id: "mine", libraryItemId: "book", mediaType: .book)
            let socket = try await routed.start()

            await routed.send(progressUpdate("book", currentTime: 30, lastUpdate: 200, sessionID: "mine"), on: socket)
            #expect(routed.store.progress.progress(libraryItemID: "book") == nil)

            await routed.send(progressUpdate("book", currentTime: 40, lastUpdate: 300), on: socket)
            #expect(routed.store.progress.progress(libraryItemID: "book")?.currentTime == 40)
        }
    }

    @Test func authorChangesReachTheAccountsObservers() async throws {
        try await withLibrarySettings { settings in
            let routed = RoutedBridge(settings: settings)
            let key = LibraryConnectionKey(connectionID: identityA.connectionID, userID: identityA.userID)
            routed.store.attach(client: nil, connectionKey: key, isOffline: true)
            let changes = Recorder<LibraryChange>()
            routed.store.observeLibraryChanges(connectionKey: key, owner: changes) { changes.append($0) }
            let socket = try await routed.start()
            let author = Author(id: "au-1", name: "Le Guin", libraryId: "lib-1")

            await routed.send(.authorChanged(.updated(author, libraryID: "lib-1")), on: socket)

            #expect(changes.values == [.author(.updated(author, libraryID: "lib-1"))])
        }
    }

    @Test func userUpdatesReplaceTheSessionsBookmarks() async throws {
        try await withLibrarySettings { settings in
            let routed = RoutedBridge(settings: settings)
            let socket = try await routed.start()
            let mark = AudioBookmark(libraryItemId: "book", title: "Here", time: 12)

            await routed.send(.userUpdated(User(id: "someone-else", username: "x", bookmarks: [mark])), on: socket)
            #expect(routed.bookmarks.bookmarks(itemID: "book").isEmpty)

            await routed.send(
                .userUpdated(User(id: identityA.userID, username: "alice", bookmarks: [mark])), on: socket)
            #expect(routed.bookmarks.bookmarks(itemID: "book") == [mark])
        }
    }

    @Test func socketProgressMergesIntoLocalRowsOnly() async throws {
        try await withLibrarySettings { settings in
            let container = try DataStack(location: .inMemory).container
            let local = LocalProgressStore(modelContainer: container)
            let key = MediaKey(serverConnectionID: identityA.connectionID, libraryItemId: "downloaded")
            let context = ModelContext(container)
            context.insert(
                LocalMediaProgress(
                    key: key.rawValue, serverConnectionID: key.serverConnectionID, libraryItemId: key.libraryItemId))
            try context.save()
            let routed = RoutedBridge(settings: settings, localProgress: local)
            let socket = try await routed.start()

            await routed.send(progressUpdate("downloaded", currentTime: 42, lastUpdate: 1_000), on: socket)
            await routed.send(progressUpdate("streamed", currentTime: 7, lastUpdate: 1_000), on: socket)
            await routed.bridge.mergeTask?.value

            let row = try #require(try await local.progress(for: key))
            #expect(row.currentTime == 42)
            #expect(row.serverBaseline?.lastUpdate == Date(timeIntervalSince1970: 1))
            let streamed = MediaKey(serverConnectionID: identityA.connectionID, libraryItemId: "streamed")
            #expect(try await local.progress(for: streamed) == nil)
        }
    }

    /// The cache reports a socket update before its local merge, which waits for the merges
    /// before it; once merged it reports again, with the same kind, so auto-advance prepares from
    /// the merged local progress (#554).
    @Test func socketProgressReportsAgainOnceMergedLocally() async throws {
        try await withLibrarySettings { settings in
            let container = try DataStack(location: .inMemory).container
            let local = LocalProgressStore(modelContainer: container)
            let context = ModelContext(container)
            for episode in ["e1", "e2"] {
                let key = MediaKey(
                    serverConnectionID: identityA.connectionID, libraryItemId: "podcast", episodeId: episode)
                context.insert(
                    LocalMediaProgress(
                        key: key.rawValue, serverConnectionID: key.serverConnectionID,
                        libraryItemId: key.libraryItemId, episodeId: episode))
            }
            try context.save()
            let routed = RoutedBridge(settings: settings, localProgress: local)
            let changes = Recorder<String>()
            routed.store.progress.onChange = { _, episode, kind in changes.append("\(episode ?? "-") \(kind)") }
            let socket = try await routed.start()

            // e1's merge comes first; e2's waits for it.
            await routed.send(progressUpdate("podcast", episode: "e1", currentTime: 4, lastUpdate: 1_000), on: socket)
            await routed.send(
                progressUpdate("podcast", episode: "e2", currentTime: 9, isFinished: true, lastUpdate: 1_000),
                on: socket)
            await routed.bridge.mergeTask?.value

            let e2 = MediaKey(serverConnectionID: identityA.connectionID, libraryItemId: "podcast", episodeId: "e2")
            #expect(try await local.progress(for: e2)?.isFinished == true)
            #expect(changes.values.filter { $0.hasPrefix("e2") } == ["e2 updated", "e2 updated"])
            #expect(changes.values.last == "e2 updated")
        }
    }

    @Test func networkPathChangesReconnectTheSocket() async throws {
        try await withLibrarySettings { settings in
            let routed = RoutedBridge(settings: settings)
            let socket = try await routed.start()
            let (paths, continuation) = AsyncStream.makeStream(of: NetworkPath.self)
            for path in [NetworkPath.wifi, .wifi, .offline, .wifi, .wired] { continuation.yield(path) }
            continuation.finish()

            await routed.bridge.follow(paths)

            // Back online on Wi-Fi, then over a wire; not the first path, a repeat, or going offline.
            #expect(socket.calls.count(of: "networkChanged") == 2)
        }
    }
}
