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

        // Once the socket authenticated, the new token may be refreshed once too; the server
        // returns it unchanged.
        await harness.send(.initialized(RealtimeSession(userId: "a", username: "alice")), on: socket)
        await harness.send(.authFailed(message: nil), on: socket)
        await tokens.refreshes.wait(count: 2)
        await socket.calls.wait { $0.filter { $0 == "updateToken(t2)" }.count == 2 }

        // Rejected again, even after authenticating in between: no third refresh of that token.
        await harness.send(.initialized(RealtimeSession(userId: "a", username: "alice")), on: socket)
        await harness.send(.authFailed(message: nil), on: socket)
        await bridge.tokenTask?.value
        #expect(tokens.refreshes.values == ["t1", "t2"])
        #expect(socket.calls.count(of: "updateToken(t2)") == 2)
        #expect(bridge.connectionState == .authFailed)
    }

    @Test func aSocketThatRejectsEveryTokenGetsOneRefreshPerStreak() async throws {
        let harness = BridgeHarness()
        let tokens = harness.defaultTokens
        tokens.refreshResults = [.success("t2"), .success("t3"), .success("t4")]
        let socket = try await harness.start()
        let bridge = harness.bridge!

        await harness.send(.authFailed(message: nil), on: socket)
        await socket.calls.wait(for: "updateToken(t2)")
        // The refreshed token is rejected too: no refresh until something changes.
        await harness.send(.authFailed(message: nil), on: socket)
        await bridge.tokenTask?.value
        #expect(tokens.refreshes.values == ["t1"])
        #expect(socket.calls.values == ["connect", "updateToken(t2)"])
        #expect(bridge.connectionState == .authFailed)

        // A network change retries once more, then the bridge waits again.
        await bridge.networkChanged()
        await socket.calls.wait(for: "updateToken(t3)")
        await harness.send(.authFailed(message: nil), on: socket)
        await bridge.tokenTask?.value
        #expect(tokens.refreshes.values == ["t1", "t2"])
        #expect(!socket.calls.values.contains("updateToken(t4)"))
        #expect(bridge.connectionState == .authFailed)
    }

    @Test func expiredSessionStopsTheBridgeWithoutAFarewell() async throws {
        let harness = BridgeHarness()
        harness.defaultTokens.refreshResults = [.failure(APIError.sessionExpired)]
        let socket = try await harness.start()
        let bridge = harness.bridge!
        await harness.send(.connected, on: socket)
        let handledBefore = harness.handled.values.count
        // Queued just as the bridge stops, so the reader can still find it in the stream.
        bridge.willDetach = {
            socket.continuation.yield(progressUpdate("book", currentTime: 1, lastUpdate: 100))
        }

        socket.continuation.yield(.authFailed(message: "Token expired"))
        await socket.calls.wait(for: "disconnect(noFarewell)")

        // Only the auth failure was handled; the reader had finished before the disconnect.
        #expect(harness.handled.values.count == handledBefore + 1)
        #expect(harness.cache.progress(libraryItemID: "book") == nil)
        #expect(bridge.connectionState == .idle)
        #expect(bridge.readerTask == nil)
        #expect(socket.calls.values == ["connect", "disconnect(noFarewell)"])
    }

    @Test func expiredSessionEndSendsNoFarewell() async throws {
        let harness = BridgeHarness()
        let socket = try await harness.start()

        await harness.bridge.sessionWillEnd(.expired)

        #expect(socket.calls.values == ["connect", "disconnect(noFarewell)"])
    }

    @Test func networkChangeRetriesAFailedRefresh() async throws {
        let harness = BridgeHarness()
        let tokens = harness.defaultTokens
        tokens.refreshResults = [.failure(APIError.timedOut), .success("t2")]
        let socket = try await harness.start()
        let bridge = harness.bridge!

        await harness.send(.authFailed(message: nil), on: socket)
        await bridge.tokenTask?.value
        #expect(bridge.connectionState == .authFailed)
        #expect(socket.calls.values == ["connect"])
        // The socket still delivers updates.
        await harness.send(progressUpdate("book", currentTime: 1, lastUpdate: 100), on: socket)
        #expect(harness.cache.progress(libraryItemID: "book")?.currentTime == 1)

        await bridge.networkChanged()
        await socket.calls.wait(for: "updateToken(t2)")
        #expect(tokens.refreshes.values == ["t1", "t1"])
        // The refreshed token reconnects the halted socket; no network change is passed on.
        #expect(socket.calls.values == ["connect", "updateToken(t2)"])
    }

    @Test func explicitRecoveryRefreshesATokenTheServerReturnedUnchanged() async throws {
        let harness = BridgeHarness()
        let tokens = harness.defaultTokens
        tokens.refreshResults = [.success("t1")]
        let socket = try await harness.start()
        let bridge = harness.bridge!
        await harness.send(.authFailed(message: nil), on: socket)
        await socket.calls.wait(for: "updateToken(t1)")
        await harness.send(.authFailed(message: nil), on: socket)
        await bridge.tokenTask?.value
        #expect(tokens.refreshes.values == ["t1"])

        // A network change refreshes the same token again and reconnects with it.
        await bridge.networkChanged()
        await socket.calls.wait { $0.filter { $0 == "updateToken(t1)" }.count == 2 }
        #expect(tokens.refreshes.values == ["t1", "t1"])
        #expect(!socket.calls.values.contains("networkChanged"))
        // Rejected again: the automatic guard still holds.
        await harness.send(.authFailed(message: nil), on: socket)
        await bridge.tokenTask?.value
        #expect(tokens.refreshes.values == ["t1", "t1"])

        // So does a reconnect: it resends the token, and its rejection is refreshed again.
        let client = try makeClient()
        harness.tokenSources[ObjectIdentifier(client)] = tokens
        await bridge.sessionDidReconnect(harness.context(client: client))
        await socket.calls.wait { $0.filter { $0 == "updateToken(t1)" }.count == 3 }
        await harness.send(.authFailed(message: nil), on: socket)
        await socket.calls.wait { $0.filter { $0 == "updateToken(t1)" }.count == 4 }
        #expect(tokens.refreshes.values == ["t1", "t1", "t1"])
    }

    @Test func reconnectAfterAFailedRefreshRefreshesTheSameTokenAgain() async throws {
        let harness = BridgeHarness()
        let tokens = harness.defaultTokens
        tokens.refreshResults = [.failure(APIError.timedOut), .success("t2")]
        let socket = try await harness.start()
        let bridge = harness.bridge!
        await harness.send(.authFailed(message: nil), on: socket)
        await bridge.tokenTask?.value

        // The reconnect resends the same, still stored, token.
        let client = try makeClient()
        harness.tokenSources[ObjectIdentifier(client)] = tokens
        await bridge.sessionDidReconnect(harness.context(client: client))
        await socket.calls.wait(for: "updateToken(t1)")
        await harness.send(.authFailed(message: nil), on: socket)
        await socket.calls.wait(for: "updateToken(t2)")

        #expect(tokens.refreshes.values == ["t1", "t1"])
    }

    @Test func reconnectSwapsTheToken() async throws {
        let harness = BridgeHarness()
        let socket = try await harness.start()

        let newClient = try makeClient()
        harness.tokenSources[ObjectIdentifier(newClient)] = FakeTokenSource(current: "t9")
        await harness.bridge.sessionDidReconnect(harness.context(client: newClient))
        await socket.calls.wait(for: "updateToken(t9)")

        #expect(harness.sockets.values.count == 1)
        #expect(harness.bridge.connectionState == .connecting)
    }

    @Test func reconnectSupersedesARefreshInFlight() async throws {
        let harness = BridgeHarness()
        let tokens = harness.defaultTokens
        tokens.refreshResults = [.failure(APIError.sessionExpired)]
        let gate = Gate()
        tokens.refreshGate = gate
        let socket = try await harness.start()
        let bridge = harness.bridge!
        await harness.send(.authFailed(message: nil), on: socket)
        await tokens.refreshes.wait(count: 1)
        let refresh = bridge.tokenTask

        let newClient = try makeClient()
        harness.tokenSources[ObjectIdentifier(newClient)] = FakeTokenSource(current: "t5")
        await bridge.sessionDidReconnect(harness.context(client: newClient))
        await socket.calls.wait(for: "updateToken(t5)")
        // The old client's refresh then reports an expired session: it no longer counts.
        gate.open()
        await refresh?.value

        #expect(socket.calls.values == ["connect", "updateToken(t5)"])
        #expect(bridge.readerTask != nil)
        #expect(bridge.connectionState == .connecting)
    }

    @Test func reconnectWithoutAUsableTokenClosesTheSocket() async throws {
        let harness = BridgeHarness()
        let socket = try await harness.start()
        let bridge = harness.bridge!
        await harness.send(.initialized(RealtimeSession(userId: "a", username: "alice")), on: socket)
        #expect(bridge.connectionState == .connected)

        let expired = FakeTokenSource(current: "t1")
        expired.readError = APIError.sessionExpired
        let client = try makeClient()
        harness.tokenSources[ObjectIdentifier(client)] = expired
        await bridge.sessionDidReconnect(harness.context(client: client))
        let task = bridge.tokenTask
        await task?.value

        #expect(socket.calls.values == ["connect", "disconnect(noFarewell)"])
        #expect(bridge.readerTask == nil)
        #expect(bridge.connectionState == .idle)

        // A later reconnect with a token opens a new socket.
        let next = try makeClient()
        harness.tokenSources[ObjectIdentifier(next)] = FakeTokenSource(current: "t9")
        await bridge.sessionDidReconnect(harness.context(client: next))
        await harness.sockets.wait(count: 2)
        #expect(harness.sockets.values.map(\.configuration.token) == ["t1", "t9"])
    }

    @Test func aTokenThatExpiredAndCouldNotBeRefreshedOpensNoSocket() async throws {
        let harness = BridgeHarness()
        // APIClient returns a still-valid token itself after a transient failure; an error
        // means the stored token can't be used.
        harness.defaultTokens.readError = APIError.timedOut
        await harness.bridge.sessionDidStart(harness.context(client: try makeClient()))
        await harness.bridge.startTask?.value

        #expect(harness.sockets.values.isEmpty)
        #expect(harness.bridge.connectionState == .idle)
    }

    @Test func startWithoutATokenStaysIdleUntilAReconnect() async throws {
        let harness = BridgeHarness()
        harness.defaultTokens.current = nil
        await harness.bridge.sessionDidStart(harness.context(client: try makeClient()))
        await harness.bridge.startTask?.value
        #expect(harness.sockets.values.isEmpty)
        #expect(harness.bridge.connectionState == .idle)

        let client = try makeClient()
        harness.tokenSources[ObjectIdentifier(client)] = FakeTokenSource(current: "t9")
        await harness.bridge.sessionDidReconnect(harness.context(client: client))
        await harness.sockets.wait(count: 1)
        #expect(harness.sockets.values[0].configuration.token == "t9")
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

    @Test func reconnectWhileTheFirstStartIsOpeningUsesTheNewClient() async throws {
        let harness = BridgeHarness()
        let gate = Gate()
        harness.defaultTokens.readGate = gate
        await harness.bridge.sessionDidStart(harness.context(client: try makeClient()))
        await harness.defaultTokens.reads.wait(count: 1)
        let firstStart = harness.bridge.startTask

        let client = try makeClient()
        harness.tokenSources[ObjectIdentifier(client)] = FakeTokenSource(current: "t7")
        await harness.bridge.sessionDidReconnect(harness.context(client: client))
        await harness.sockets.wait(count: 1)
        gate.open()
        await firstStart?.value

        #expect(harness.sockets.values.map(\.configuration.token) == ["t7"])
    }

    @Test func endWhileTheStartIsHeldOpensNoSocket() async throws {
        let harness = BridgeHarness()
        let gate = Gate()
        harness.defaultTokens.readGate = gate
        await harness.bridge.sessionDidStart(harness.context(client: try makeClient()))
        await harness.defaultTokens.reads.wait(count: 1)
        let start = harness.bridge.startTask

        await harness.bridge.sessionWillEnd(.signOut)
        gate.open()
        await start?.value

        #expect(harness.sockets.values.isEmpty)
        #expect(harness.bridge.connectionState == .idle)
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

    @Test func echoesOfThisDevicesPlaybackAreSkipped() async throws {
        let harness = BridgeHarness()
        let socket = try await harness.start()
        let bridge = harness.bridge!
        bridge.playbackSnapshot = {
            RealtimePlaybackSnapshot(
                libraryItemID: "book", playbackSessionID: "local", isPlaying: true, currentTime: 60)
        }
        // Local progress stamped with the device clock, behind the server's.
        harness.cache.apply(MediaProgress(id: "p-book", libraryItemId: "book", currentTime: 60, lastUpdate: 1_000))

        // The echo of an earlier sync carries a later server time but an older position.
        await harness.send(progressUpdate("book", currentTime: 50, lastUpdate: 5_000, sessionID: "local"), on: socket)
        #expect(harness.cache.progress(libraryItemID: "book")?.currentTime == 60)

        // The same session's progress for another item isn't an echo of the open one.
        await harness.send(progressUpdate("other", currentTime: 5, lastUpdate: 5_000, sessionID: "local"), on: socket)
        #expect(harness.cache.progress(libraryItemID: "other")?.currentTime == 5)

        // Another session's newer progress still lands.
        await harness.send(progressUpdate("book", currentTime: 70, lastUpdate: 6_000, sessionID: "web"), on: socket)
        #expect(harness.cache.progress(libraryItemID: "book")?.currentTime == 70)

        // An echo that finishes the item (the server's auto-finish) goes through.
        await harness.send(
            progressUpdate("book", currentTime: 100, isFinished: true, lastUpdate: 7_000, sessionID: "local"),
            on: socket)
        #expect(harness.cache.progress(libraryItemID: "book")?.isFinished == true)
        #expect(harness.cache.progress(libraryItemID: "book")?.currentTime == 100)
    }

    @Test func remoteProgressOffersAJumpOnlyToThePausedPlayer() async throws {
        let harness = BridgeHarness()
        let socket = try await harness.start()
        let bridge = harness.bridge!
        let offers = Recorder<UserItemProgressUpdate>()
        bridge.onRemoteProgress = { offers.append($0) }
        let player = PlayerBox(
            RealtimePlaybackSnapshot(
                libraryItemID: "book", playbackSessionID: "local", isPlaying: false, currentTime: 10))
        bridge.playbackSnapshot = { player.snapshot }

        // Another session's progress for the paused item.
        await harness.send(progressUpdate("book", currentTime: 30, lastUpdate: 100, sessionID: "remote"), on: socket)
        #expect(offers.values.map(\.progress.currentTime) == [30])
        #expect(offers.values.first?.sessionId == "remote")

        // Unlike the legacy app, progress older than the cached one offers no jump backwards.
        await harness.send(progressUpdate("book", currentTime: 20, lastUpdate: 90), on: socket)
        #expect(offers.values.map(\.progress.currentTime) == [30])
        #expect(harness.cache.progress(libraryItemID: "book")?.currentTime == 30)

        // Not for this device's own session, a position within a second of the player's (an
        // ebook or finished change), another item or episode, while playing or with no player.
        await harness.send(progressUpdate("book", currentTime: 31, lastUpdate: 101, sessionID: "local"), on: socket)
        await harness.send(progressUpdate("book", currentTime: 10.5, lastUpdate: 103), on: socket)
        await harness.send(progressUpdate("book", currentTime: 9.2, lastUpdate: 104), on: socket)
        await harness.send(progressUpdate("other", currentTime: 1, lastUpdate: 200), on: socket)
        await harness.send(progressUpdate("book", episode: "e1", currentTime: 1, lastUpdate: 200), on: socket)
        player.snapshot?.isPlaying = true
        await harness.send(progressUpdate("book", currentTime: 40, lastUpdate: 300), on: socket)
        player.snapshot = nil
        await harness.send(progressUpdate("book", currentTime: 50, lastUpdate: 400), on: socket)

        #expect(offers.values.map(\.progress.currentTime) == [30])
        #expect(harness.cache.progress(libraryItemID: "book")?.currentTime == 50)
    }

    @Test func progressAlreadyFetchedIntoTheCacheIsStillOffered() async throws {
        let harness = BridgeHarness()
        let socket = try await harness.start()
        let bridge = harness.bridge!
        let offers = Recorder<UserItemProgressUpdate>()
        bridge.onRemoteProgress = { offers.append($0) }
        bridge.playbackSnapshot = {
            RealtimePlaybackSnapshot(
                libraryItemID: "book", playbackSessionID: "local", isPlaying: false, currentTime: 10)
        }
        // A fetch brought the other device's position before its socket event arrived.
        harness.cache.apply(MediaProgress(id: "p-book", libraryItemId: "book", currentTime: 30, lastUpdate: 100))

        await harness.send(progressUpdate("book", currentTime: 30, lastUpdate: 100), on: socket)

        #expect(offers.values.map(\.progress.currentTime) == [30])
    }

    @Test func anEqualTimestampOffersOnlyTheCachedPosition() async throws {
        let harness = BridgeHarness()
        let socket = try await harness.start()
        let bridge = harness.bridge!
        let offers = Recorder<UserItemProgressUpdate>()
        bridge.onRemoteProgress = { offers.append($0) }
        bridge.playbackSnapshot = {
            RealtimePlaybackSnapshot(
                libraryItemID: "book", playbackSessionID: "local", isPlaying: false, currentTime: 10)
        }
        harness.cache.apply(MediaProgress(id: "p-book", libraryItemId: "book", currentTime: 30, lastUpdate: 100))

        // As old as the cached progress but elsewhere: stale, so no offer.
        await harness.send(progressUpdate("book", currentTime: 20, lastUpdate: 100), on: socket)
        #expect(offers.values.isEmpty)
        // As old and at the cached position (within a second): the same progress.
        await harness.send(progressUpdate("book", currentTime: 30.4, lastUpdate: 100), on: socket)

        #expect(offers.values.map(\.progress.currentTime) == [30.4])
        #expect(harness.cache.progress(libraryItemID: "book")?.currentTime == 30)
    }

    @Test func updatesWithoutASessionFollowTheLegacyComparison() async throws {
        let harness = BridgeHarness()
        let socket = try await harness.start()
        let bridge = harness.bridge!
        let offers = Recorder<UserItemProgressUpdate>()
        bridge.onRemoteProgress = { offers.append($0) }
        let player = PlayerBox(
            RealtimePlaybackSnapshot(libraryItemID: "book", playbackSessionID: nil, isPlaying: false, currentTime: 0))
        bridge.playbackSnapshot = { player.snapshot }

        // No playback session on either side: the same "session", so no offer, but it's applied.
        await harness.send(progressUpdate("book", currentTime: 5, lastUpdate: 100, sessionID: nil), on: socket)
        #expect(offers.values.isEmpty)
        #expect(harness.cache.progress(libraryItemID: "book")?.currentTime == 5)

        // With a local session, an update without one (say, a web edit) is offered.
        player.snapshot?.playbackSessionID = "local"
        await harness.send(progressUpdate("book", currentTime: 8, lastUpdate: 200, sessionID: nil), on: socket)
        #expect(offers.values.map(\.progress.currentTime) == [8])
        #expect(harness.cache.progress(libraryItemID: "book")?.currentTime == 8)
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
