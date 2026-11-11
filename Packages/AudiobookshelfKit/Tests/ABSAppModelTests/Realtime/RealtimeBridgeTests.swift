import ABSAPI
import ABSCore
import ABSRealtime
import Foundation
import Testing

@testable import ABSAppModel

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct RealtimeBridgeTests {
    @Test func startBuildsTheSocketFromTheSessionClient() async throws {
        let harness = BridgeHarness()
        var configuration = try APIClientConfiguration(baseURL: URL(string: "https://abs.example/sub")!)
        try configuration.setCustomHeaders(["X-Proxy": "yes"])
        let client = APIClient(configuration: configuration, tokenProvider: FakeTokenProvider())

        let socket = try await harness.start(client: client)

        #expect(socket.configuration.serverAddress == URL(string: "https://abs.example/sub")!)
        #expect(socket.configuration.token == "t1")
        #expect(socket.configuration.customHeaders == ["X-Proxy": "yes"])
        #expect(harness.bridge.connectionState == .connecting)
    }

    @Test func offlineSessionOpensNoSocket() async throws {
        let harness = BridgeHarness()
        await harness.bridge.sessionDidStart(harness.context(client: try makeClient(), isOffline: true))
        await harness.bridge.sessionDidStart(harness.context(client: nil))

        // The offline paths return without starting a task, so no socket can appear later.
        #expect(harness.sockets.values.isEmpty)
        #expect(harness.bridge.connectionState == .idle)
    }

    @Test func connectionStateFollowsTheSocket() async throws {
        let harness = BridgeHarness()
        let socket = try await harness.start()
        let bridge = harness.bridge!

        await harness.send(.connected, on: socket)
        #expect(bridge.connectionState == .connecting)
        await harness.send(.initialized(RealtimeSession(userId: "a", username: "alice")), on: socket)
        #expect(bridge.connectionState == .connected)
        await harness.send(.disconnected(.transportClosed), on: socket)
        #expect(bridge.connectionState == .disconnected)
        await harness.send(.disconnected(.networkChanged), on: socket)
        #expect(bridge.connectionState == .connecting)

        await bridge.sessionWillEnd(.signOut)
        #expect(bridge.connectionState == .idle)
        #expect(socket.calls.values == ["connect", "disconnect"])
    }

    @Test func progressUpdatesOnlyApplyWhenNewer() async throws {
        let harness = BridgeHarness()
        let socket = try await harness.start()
        let cache = harness.cache
        cache.apply(MediaProgress(id: "p-book", libraryItemId: "book", currentTime: 10, lastUpdate: 100))

        await harness.send(progressUpdate("book", currentTime: 20, lastUpdate: 200), on: socket)
        #expect(cache.progress(libraryItemID: "book")?.currentTime == 20)

        // An echo of the same sync, a different value at the same time, older and undated
        // values all leave the cache alone.
        await harness.send(progressUpdate("book", currentTime: 20, lastUpdate: 200), on: socket)
        await harness.send(progressUpdate("book", currentTime: 25, lastUpdate: 200), on: socket)
        await harness.send(progressUpdate("book", currentTime: 5, lastUpdate: 150), on: socket)
        await harness.send(progressUpdate("book", currentTime: 6, lastUpdate: nil), on: socket)
        #expect(cache.progress(libraryItemID: "book")?.currentTime == 20)
        #expect(cache.progress(libraryItemID: "book")?.lastUpdate == 200)

        await harness.send(progressUpdate("show", episode: "e1", currentTime: 3, lastUpdate: 50), on: socket)
        #expect(cache.progress(libraryItemID: "show", episodeID: "e1")?.currentTime == 3)
    }

    @Test func nothingIsAppliedAfterTheSessionEnds() async throws {
        let harness = BridgeHarness()
        let socket = try await harness.start()
        let bridge = harness.bridge!
        let users = Recorder<User>()
        bridge.onUserUpdated = { users.append($0) }

        // Queued before the end, but the reader can't run before `sessionWillEnd` starts: it
        // stops reading synchronously.
        socket.continuation.yield(progressUpdate("book", currentTime: 1, lastUpdate: 100))
        socket.continuation.yield(.userUpdated(User(id: "a", username: "alice")))
        await bridge.sessionWillEnd(.switch)

        // The reader finished before `sessionWillEnd` returned, so these are never read either.
        socket.continuation.yield(progressUpdate("book", currentTime: 2, lastUpdate: 200))
        socket.continuation.finish()

        #expect(bridge.readerTask == nil)
        #expect(harness.handled.values.isEmpty)
        #expect(users.values.isEmpty)
        #expect(harness.cache.progress(libraryItemID: "book") == nil)
        #expect(socket.calls.values == ["connect", "disconnect"])
    }

    @Test func authFailureRefreshesOncePerRejectedToken() async throws {
        let harness = BridgeHarness()
        let tokens = harness.defaultTokens
        tokens.refreshResults = [.success("t2"), .success("t2")]
        let gate = Gate()
        tokens.refreshGate = gate
        let socket = try await harness.start()
        let bridge = harness.bridge!

        // A second rejection of the same token while the refresh runs doesn't refresh again.
        await harness.send(.authFailed(message: "Token expired"), on: socket)
        await harness.send(.authFailed(message: "Token expired"), on: socket)
        #expect(bridge.connectionState == .authFailed)
        gate.open()
        await socket.calls.wait(for: "updateToken(t2)")
        #expect(tokens.refreshes.values == ["t1"])
        #expect(bridge.connectionState == .connecting)

        // The new token may be refreshed once too; the server returns it unchanged.
        await harness.send(.authFailed(message: nil), on: socket)
        await tokens.refreshes.wait(count: 2)
        await socket.calls.wait { $0.filter { $0 == "updateToken(t2)" }.count == 2 }

        // Rejected again: no third refresh.
        await harness.send(.authFailed(message: nil), on: socket)
        await bridge.tokenTask?.value
        #expect(tokens.refreshes.values == ["t1", "t2"])
        #expect(socket.calls.count(of: "updateToken(t2)") == 2)
        #expect(bridge.connectionState == .authFailed)
    }

    @Test func expiredSessionStopsTheBridge() async throws {
        let harness = BridgeHarness()
        harness.defaultTokens.refreshResults = [.failure(APIError.sessionExpired)]
        let socket = try await harness.start()
        let bridge = harness.bridge!

        await harness.send(.authFailed(message: "Token expired"), on: socket)
        await socket.calls.wait(for: "disconnect")

        #expect(bridge.connectionState == .idle)
        #expect(bridge.readerTask == nil)
        socket.continuation.yield(progressUpdate("book", currentTime: 1, lastUpdate: 100))
        socket.continuation.finish()
        #expect(harness.cache.progress(libraryItemID: "book") == nil)
        #expect(!socket.calls.values.contains { $0.hasPrefix("updateToken") })
    }

    @Test func transientRefreshFailureKeepsTheSocket() async throws {
        let harness = BridgeHarness()
        harness.defaultTokens.refreshResults = [.failure(APIError.timedOut)]
        let socket = try await harness.start()
        let bridge = harness.bridge!

        await harness.send(.authFailed(message: nil), on: socket)
        await bridge.tokenTask?.value

        #expect(bridge.connectionState == .authFailed)
        #expect(socket.calls.values == ["connect"])
        await harness.send(progressUpdate("book", currentTime: 1, lastUpdate: 100), on: socket)
        #expect(harness.cache.progress(libraryItemID: "book")?.currentTime == 1)
    }

    @Test func reconnectSwapsTheToken() async throws {
        let harness = BridgeHarness()
        harness.defaultTokens.current = nil
        let socket = try await harness.start()
        #expect(socket.configuration.token == nil)

        let newClient = try makeClient()
        harness.tokenSources[ObjectIdentifier(newClient)] = FakeTokenSource(current: "t9")
        await harness.bridge.sessionDidReconnect(harness.context(client: newClient))
        await socket.calls.wait(for: "updateToken(t9)")

        #expect(harness.sockets.values.count == 1)
        #expect(harness.bridge.connectionState == .connecting)
    }

    @Test func reconnectAfterAnOfflineStartOpensTheSocket() async throws {
        let harness = BridgeHarness()
        let client = try makeClient()
        await harness.bridge.sessionDidStart(harness.context(client: client, isOffline: true))
        #expect(harness.sockets.values.isEmpty)

        await harness.bridge.sessionDidReconnect(harness.context(client: client))
        await harness.sockets.wait(count: 1)
        await harness.sockets.values[0].calls.wait(for: "connect")
        #expect(harness.sockets.values[0].configuration.token == "t1")
    }

    @Test func networkChangesPassThrough() async throws {
        let harness = BridgeHarness()
        let socket = try await harness.start()

        await harness.bridge.networkChanged()

        #expect(socket.calls.values == ["connect", "networkChanged"])
    }

    @Test func userUpdatesReachTheHookOnlyForTheSessionUser() async throws {
        let harness = BridgeHarness()
        let socket = try await harness.start()
        let users = Recorder<User>()
        harness.bridge.onUserUpdated = { users.append($0) }
        let progress = MediaProgress(id: "p-book", libraryItemId: "book", currentTime: 5, lastUpdate: 100)

        await harness.send(.userUpdated(User(id: "b", username: "bob")), on: socket)
        await harness.send(.userUpdated(User(id: "a", username: "alice", mediaProgress: [progress])), on: socket)

        #expect(users.values.map(\.username) == ["alice"])
        // `user_updated` never seeds the cache.
        #expect(harness.cache.progress(libraryItemID: "book") == nil)
    }

    @Test func remoteProgressOffersAJumpOnlyToThePausedPlayer() async throws {
        let harness = BridgeHarness()
        let socket = try await harness.start()
        let bridge = harness.bridge!
        let offers = Recorder<UserItemProgressUpdate>()
        bridge.onRemoteProgress = { offers.append($0) }
        let player = PlayerBox(
            RealtimePlaybackSnapshot(libraryItemID: "book", playbackSessionID: "local", isPlaying: false))
        bridge.playbackSnapshot = { player.snapshot }

        // Another session's newer progress for the paused item.
        await harness.send(progressUpdate("book", currentTime: 30, lastUpdate: 100, sessionID: "remote"), on: socket)
        #expect(offers.values.map(\.progress.currentTime) == [30])
        #expect(offers.values.first?.sessionId == "remote")

        // Not for this device's own session, older progress, another item, or while playing.
        await harness.send(progressUpdate("book", currentTime: 31, lastUpdate: 101, sessionID: "local"), on: socket)
        await harness.send(progressUpdate("book", currentTime: 29, lastUpdate: 99), on: socket)
        await harness.send(progressUpdate("other", currentTime: 1, lastUpdate: 200), on: socket)
        await harness.send(progressUpdate("book", episode: "e1", currentTime: 1, lastUpdate: 200), on: socket)
        player.snapshot?.isPlaying = true
        await harness.send(progressUpdate("book", currentTime: 40, lastUpdate: 300), on: socket)
        player.snapshot = nil
        await harness.send(progressUpdate("book", currentTime: 50, lastUpdate: 400), on: socket)

        #expect(offers.values.map(\.progress.currentTime) == [30])
        // Each newer update still reached the cache.
        #expect(harness.cache.progress(libraryItemID: "book")?.currentTime == 50)
    }
}

/// What the player has open, changed by the test.
@MainActor
private final class PlayerBox {
    var snapshot: RealtimePlaybackSnapshot?

    init(_ snapshot: RealtimePlaybackSnapshot?) {
        self.snapshot = snapshot
    }
}

private struct FakeTokenProvider: TokenProvider {
    func tokens() async -> AuthTokens? { nil }
    func replaceTokens(expected: AuthTokens, with new: AuthTokens) async -> Bool { false }
    func expireSession(ifCurrent rejected: AuthTokens) async -> Bool { false }
}
