import ABSAPI
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
    /// Transitions the lifecycle rejected as re-entrant.
    let misuse = CallLog()

    init(restoredPhase: AccountSessionPhase = .active(identityA, isOffline: false), restoredClient: APIClient? = nil) {
        source = FakeAccountSource(log: log)
        source.restoredPhase = restoredPhase
        source.restoredClient = restoredClient
        library = FakeLibrary(log: log)
        images = FakeParticipant("images", log: log)
        playback = FakeParticipant("playback", log: log)
        socket = FakeParticipant("socket", log: log)
        lifecycle = SessionLifecycle(source: source, clock: clock)
        lifecycle.reportMisuse = { [misuse] in misuse.record($0) }
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
        // The observation reads the source once more when it begins; let that settle first.
        try #require(await eventually { lifecycle.reconciledObservations > 0 })
        log.clear()
    }
}

private let allFlushes: Set<String> = [
    "socket.flush", "socket.flushed", "playback.flush", "playback.flushed", "images.flush", "images.flushed",
    "library.flush", "library.flushed",
]

private func pipeline(_ user: String) -> [String] {
    [
        "library.connect(\(user))", "images.start(\(user))", "library.beginSeed(\(user))", "playback.start(\(user))",
        "socket.start(\(user))", "library.fetchMe(\(user))", "library.seed(\(user))",
    ]
}

private func teardown(_ reason: String) -> [String] {
    ["socket.end(\(reason))", "playback.end(\(reason))", "images.end(\(reason))", "library.clear(\(reason))"]
}

@MainActor
@Suite struct SessionLifecycleTests {
    // MARK: Start

    @Test func startConnectsThenBeginsSeedThenStartsSourcesThenSeeds() async {
        let harness = Harness()

        await harness.lifecycle.start()
        #expect(await eventually { harness.log.entries.contains("library.seed(a)") })

        #expect(harness.log.entries == ["accounts.restore"] + pipeline("a"))
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

    // MARK: Reconnect

    @Test func comingOnlineWithAClientReseedsAroundTheSources() async throws {
        let harness = Harness(restoredPhase: .active(identityA, isOffline: true))
        try await harness.started()

        await harness.source.reconnect(client: try makeClient())
        #expect(await eventually { harness.log.entries.contains("library.seed(a)") })

        #expect(
            harness.log.entries == [
                "library.beginSeed(a)", "library.reconnect(a)", "images.reconnect(a)", "playback.reconnect(a)",
                "socket.reconnect(a)", "library.fetchMe(a)", "library.seed(a)",
            ])
        #expect(harness.lifecycle.gate == .ready(identityA, isOffline: false))
    }

    @Test func aNewClientForTheSameIdentityReseeds() async throws {
        let harness = Harness(restoredClient: try makeClient())
        try await harness.started()

        await harness.source.reconnect(client: try makeClient())
        #expect(await eventually { harness.log.entries.contains("library.seed(a)") })

        #expect(harness.log.entries.first == "library.beginSeed(a)")
        #expect(harness.log.count(of: "library.beginSeed(a)") == 1)
        #expect(!harness.log.entries.contains { $0.contains(".end(") || $0.contains(".start(") })
    }

    @Test func progressAppliedWhileAReconnectHookIsSuspendedSurvivesTheSeed() async throws {
        let harness = Harness(restoredPhase: .active(identityA, isOffline: true))
        try await harness.started()
        let reconnectGate = Gate()
        harness.images.reconnectGate = reconnectGate

        await harness.source.reconnect(client: try makeClient())
        #expect(await eventually { harness.log.entries.contains("images.reconnect(a)") })
        // Playback keeps running through the reconnect.
        harness.library.apply("item")
        reconnectGate.open()
        #expect(await eventually { harness.log.entries.contains("library.seed(a)") })

        #expect(harness.library.progress == ["item"])
    }

    @Test func goingOfflineOnlyChangesTheGate() async throws {
        let harness = Harness()
        try await harness.started()

        harness.source.phase = .active(identityA, isOffline: true)
        #expect(await eventually { harness.lifecycle.gate == .ready(identityA, isOffline: true) })

        #expect(harness.log.entries.isEmpty)
    }

    // MARK: Sign out

    @Test func signOutFlushesThenEndsInReverseThenClearsThenLogsOut() async throws {
        let harness = Harness()
        try await harness.started()

        let url = await harness.lifecycle.signOut()

        #expect(harness.log.flushes == allFlushes)
        #expect(harness.log.withoutFlushes == teardown("signOut") + ["accounts.logout"])
        let lastFlush = try #require(harness.log.entries.lastIndex { $0.contains(".flush") })
        #expect(lastFlush < harness.log.entries.firstIndex(of: "socket.end(signOut)") ?? 0)
        #expect(url == URL(string: "https://idp.example/logout"))
        #expect(harness.lifecycle.gate == .connect)
    }

    @Test func secondSignOutDoesNothing() async throws {
        let harness = Harness()
        try await harness.started()

        async let first = harness.lifecycle.signOut()
        async let second = harness.lifecycle.signOut()
        _ = await (first, second)

        #expect(harness.log.count(of: "accounts.logout") == 1)
        #expect(harness.log.count(of: "library.clear(signOut)") == 1)
        #expect(harness.lifecycle.gate == .connect)
    }

    @Test func signOutBeforeStartFinishesRunsAfterTheRestore() async {
        let harness = Harness()
        let restoreGate = Gate()
        harness.source.restoreGate = restoreGate

        let start = Task { await harness.lifecycle.start() }
        #expect(await eventually { harness.source.restoreCount == 1 })
        let signOut = Task { await harness.lifecycle.signOut() }
        restoreGate.open()
        await start.value
        _ = await signOut.value

        let entries = harness.log.withoutFlushes.filter {
            !$0.hasPrefix("library.fetchMe") && !$0.hasPrefix("library.seed")
        }
        #expect(entries == ["accounts.restore"] + pipeline("a").prefix(5) + teardown("signOut") + ["accounts.logout"])
        #expect(harness.lifecycle.gate == .connect)
    }

    @Test func signOutRequestedFromInsideTheStartRunsAfterIt() async {
        let harness = Harness()
        let lifecycle = harness.lifecycle
        let playback = harness.playback
        harness.playback.onStart = { if let context = playback.context { lifecycle.requestSignOut(of: context) } }

        await harness.lifecycle.start()
        #expect(await eventually { harness.log.entries.contains("accounts.logout") })

        let entries = harness.log.withoutFlushes.filter {
            !$0.hasPrefix("library.fetchMe") && !$0.hasPrefix("library.seed")
        }
        #expect(entries == ["accounts.restore"] + pipeline("a").prefix(5) + teardown("signOut") + ["accounts.logout"])
        #expect(harness.lifecycle.gate == .connect)
    }

    @Test func signOutFromATaskAParticipantStartedRunsOnceTheStartEnded() async throws {
        let harness = Harness()
        let lifecycle = harness.lifecycle
        let rejected = Gate()
        var signOut: Task<URL?, Never>?
        harness.playback.onStart = {
            signOut = Task {
                await rejected.wait()
                return await lifecycle.signOut()
            }
        }
        try await harness.started()

        rejected.open()
        let url = await signOut?.value

        #expect(url == URL(string: "https://idp.example/logout"))
        #expect(harness.log.withoutFlushes == teardown("signOut") + ["accounts.logout"])
        #expect(harness.lifecycle.gate == .connect)
    }

    @Test func signOutRequestedByTheOldSessionDuringASwitchLeavesTheNewOneSignedIn() async throws {
        let harness = Harness()
        try await harness.started()
        let lifecycle = harness.lifecycle
        let contextA = try #require(harness.socket.context)
        harness.socket.onEnd = { lifecycle.requestSignOut(of: contextA) }

        try await lifecycle.switchAccount(to: identityB.connectionID)
        // A transition queued after the request, to wait for it.
        try await lifecycle.switchAccount(to: identityB.connectionID)
        #expect(await eventually { harness.log.entries.contains("library.seed(b)") })

        #expect(!harness.log.entries.contains("accounts.logout"))
        #expect(harness.lifecycle.gate == .ready(identityB, isOffline: false))
    }

    @Test(arguments: [false, true])
    func signOutRequestedByAStaleTaskIsIgnoredWhenTheAccountIsBack(signsOutFirst: Bool) async throws {
        let harness = Harness()
        let lifecycle = harness.lifecycle
        let playback = harness.playback
        let rejected = Gate()
        var request: Task<Void, Never>?
        harness.playback.onStart = {
            guard let context = playback.context else { return }
            request = Task {
                await rejected.wait()
                lifecycle.requestSignOut(of: context)
            }
        }
        try await harness.started()
        if signsOutFirst {
            await lifecycle.signOut()
            harness.source.phase = .active(identityA, isOffline: false)
        } else {
            try await lifecycle.switchAccount(to: identityB.connectionID)
            try await lifecycle.switchAccount(to: identityA.connectionID)
        }
        #expect(await eventually { harness.log.entries.contains("library.seed(a)") })

        rejected.open()
        await request?.value
        // A no-op transition queued after the request, to wait for it.
        try await lifecycle.switchAccount(to: identityA.connectionID)

        #expect(harness.log.count(of: "accounts.logout") == (signsOutFirst ? 1 : 0))
        #expect(harness.lifecycle.gate == .ready(identityA, isOffline: false))
    }

    @Test func signOutRequestedBeforeTheSourceMovedOnLeavesTheNewAccountSignedIn() async throws {
        let harness = Harness()
        try await harness.started()
        let contextA = try #require(harness.playback.context)

        // Queued before the observation's reconcile, so it runs while the session is still A.
        harness.lifecycle.requestSignOut(of: contextA)
        harness.source.phase = .active(identityB, isOffline: false)
        #expect(await eventually { harness.log.entries.contains("library.seed(b)") })
        try await harness.lifecycle.switchAccount(to: identityB.connectionID)

        #expect(!harness.log.entries.contains("accounts.logout"))
        #expect(harness.lifecycle.gate == .ready(identityB, isOffline: false))
    }

    @Test func signOutRequestedAfterAnExpiryEndsTheSessionAsExpired() async throws {
        let harness = Harness()
        try await harness.started()

        harness.source.expireUnobserved()
        harness.lifecycle.requestSignOut(of: try #require(harness.playback.context))
        #expect(await eventually { harness.lifecycle.gate == .connect })
        // Signed out, so this only waits for the queue.
        await harness.lifecycle.signOut()

        #expect(harness.log.entries == teardown("expired"))
    }

    @Test func signOutRequestedDuringAnAccountChangeLeavesTheSignInAlone() async throws {
        let harness = Harness()
        try await harness.started()
        let lifecycle = harness.lifecycle
        let contextA = try #require(harness.playback.context)

        await lifecycle.performAccountChange {
            lifecycle.requestSignOut(of: contextA)
            // A nested change with no body waits for the queue, so the request runs first.
            await lifecycle.performAccountChange {}
            harness.source.phase = .active(identityB, isOffline: false)
        }
        #expect(await eventually { harness.log.entries.contains("library.seed(b)") })

        #expect(harness.log.withoutFlushes == teardown("switch") + pipeline("b"))
        #expect(harness.lifecycle.gate == .ready(identityB, isOffline: false))
    }

    @Test(arguments: ["switchAccount(to:)", "removeAccount(_:)", "performAccountChange(_:)"])
    func transitionFromInsideATransitionIsRejected(operation: String) async throws {
        let harness = Harness()
        let lifecycle = harness.lifecycle
        harness.playback.onStart = {
            switch operation {
            case "switchAccount(to:)": try? await lifecycle.switchAccount(to: identityB.connectionID)
            case "removeAccount(_:)": _ = try? await lifecycle.removeAccount(identityA.connectionID)
            default: await lifecycle.performAccountChange {}
            }
        }

        try await harness.started()
        try await lifecycle.switchAccount(to: identityA.connectionID)

        #expect(harness.misuse.entries == ["\(operation) was called from inside a session transition"])
        #expect(harness.log.entries.isEmpty)
        #expect(harness.lifecycle.gate == .ready(identityA, isOffline: false))
    }

    @Test func signOutKeepsAStoreUnavailableGate() async {
        let harness = Harness()
        harness.source.restoreError = StoreFailure()
        await harness.lifecycle.start()

        await harness.lifecycle.signOut()

        #expect(harness.lifecycle.gate == .storeUnavailable(SessionStoreError(StoreFailure())))
    }

    // MARK: Switch

    @Test func switchEndsAccountACompletelyBeforeBConnects() async throws {
        let harness = Harness()
        try await harness.started()
        var gateDuringSwitch: AuthGate?
        harness.source.onSwitch = { gateDuringSwitch = harness.lifecycle.gate }

        try await harness.lifecycle.switchAccount(to: identityB.connectionID)
        #expect(await eventually { harness.log.entries.contains("library.seed(b)") })

        #expect(harness.log.flushes == allFlushes)
        #expect(harness.log.withoutFlushes == teardown("switch") + ["accounts.switch(b)"] + pipeline("b"))
        #expect(gateDuringSwitch == .switching(from: identityA))
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
        #expect(await eventually { harness.log.entries.contains("library.seed(a)") })

        #expect(harness.log.withoutFlushes == teardown("switch") + ["accounts.switch(b)"] + pipeline("a"))
        #expect(harness.lifecycle.gate == .ready(identityA, isOffline: false))
    }

    @Test func switchThatSignsOutWithoutThrowingShowsConnect() async throws {
        let harness = Harness()
        try await harness.started()
        harness.source.switchSignsOut = true

        try await harness.lifecycle.switchAccount(to: identityB.connectionID)

        #expect(harness.log.withoutFlushes == teardown("switch") + ["accounts.switch(b)"])
        #expect(harness.lifecycle.gate == .connect)
    }

    @Test func identityChangedByTheSourceEndsTheOldSessionFirst() async throws {
        let harness = Harness()
        try await harness.started()

        harness.source.phase = .active(identityB, isOffline: false)
        #expect(await eventually { harness.log.entries.contains("library.seed(b)") })

        #expect(harness.log.entries == teardown("switch") + pipeline("b"))
        #expect(harness.lifecycle.gate == .ready(identityB, isOffline: false))
    }

    @Test func seedThatFinishesAfterTheSwitchIsDropped() async {
        let harness = Harness()
        let seedGate = Gate()
        harness.library.seedGate = seedGate
        await harness.lifecycle.start()
        #expect(await eventually { harness.log.entries.contains("library.fetchMe(a)") })

        try? await harness.lifecycle.switchAccount(to: identityB.connectionID)
        #expect(await eventually { harness.log.entries.contains("library.fetchMe(b)") })
        seedGate.open()
        #expect(await eventually { harness.log.entries.contains("library.seed(b)") })

        #expect(harness.log.entries.contains("library.seedDropped(a)"))
        #expect(!harness.log.entries.contains("library.seed(a)"))
    }

    // MARK: Account changes

    @Test func removingTheActiveAccountEndsItWithRemoved() async throws {
        let harness = Harness()
        try await harness.started()

        let url = try await harness.lifecycle.removeAccount(identityA.connectionID)

        #expect(harness.log.flushes == allFlushes)
        #expect(harness.log.withoutFlushes == teardown("removed") + ["accounts.remove(a)"])
        #expect(url == URL(string: "https://idp.example/logout"))
        #expect(harness.lifecycle.gate == .connect)
    }

    @Test func removingAnotherAccountLeavesTheSession() async throws {
        let harness = Harness()
        try await harness.started()

        try await harness.lifecycle.removeAccount(identityB.connectionID)

        #expect(harness.log.entries == ["accounts.remove(b)"])
        #expect(harness.lifecycle.gate == .ready(identityA, isOffline: false))
    }

    @Test func accountChangeEndsTheSessionThenStartsTheAccountThatSignedIn() async throws {
        let harness = Harness()
        try await harness.started()
        var gateDuringChange: AuthGate?

        await harness.lifecycle.performAccountChange {
            gateDuringChange = harness.lifecycle.gate
            harness.source.phase = .active(identityB, isOffline: false)
        }
        #expect(await eventually { harness.log.entries.contains("library.seed(b)") })

        #expect(harness.log.flushes == allFlushes)
        #expect(harness.log.withoutFlushes == teardown("switch") + pipeline("b"))
        #expect(gateDuringChange == .switching(from: identityA))
        #expect(harness.lifecycle.gate == .ready(identityB, isOffline: false))
    }

    @Test func accountChangeToTheSameIdentityWithANewClientRestartsIt() async throws {
        let harness = Harness(restoredClient: try makeClient())
        try await harness.started()
        let client = try makeClient()

        await harness.lifecycle.performAccountChange { await harness.source.reconnect(client: client) }
        #expect(await eventually { harness.log.entries.contains("library.seed(a)") })

        #expect(harness.log.withoutFlushes == teardown("switch") + pipeline("a"))
        #expect(harness.lifecycle.gate == .ready(identityA, isOffline: false))
    }

    @Test(arguments: [false, true])
    func accountChangeThatFailsRestartsTheSession(cancelled: Bool) async throws {
        let harness = Harness()
        try await harness.started()

        do {
            try await harness.lifecycle.performAccountChange {
                if cancelled { throw CancellationError() } else { throw StoreFailure() }
            }
            Issue.record("performAccountChange didn't rethrow")
        } catch {
            #expect(cancelled ? error is CancellationError : error is StoreFailure)
        }
        #expect(await eventually { harness.log.entries.contains("library.seed(a)") })

        #expect(harness.log.withoutFlushes == teardown("switch") + pipeline("a"))
        #expect(harness.lifecycle.gate == .ready(identityA, isOffline: false))
    }

    @Test func noSessionStartsUntilTheLastOverlappingAccountChangeFinishes() async throws {
        let harness = Harness()
        try await harness.started()
        let lifecycle = harness.lifecycle
        let firstGate = Gate()
        let secondGate = Gate()
        var secondEntered = false

        let first = Task {
            await lifecycle.performAccountChange {
                await firstGate.wait()
                harness.source.phase = .active(identityB, isOffline: false)
            }
        }
        #expect(await eventually { harness.lifecycle.gate == .switching(from: identityA) })
        let second = Task {
            await lifecycle.performAccountChange {
                secondEntered = true
                await secondGate.wait()
            }
        }
        #expect(await eventually { secondEntered })
        firstGate.open()
        await first.value
        for _ in 0..<50 { await Task.yield() }
        #expect(!harness.log.entries.contains("library.connect(b)"))
        #expect(harness.lifecycle.gate == .switching(from: identityA))

        secondGate.open()
        await second.value
        #expect(await eventually { harness.log.entries.contains("library.seed(b)") })

        #expect(harness.log.withoutFlushes == teardown("switch") + pipeline("b"))
        #expect(harness.lifecycle.gate == .ready(identityB, isOffline: false))
    }

    @Test func overlappingAccountChangesFollowTheAccountOnceBothFinish() async throws {
        let harness = Harness()
        try await harness.started()
        let lifecycle = harness.lifecycle
        let firstGate = Gate()
        let secondGate = Gate()
        var secondEntered = false

        let first = Task { await lifecycle.performAccountChange { await firstGate.wait() } }
        #expect(await eventually { harness.lifecycle.gate == .switching(from: identityA) })
        let second = Task {
            await lifecycle.performAccountChange {
                secondEntered = true
                await secondGate.wait()
                harness.source.phase = .active(identityB, isOffline: false)
            }
        }
        #expect(await eventually { secondEntered })
        firstGate.open()
        await first.value
        for _ in 0..<50 { await Task.yield() }
        #expect(!harness.log.entries.contains("library.connect(a)"))
        #expect(harness.lifecycle.gate == .switching(from: identityA))

        secondGate.open()
        await second.value
        #expect(await eventually { harness.log.entries.contains("library.seed(b)") })

        #expect(harness.log.withoutFlushes == teardown("switch") + pipeline("b"))
        #expect(harness.lifecycle.gate == .ready(identityB, isOffline: false))
    }

    // MARK: Expiry

    @Test func expiryTearsDownWithoutFlushingOrLoggingOut() async throws {
        let harness = Harness()
        try await harness.started()

        harness.source.expire()
        #expect(await eventually { harness.lifecycle.gate == .connect })

        #expect(harness.log.entries == teardown("expired"))
    }

    @Test func expiryWhileTheSessionStartsEndsItAsExpired() async {
        let harness = Harness()
        let connectGate = Gate()
        harness.library.connectGate = connectGate
        let start = Task { await harness.lifecycle.start() }
        #expect(await eventually { harness.log.entries.contains("library.connect(a)") })

        harness.source.expire()
        connectGate.open()
        await start.value
        #expect(await eventually { harness.lifecycle.gate == .connect })

        // Nothing after the library starts once the source left: only what started ends.
        #expect(harness.log.entries == ["accounts.restore", "library.connect(a)", "library.clear(expired)"])
    }

    @Test func expiryDuringASwitchFlushEndsTheOldSessionOnce() async throws {
        let harness = Harness()
        try await harness.started()
        let flushGate = Gate()
        harness.playback.flushGate = flushGate

        let switching = Task { try await harness.lifecycle.switchAccount(to: identityB.connectionID) }
        #expect(await eventually { harness.log.entries.contains("playback.flush") && harness.clock.sleeperCount == 1 })
        harness.source.expire()
        harness.clock.advance(by: .seconds(3))
        try await switching.value
        #expect(await eventually { harness.log.entries.contains("library.seed(b)") })

        #expect(harness.log.withoutFlushes == teardown("switch") + ["accounts.switch(b)"] + pipeline("b"))
        #expect(harness.lifecycle.gate == .ready(identityB, isOffline: false))
    }

    @Test(arguments: ["signOut", "switch", "remove", "removeOther"])
    func transitionAfterAnUnreconciledExpiryEndsAsExpiredWithoutFlushing(operation: String) async throws {
        let harness = Harness()
        try await harness.started()

        harness.source.expireUnobserved()
        let expected: [String]
        switch operation {
        case "signOut":
            await harness.lifecycle.signOut()
            expected = []
        case "switch":
            try await harness.lifecycle.switchAccount(to: identityB.connectionID)
            #expect(await eventually { harness.log.entries.contains("library.seed(b)") })
            expected = ["accounts.switch(b)"] + pipeline("b")
        case "remove":
            try await harness.lifecycle.removeAccount(identityA.connectionID)
            expected = ["accounts.remove(a)"]
        default:
            try await harness.lifecycle.removeAccount(identityB.connectionID)
            expected = ["accounts.remove(b)"]
        }

        #expect(harness.log.entries == teardown("expired") + expected)
        #expect(harness.lifecycle.gate == (operation == "switch" ? .ready(identityB, isOffline: false) : .connect))
    }

    @Test(arguments: ["signOut", "accountChange"])
    func transitionAfterTheSourceShowsAnotherAccountEndsTheOldSessionWithoutFlushing(operation: String) async throws {
        let harness = Harness()
        try await harness.started()

        harness.source.publishUnobserved(.active(identityB, isOffline: false))
        let expected: [String]
        if operation == "signOut" {
            await harness.lifecycle.signOut()
            expected = ["accounts.logout"]
        } else {
            await harness.lifecycle.performAccountChange {}
            #expect(await eventually { harness.log.entries.contains("library.seed(b)") })
            expected = pipeline("b")
        }

        #expect(harness.log.entries == teardown("switch") + expected)
    }

    @Test(arguments: [false, true])
    func selectingTheCachedAccountAfterTheSourceMovedOnSwitchesBack(expired: Bool) async throws {
        let harness = Harness()
        try await harness.started()

        if expired {
            harness.source.expireUnobserved()
        } else {
            harness.source.publishUnobserved(.active(identityB, isOffline: false))
        }
        try await harness.lifecycle.switchAccount(to: identityA.connectionID)
        #expect(await eventually { harness.log.entries.contains("library.seed(a)") })

        #expect(
            harness.log.entries == teardown(expired ? "expired" : "switch") + ["accounts.switch(a)"] + pipeline("a"))
        #expect(harness.source.phase == .active(identityA, isOffline: false))
        #expect(harness.lifecycle.gate == .ready(identityA, isOffline: false))
    }

    @Test(arguments: [false, true])
    func backgroundAfterTheSourceLeftTheSessionDoesNotFlush(expired: Bool) async throws {
        let harness = Harness()
        try await harness.started()

        if expired {
            harness.source.expireUnobserved()
        } else {
            harness.source.publishUnobserved(.active(identityB, isOffline: false))
        }
        await harness.lifecycle.handle(scenePhase: .background)
        // A transition queued after the background's reconcile, to wait for it.
        try await harness.lifecycle.removeAccount(UUID())
        #expect(await eventually { expired || harness.log.entries.contains("library.seed(b)") })

        #expect(harness.log.flushes.isEmpty)
        #expect(
            harness.log.entries.filter { $0 != "accounts.remove(?)" }
                == teardown(expired ? "expired" : "switch") + (expired ? [] : pipeline("b")))
        #expect(harness.lifecycle.gate == (expired ? .connect : .ready(identityB, isOffline: false)))
    }

    @Test func sourceThatExpiresDuringASwitchTeardownStartsNothing() async throws {
        let harness = Harness()
        try await harness.started()
        let endGate = Gate()
        harness.socket.endGate = endGate
        defer { endGate.open() }

        harness.source.phase = .active(identityB, isOffline: false)
        #expect(await eventually { harness.log.entries.contains("socket.end(switch)") })
        harness.source.expire()
        endGate.open()
        #expect(await eventually { harness.lifecycle.gate == .connect })
        // Signed out, so this only waits for the queue.
        await harness.lifecycle.signOut()

        #expect(harness.log.entries == ["socket.end(switch)", "socket.ended"] + teardown("switch").dropFirst())
        #expect(harness.lifecycle.gate == .connect)
    }

    @Test func expiryDuringAReconnectHookReconnectsNothingMore() async throws {
        let harness = Harness(restoredPhase: .active(identityA, isOffline: true))
        try await harness.started()
        let reconnectGate = Gate()
        harness.images.reconnectGate = reconnectGate

        let reconnect = Task { await harness.source.reconnect(client: try makeClient()) }
        #expect(await eventually { harness.log.entries.contains("images.reconnect(a)") })
        harness.source.expire()
        reconnectGate.open()
        try await reconnect.value
        #expect(await eventually { harness.lifecycle.gate == .connect })
        await harness.lifecycle.signOut()

        #expect(
            harness.log.entries == ["library.beginSeed(a)", "library.reconnect(a)", "images.reconnect(a)"]
                + teardown("expired"))
    }

    // MARK: Flush

    @Test func flushIsBoundedAndASlowParticipantDoesNotStarveTheOthers() async throws {
        let harness = Harness()
        try await harness.started()
        let flushGate = Gate()
        harness.playback.flushGate = flushGate
        defer { flushGate.open() }

        let signOut = Task { await harness.lifecycle.signOut() }
        #expect(
            await eventually {
                ["socket.flushed", "images.flushed", "library.flushed", "playback.flush"]
                    .allSatisfy(harness.log.entries.contains) && harness.clock.sleeperCount == 1
            })
        #expect(harness.lifecycle.gate == .signingOut(from: identityA))

        harness.clock.advance(by: .seconds(2))
        for _ in 0..<50 { await Task.yield() }
        #expect(harness.clock.sleeperCount == 1)
        #expect(!harness.log.entries.contains("playback.flushed"))
        #expect(!harness.log.entries.contains("playback.flushCancelled"))
        #expect(!harness.log.entries.contains("socket.end(signOut)"))

        harness.clock.advance(by: .seconds(1))
        _ = await signOut.value
        #expect(await eventually { harness.log.entries.contains("playback.flushCancelled") })

        #expect(!harness.log.entries.contains("playback.flushed"))
        #expect(harness.log.withoutFlushes == teardown("signOut") + ["accounts.logout"])
    }

    @Test func teardownSharesOneBudgetAndAHangingEndDoesNotBlockTheNextSession() async throws {
        let harness = Harness()
        try await harness.started()
        let socketGate = Gate()
        let playbackGate = Gate()
        harness.socket.endGate = socketGate
        harness.playback.endGate = playbackGate
        defer {
            socketGate.open()
            playbackGate.open()
        }

        let switching = Task { try await harness.lifecycle.switchAccount(to: identityB.connectionID) }
        #expect(
            await eventually { harness.log.entries.contains("socket.end(switch)") && harness.clock.sleeperCount == 1 })
        #expect(!harness.log.entries.contains("playback.end(switch)"))

        harness.clock.advance(by: .seconds(3))
        try await switching.value
        #expect(await eventually { harness.log.entries.contains("library.seed(b)") })
        #expect(await eventually { harness.log.entries.contains("playback.endCancelled") })

        let cancelled: Set = ["socket.endCancelled", "playback.endCancelled"]
        #expect(harness.log.entries.contains("socket.endCancelled"))
        #expect(
            harness.log.withoutFlushes.filter { !cancelled.contains($0) }
                == teardown("switch") + ["accounts.switch(b)"] + pipeline("b"))
        #expect(harness.clock.sleeperCount == 0)
    }

    @Test func backgroundFlushDuringASignOutFlushesBeforeEachEnd() async throws {
        let harness = Harness()
        try await harness.started()
        let flushGate = Gate()
        harness.playback.flushGate = flushGate

        let background = Task { await harness.lifecycle.handle(scenePhase: .background) }
        #expect(await eventually { harness.log.count(of: "playback.flush") == 1 })
        let signOut = Task { await harness.lifecycle.signOut() }
        #expect(await eventually { harness.log.count(of: "playback.flush") == 2 })
        flushGate.open()
        await background.value
        _ = await signOut.value
        await harness.lifecycle.handle(scenePhase: .background)

        let entries = harness.log.entries
        for name in ["socket", "playback", "images"] {
            let end = try #require(entries.firstIndex(of: "\(name).end(signOut)"))
            #expect(!entries[end...].contains { $0.hasPrefix("\(name).flush") })
        }
        #expect(harness.log.count(of: "playback.flushed") == 2)
        #expect(harness.log.withoutFlushes == teardown("signOut") + ["accounts.logout"])
    }

    @Test func backgroundFlushesTheSessionAndActiveDoesNot() async throws {
        let harness = Harness()
        try await harness.started()

        await harness.lifecycle.handle(scenePhase: .active)
        await harness.lifecycle.handle(scenePhase: .inactive)
        #expect(harness.log.entries.isEmpty)

        await harness.lifecycle.handle(scenePhase: .background)
        #expect(harness.log.flushes == allFlushes)
        #expect(harness.log.withoutFlushes.isEmpty)
        #expect(harness.lifecycle.gate == .ready(identityA, isOffline: false))
    }

    @Test func backgroundWithoutASessionDoesNothing() async {
        let harness = Harness(restoredPhase: .signedOut)
        await harness.lifecycle.start()

        await harness.lifecycle.handle(scenePhase: .background)

        #expect(harness.log.entries == ["accounts.restore"])
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

    @Test func storeErrorsOfDifferentTypesDiffer() {
        struct Other: Error, CustomStringConvertible {
            var description: String { "The store couldn't be opened." }
        }
        #expect(SessionStoreError(StoreFailure()) != SessionStoreError(Other()))
    }
}
