import Foundation
import Testing

@testable import ABSAppModel

/// A lifecycle with the library seeder, an image-like connect participant, and two progress
/// sources, all recording into one log.
@MainActor
private struct Harness {
    let log = CallLog()
    let source: FakeAccountSource
    let library: FakeLibrary
    let images: FakeParticipant
    let playback: FakeParticipant
    let socket: FakeParticipant
    let clock = ManualClock()
    let lifecycle: SessionLifecycle

    init(restoredPhase: AccountSessionPhase = .active(identityA, isOffline: false)) {
        source = FakeAccountSource(log: log)
        source.restoredPhase = restoredPhase
        library = FakeLibrary(log: log)
        images = FakeParticipant("images", log: log)
        playback = FakeParticipant("playback", log: log)
        socket = FakeParticipant("socket", log: log)
        lifecycle = SessionLifecycle(source: source, clock: clock)
        // Registered out of pipeline order on purpose: the stages decide the order.
        lifecycle.register(playback, stage: .progressSource)
        lifecycle.register(images, stage: .connect)
        lifecycle.register(seeder: library)
        lifecycle.register(socket, stage: .progressSource)
    }

    /// Starts, waits for the seed, and clears the log.
    func started() async throws {
        await lifecycle.start()
        try #require(await eventually { log.entries.contains("library.seed(a)") })
        log.clear()
    }
}

@MainActor
@Suite struct SessionLifecycleTests {
    // MARK: Start order

    @Test func startConnectsThenBeginsSeedThenStartsSourcesThenSeeds() async {
        let harness = Harness()

        await harness.lifecycle.start()
        #expect(await eventually { harness.log.entries.contains("library.seed(a)") })

        #expect(
            harness.log.entries == [
                "accounts.restore",
                "library.connect(a)",
                "images.start(a)",
                "library.beginSeed(a)",
                "playback.start(a)",
                "socket.start(a)",
                "library.fetchMe(a)",
                "library.seed(a)",
            ])
        #expect(harness.lifecycle.gate == .ready(identityA, isOffline: false))
    }

    @Test func startTwiceFromTwoScenesRunsOnce() async {
        let harness = Harness()

        async let first: Void = harness.lifecycle.start()
        async let second: Void = harness.lifecycle.start()
        async let carPlay: Void = harness.lifecycle.start()
        _ = await (first, second, carPlay)
        await harness.lifecycle.start()

        #expect(harness.source.restoreCount == 1)
        #expect(harness.log.count(of: "library.connect(a)") == 1)
        #expect(harness.log.count(of: "playback.start(a)") == 1)
        #expect(harness.lifecycle.gate == .ready(identityA, isOffline: false))
    }

    // MARK: End order

    @Test func signOutFlushesThenEndsInReverseThenClearsThenLogsOut() async throws {
        let harness = Harness()
        try await harness.started()

        let url = await harness.lifecycle.signOut()

        #expect(
            harness.log.entries == [
                "socket.flush",
                "playback.flush",
                "images.flush",
                "library.flush",
                "socket.end(signOut)",
                "playback.end(signOut)",
                "images.end(signOut)",
                "library.clear(signOut)",
                "accounts.logout",
            ])
        #expect(url == URL(string: "https://idp.example/logout"))
        #expect(harness.lifecycle.gate == .connect)
    }

    @Test func switchEndsAccountACompletelyBeforeBConnects() async throws {
        let harness = Harness()
        try await harness.started()

        try await harness.lifecycle.switchAccount(to: identityB.connectionID)
        #expect(await eventually { harness.log.entries.contains("library.seed(b)") })

        #expect(
            harness.log.entries == [
                "socket.flush",
                "playback.flush",
                "images.flush",
                "library.flush",
                "socket.end(switch)",
                "playback.end(switch)",
                "images.end(switch)",
                "library.clear(switch)",
                "accounts.switch(b)",
                "library.connect(b)",
                "images.start(b)",
                "library.beginSeed(b)",
                "playback.start(b)",
                "socket.start(b)",
                "library.fetchMe(b)",
                "library.seed(b)",
            ])
        #expect(harness.lifecycle.gate == .ready(identityB, isOffline: false))
    }

    @Test func switchToTheActiveConnectionDoesNothing() async throws {
        let harness = Harness()
        try await harness.started()

        try await harness.lifecycle.switchAccount(to: identityA.connectionID)

        #expect(harness.log.entries.isEmpty)
        #expect(harness.lifecycle.gate == .ready(identityA, isOffline: false))
    }

    @Test func failedSwitchRestartsTheOldSession() async throws {
        let harness = Harness()
        try await harness.started()
        harness.source.switchError = StoreFailure()

        await #expect(throws: StoreFailure.self) {
            try await harness.lifecycle.switchAccount(to: identityB.connectionID)
        }

        #expect(harness.log.entries.contains("library.clear(switch)"))
        #expect(harness.log.entries.last(where: { $0.hasPrefix("library.connect") }) == "library.connect(a)")
        #expect(harness.lifecycle.gate == .ready(identityA, isOffline: false))
    }

    @Test func identityChangedByTheSourceEndsTheOldSessionFirst() async throws {
        let harness = Harness()
        try await harness.started()

        harness.source.phase = .active(identityB, isOffline: false)
        #expect(await eventually { harness.log.entries.contains("library.seed(b)") })

        let entries = harness.log.entries
        #expect(!entries.contains { $0.hasSuffix(".flush") })
        let cleared = try #require(entries.firstIndex(of: "library.clear(switch)"))
        let connected = try #require(entries.firstIndex(of: "library.connect(b)"))
        #expect(cleared < connected)
        #expect(harness.lifecycle.gate == .ready(identityB, isOffline: false))
    }

    // MARK: Expiry

    @Test func expiryTearsDownWithoutFlushingOrLoggingOut() async throws {
        let harness = Harness()
        try await harness.started()

        harness.source.expire()
        #expect(await eventually { harness.lifecycle.gate == .connect })

        #expect(
            harness.log.entries == [
                "socket.end(expired)",
                "playback.end(expired)",
                "images.end(expired)",
                "library.clear(expired)",
            ])
    }

    // MARK: Flush

    @Test func signOutWaitsForTheFlushOnlyUpToTheTimeout() async throws {
        let harness = Harness()
        try await harness.started()
        harness.playback.blocksFlush = true
        defer { harness.playback.releaseFlush() }

        let signOut = Task { await harness.lifecycle.signOut() }
        #expect(await eventually { harness.log.entries.contains("playback.flush") && harness.clock.sleeperCount == 1 })

        harness.clock.advance(by: .seconds(2))
        for _ in 0..<50 { await Task.yield() }
        #expect(!harness.log.entries.contains("socket.end(signOut)"))

        harness.clock.advance(by: .seconds(1))
        _ = await signOut.value

        #expect(
            harness.log.entries == [
                "socket.flush",
                "playback.flush",
                "socket.end(signOut)",
                "playback.end(signOut)",
                "images.end(signOut)",
                "library.clear(signOut)",
                "accounts.logout",
            ])
    }

    @Test func backgroundFlushesTheSessionAndActiveDoesNot() async throws {
        let harness = Harness()
        try await harness.started()

        await harness.lifecycle.handle(scenePhase: .active)
        await harness.lifecycle.handle(scenePhase: .inactive)
        #expect(harness.log.entries.isEmpty)

        await harness.lifecycle.handle(scenePhase: .background)
        #expect(harness.log.entries == ["socket.flush", "playback.flush", "images.flush", "library.flush"])
        #expect(harness.lifecycle.gate == .ready(identityA, isOffline: false))
    }

    // MARK: Gate

    @Test func gateIsLaunchingBeforeStart() {
        let harness = Harness()
        #expect(harness.lifecycle.gate == .launching)
    }

    @Test func gateGoesFromLaunchingToConnectWhenNothingIsRestored() async {
        let harness = Harness(restoredPhase: .signedOut)

        await harness.lifecycle.start()

        #expect(harness.lifecycle.gate == .connect)
        #expect(harness.log.entries == ["accounts.restore"])
    }

    @Test func gateGoesFromLaunchingToReadyOffline() async {
        let harness = Harness(restoredPhase: .active(identityA, isOffline: true))

        await harness.lifecycle.start()

        #expect(harness.lifecycle.gate == .ready(identityA, isOffline: true))
        #expect(harness.lifecycle.gate.identity?.snapshotKey == "nav.snapshot.AAAAAAAA-0000-0000-0000-000000000000.a")
    }

    @Test func gateFollowsConnectivityWithoutRestartingTheSession() async throws {
        let harness = Harness()
        try await harness.started()

        harness.source.phase = .active(identityA, isOffline: true)
        #expect(await eventually { harness.lifecycle.gate == .ready(identityA, isOffline: true) })

        #expect(harness.log.entries.isEmpty)
    }

    @Test func gateGoesFromConnectToReadyWhenTheUserSignsIn() async {
        let harness = Harness(restoredPhase: .signedOut)
        await harness.lifecycle.start()

        harness.source.phase = .active(identityB, isOffline: false)
        #expect(await eventually { harness.log.entries.contains("library.seed(b)") })

        #expect(harness.lifecycle.gate == .ready(identityB, isOffline: false))
    }

    @Test func gateShowsStoreUnavailableWhenRestoreThrows() async {
        let harness = Harness()
        harness.source.restoreError = StoreFailure()

        await harness.lifecycle.start()

        #expect(harness.lifecycle.gate == .storeUnavailable(SessionStoreError(StoreFailure())))
        #expect(!harness.log.entries.contains { $0.hasPrefix("library") })
    }

    @Test func storeUnavailableLifecycleShowsTheError() async {
        let lifecycle = SessionLifecycle(storeUnavailable: StoreFailure())
        #expect(lifecycle.gate == .launching)

        await lifecycle.start()

        #expect(lifecycle.gate == .storeUnavailable(SessionStoreError(StoreFailure())))
    }
}
