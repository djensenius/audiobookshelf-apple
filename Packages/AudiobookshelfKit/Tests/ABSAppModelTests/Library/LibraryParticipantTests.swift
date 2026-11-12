import ABSAPI
import ABSCore
import Foundation
import Testing

@testable import ABSAppModel

private let keyA = LibraryConnectionKey(connectionID: identityA.connectionID, userID: identityA.userID)
private let keyB = LibraryConnectionKey(connectionID: identityB.connectionID, userID: identityB.userID)

private func progress(_ itemID: String, at time: Double = 1) -> MediaProgress {
    MediaProgress(id: "p-\(itemID)", libraryItemId: itemID, currentTime: time)
}

/// A participant whose `/api/me` and libraries requests wait for the test to answer them.
@MainActor
private struct Harness {
    let store: LibraryStore
    let participant: LibraryParticipant
    /// `/api/me` requests, with the client each was sent through.
    let me = GatedCalls<ObjectIdentifier, [MediaProgress]>()
    let libraries = GatedCalls<Void, [Library]>()

    /// - Parameter gatesLibraries: whether libraries requests wait on ``libraries``; otherwise
    ///   they answer with none.
    init(settings: AppSettings, defaultLibraryID: String? = nil, gatesLibraries: Bool = false) {
        store = LibraryStore(settings: settings)
        var service = FakeLibraryService()
        if gatesLibraries { service.librariesHandler = { [libraries] in try await libraries.call(()) } }
        let me = me
        participant = LibraryParticipant(
            store: store, defaultLibraryID: { defaultLibraryID }, service: { _ in service },
            fetchProgress: { client in try await me.call(ObjectIdentifier(client)) })
    }

    func context(
        _ identity: SessionIdentity = identityA, client: APIClient?, isOffline: Bool = false, sessionID: UInt64 = 1
    ) -> SessionContext {
        SessionContext(identity: identity, client: client, isOffline: isOffline, sessionID: sessionID)
    }

    var cached: Set<String> {
        Set(["a", "b", "old", "new", "stale"].filter { store.progress.progress(libraryItemID: $0) != nil })
    }
}

@MainActor
@Suite struct LibraryParticipantTests {
    @Test func startAttachesPromptlyAndRefreshesInItsOwnTask() async throws {
        try await withLibrarySettings { settings in
            let harness = Harness(settings: settings, defaultLibraryID: "default", gatesLibraries: true)
            var requests = harness.libraries.calls.makeAsyncIterator()

            // Returns with the libraries request still unanswered.
            await harness.participant.sessionDidStart(harness.context(client: try makeClient()))
            #expect(harness.store.connectionKey == keyA)
            #expect(harness.store.defaultLibraryID == "default")
            #expect(!harness.store.hasLoaded)

            let request = try #require(await requests.next())
            request.reply.resume(returning: [makeLibrary("books")])
            #expect(await eventually { harness.store.hasLoaded })
            #expect(harness.store.libraries.map(\.id) == ["books"])
        }
    }

    @Test func offlineStartAttachesWithoutRequests() async throws {
        try await withLibrarySettings { settings in
            let harness = Harness(settings: settings)
            let context = harness.context(client: nil, isOffline: true)
            await harness.participant.sessionDidStart(context)
            await harness.participant.beginSeed(context)
            await harness.participant.seed(context)

            #expect(harness.store.connectionKey == keyA)
            #expect(harness.store.client == nil)
            #expect(!harness.store.isLoading)
        }
    }

    /// The cache is only ever seeded with the list `/api/me` returned, through the seed's client.
    @Test func seedsOnlyFromMe() async throws {
        try await withLibrarySettings { settings in
            let harness = Harness(settings: settings)
            var me = harness.me.calls.makeAsyncIterator()
            let client = try makeClient()
            let context = harness.context(client: client)
            await harness.participant.sessionDidStart(context)
            await harness.participant.beginSeed(context)
            #expect(harness.cached.isEmpty)

            let seed = Task { await harness.participant.seed(context) }
            let call = try #require(await me.next())
            #expect(call.request == ObjectIdentifier(client))
            call.reply.resume(returning: [progress("a")])
            await seed.value
            #expect(harness.cached == ["a"])

            // A failed request seeds nothing: the cache keeps what it has.
            await harness.participant.beginSeed(context)
            let failed = Task { await harness.participant.seed(context) }
            try #require(await me.next()).reply.resume(throwing: TestError.offline)
            await failed.value
            #expect(harness.cached == ["a"])
        }
    }

    @Test func staleSeedAfterReconnectIsDropped() async throws {
        try await withLibrarySettings { settings in
            let harness = Harness(settings: settings)
            var me = harness.me.calls.makeAsyncIterator()
            let first = harness.context(client: try makeClient())
            await harness.participant.sessionDidStart(first)
            await harness.participant.beginSeed(first)
            let staleSeed = Task { await harness.participant.seed(first) }
            let stale = try #require(await me.next())

            // The lifecycle's reconnect order: boundary, reconnect hooks, then the new seed.
            let newClient = try makeClient()
            let second = harness.context(client: newClient)
            await harness.participant.beginSeed(second)
            await harness.participant.sessionDidReconnect(second)
            let freshSeed = Task { await harness.participant.seed(second) }
            let fresh = try #require(await me.next())
            #expect(fresh.request == ObjectIdentifier(newClient))

            // The stale response arrives first and must not be applied.
            stale.reply.resume(returning: [progress("stale")])
            await staleSeed.value
            #expect(harness.cached.isEmpty)
            fresh.reply.resume(returning: [progress("new")])
            await freshSeed.value
            #expect(harness.cached == ["new"])
        }
    }

    @Test func staleSeedAfterSwitchIsDropped() async throws {
        try await withLibrarySettings { settings in
            let harness = Harness(settings: settings)
            var me = harness.me.calls.makeAsyncIterator()
            let contextA = harness.context(client: try makeClient())
            await harness.participant.sessionDidStart(contextA)
            await harness.participant.beginSeed(contextA)
            let seedA = Task { await harness.participant.seed(contextA) }
            let callA = try #require(await me.next())

            await harness.participant.sessionWillEnd(.switch)
            let contextB = harness.context(identityB, client: try makeClient(), sessionID: 2)
            await harness.participant.sessionDidStart(contextB)
            await harness.participant.beginSeed(contextB)

            callA.reply.resume(returning: [progress("a")])
            await seedA.value
            #expect(harness.store.connectionKey == keyB)
            #expect(harness.cached.isEmpty)
        }
    }

    @Test func endClearsWhileTheRefreshIsRunning() async throws {
        try await withLibrarySettings { settings in
            let harness = Harness(settings: settings, gatesLibraries: true)
            var requests = harness.libraries.calls.makeAsyncIterator()
            let context = harness.context(client: try makeClient())
            await harness.participant.sessionDidStart(context)
            let request = try #require(await requests.next())
            #expect(harness.participant.progressSink(for: context)(progress("a")))

            await harness.participant.sessionWillEnd(.signOut)
            #expect(harness.store.connectionKey == nil)
            #expect(harness.cached.isEmpty)

            // The refresh's late answer doesn't bring the account back.
            request.reply.resume(returning: [makeLibrary("books")])
            for _ in 0..<50 { await Task.yield() }
            #expect(harness.store.libraries.isEmpty)
            #expect(!harness.store.hasLoaded)
        }
    }

    /// Start without a boundary or seed, a seed after the end, and an end without a start.
    @Test func partialPipelinesAreHarmless() async throws {
        try await withLibrarySettings { settings in
            let harness = Harness(settings: settings)
            await harness.participant.sessionWillEnd(.signOut)
            let context = harness.context(client: try makeClient(), isOffline: true)
            await harness.participant.sessionDidStart(context)
            await harness.participant.sessionWillEnd(.switch)

            // A seed that starts after the end never requests.
            let seed = Task { await harness.participant.seed(context) }
            await seed.value
            await harness.participant.beginSeed(context)
            await harness.participant.sessionDidReconnect(harness.context(client: try makeClient()))
            #expect(harness.store.connectionKey == nil)
            #expect(harness.cached.isEmpty)
        }
    }

    @Test func progressSinkIsGatedBySession() async throws {
        try await withLibrarySettings { settings in
            let harness = Harness(settings: settings)
            let first = harness.context(client: nil, isOffline: true)
            await harness.participant.sessionDidStart(first)
            let oldSink = harness.participant.progressSink(for: first)
            #expect(oldSink(progress("a")))
            #expect(harness.cached == ["a"])

            await harness.participant.sessionWillEnd(.switch)
            let second = harness.context(identityB, client: nil, isOffline: true, sessionID: 2)
            await harness.participant.sessionDidStart(second)
            #expect(!oldSink(progress("old")))
            #expect(harness.participant.progressSink(for: second)(progress("b")))
            #expect(harness.cached == ["b"])
        }
    }

    /// Through the real lifecycle: a start connects, then seeds from `/api/me`.
    @Test func lifecycleConnectsAndSeeds() async throws {
        try await withLibrarySettings { settings in
            let harness = Harness(settings: settings)
            var me = harness.me.calls.makeAsyncIterator()
            let source = FakeAccountSource(log: CallLog())
            source.restoredPhase = .active(identityA, isOffline: false)
            source.restoredClient = try makeClient()
            let lifecycle = SessionLifecycle(source: source)
            lifecycle.register(seeder: harness.participant)

            await lifecycle.start()
            #expect(harness.store.connectionKey == keyA)
            try #require(await me.next()).reply.resume(returning: [progress("a")])
            #expect(await eventually { harness.cached == ["a"] })

            _ = await lifecycle.signOut()
            #expect(harness.store.connectionKey == nil)
            #expect(harness.cached.isEmpty)
        }
    }
}
