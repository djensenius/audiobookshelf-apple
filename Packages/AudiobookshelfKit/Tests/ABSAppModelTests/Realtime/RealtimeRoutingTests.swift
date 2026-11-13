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

/// Socket progress through the routed bridge into ``LocalProgressStore`` (#529): the store's
/// `.socket` rules hold through the wiring, and the cache is updated first.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct RealtimeLocalProgressTests {
    /// 1,800,000,000 s, in the socket's milliseconds.
    private static let t0Millis = 1_800_000_000_000
    private static func date(_ millis: Int) -> Date { Date(timeIntervalSince1970: Double(millis) / 1000) }

    private let key = MediaKey(serverConnectionID: identityA.connectionID, libraryItemId: "book")

    /// A store with a row for ``key`` at `currentTime`, its server baseline from `t0Millis`.
    private func storeWithRow(currentTime: Double = 50) async throws -> LocalProgressStore {
        let store = LocalProgressStore(modelContainer: try DataStack(location: .inMemory).container)
        try await store.recordEdit(
            ProgressEdit(audio: .init(currentTime: currentTime, duration: 1000, progress: currentTime / 1000)),
            for: key,
            serverProgress: ProgressBaseline(
                currentTime: 10, progress: 0.01, duration: 1000, isFinished: false,
                lastUpdate: Self.date(Self.t0Millis)))
        // Acknowledged, so the row is clean and only server values move it.
        let patch = try #require(try await store.beginSend(for: key))
        try await store.completeSend(patch, serverLastUpdate: Self.date(Self.t0Millis + 1_000))
        return store
    }

    @Test func socketProgressReachesTheStoreAfterTheCacheInEventOrder() async throws {
        try await withLibrarySettings { settings in
            let local = try await storeWithRow()
            let routed = RoutedBridge(settings: settings, localProgress: local)
            let socket = try await routed.start()

            await routed.send(progressUpdate("book", currentTime: 300, lastUpdate: Self.t0Millis + 5_000), on: socket)
            // The cache takes it as the event is handled; the store's merge follows.
            #expect(routed.store.progress.progress(libraryItemID: "book")?.currentTime == 300)
            await routed.send(progressUpdate("book", currentTime: 200, lastUpdate: Self.t0Millis + 4_000), on: socket)
            await routed.bridge.mergeTask?.value

            // Both keep the newer value: the older event, merged after it, changes neither.
            #expect(routed.store.progress.progress(libraryItemID: "book")?.currentTime == 300)
            let row = try #require(try await local.progress(for: key))
            #expect(row.currentTime == 300)
            #expect(row.serverBaseline?.lastUpdate == Self.date(Self.t0Millis + 5_000))
            #expect(row.dirtyGroups.isEmpty)
        }
    }

    /// The PATCH's 200 carries no server time, so a socket value received after it may have been
    /// emitted before the PATCH was applied; through the wiring it still can't roll the
    /// acknowledged position back, whatever its `lastUpdate`.
    @Test(arguments: [0, 500, -1_000])
    func staleEventBeforeAnAcknowledgedPatchDoesNotRollBack(_ offsetMillis: Int) async throws {
        try await withLibrarySettings { settings in
            let local = LocalProgressStore(modelContainer: try DataStack(location: .inMemory).container)
            try await local.recordEdit(
                ProgressEdit(audio: .init(currentTime: 200, duration: 1000, progress: 0.2)), for: key,
                serverProgress: ProgressBaseline(
                    currentTime: 10, progress: 0.01, duration: 1000, isFinished: false,
                    lastUpdate: Self.date(Self.t0Millis)))
            let patch = try #require(try await local.beginSend(for: key))
            try await local.completeSend(patch, serverLastUpdate: nil)
            let routed = RoutedBridge(settings: settings, localProgress: local)
            let socket = try await routed.start()

            await routed.send(
                progressUpdate("book", currentTime: 100, lastUpdate: Self.t0Millis + offsetMillis), on: socket)
            await routed.bridge.mergeTask?.value

            let row = try #require(try await local.progress(for: key))
            #expect(row.currentTime == 200)
            #expect(row.dirtyGroups.isEmpty)
            // The cache shows the server's newest value, which it had none of.
            #expect(routed.store.progress.progress(libraryItemID: "book")?.currentTime == 100)
        }
    }

    @Test func undatedProgressIsDropped() async throws {
        try await withLibrarySettings { settings in
            let local = try await storeWithRow()
            let routed = RoutedBridge(settings: settings, localProgress: local)
            let socket = try await routed.start()

            await routed.send(progressUpdate("book", currentTime: 900, lastUpdate: nil), on: socket)

            #expect(routed.bridge.mergeTask == nil)
            #expect(routed.store.progress.progress(libraryItemID: "book") == nil)
            #expect(try await local.progress(for: key)?.currentTime == 50)
        }
    }

    @Test func anotherConnectionsProgressLeavesTheRowAlone() async throws {
        try await withLibrarySettings { settings in
            let local = try await storeWithRow()
            let routed = RoutedBridge(settings: settings, localProgress: local)
            _ = try await routed.start(identityA)
            await routed.bridge.sessionWillEnd(.switch)
            let socket = try await routed.start(identityB)

            await routed.send(progressUpdate("book", currentTime: 900, lastUpdate: Self.t0Millis + 5_000), on: socket)
            await routed.bridge.mergeTask?.value

            // Merged under B's connection, which has no row for the item; A's row is untouched.
            #expect(try await local.progress(for: key)?.currentTime == 50)
            let other = MediaKey(serverConnectionID: identityB.connectionID, libraryItemId: "book")
            #expect(try await local.progress(for: other) == nil)
        }
    }
}
