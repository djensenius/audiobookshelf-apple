import ABSAPI
import ABSCore
import ABSData
import ABSPlayback
import Foundation
import Testing

@testable import ABSAppModel

private let keyA = LibraryConnectionKey(connectionID: identityA.connectionID, userID: identityA.userID)
private let keyB = LibraryConnectionKey(connectionID: identityB.connectionID, userID: identityB.userID)

private func progress(_ itemID: String, at time: Double = 1) -> MediaProgress {
    MediaProgress(id: "p-\(itemID)", libraryItemId: itemID, currentTime: time)
}

/// Answers the `n`th `/api/me` request (from 1) sent through a client, or `nil` to wait on
/// ``Harness/me``.
private typealias MeAnswer = @Sendable (_ client: ObjectIdentifier, _ n: Int) throws -> [MediaProgress]?

/// A participant whose `/api/me` and libraries requests wait for the test to answer them,
/// unless `answer` answers at once. Every request is counted, and backoffs don't wait.
@MainActor
private struct Harness {
    let store: LibraryStore
    let participant: LibraryParticipant
    /// `/api/me` requests, with the client each was sent through.
    let me = GatedCalls<ObjectIdentifier, [MediaProgress]>()
    let libraries = GatedCalls<Void, [Library]>()
    /// The client of every `/api/me` request so far.
    let meRequests = Locked<[ObjectIdentifier]>([])
    let libraryRequests = Locked(0)
    /// The backoffs the participant waited out.
    let sleeps = Locked<[Duration]>([])
    /// The malformed rows every `/api/me` response reports.
    let skippedRows = Locked(0)

    /// - Parameter gatesLibraries: whether libraries requests wait on ``libraries``; otherwise
    ///   they answer with none.
    init(
        settings: AppSettings, defaultLibraryID: String? = nil, gatesLibraries: Bool = false,
        answer: MeAnswer? = nil
    ) {
        store = LibraryStore(settings: settings)
        var service = FakeLibraryService()
        let libraryRequests = libraryRequests
        service.librariesHandler = { [libraries] in
            libraryRequests.value += 1
            return gatesLibraries ? try await libraries.call(()) : []
        }
        let me = me
        let meRequests = meRequests
        let sleeps = sleeps
        let skippedRows = skippedRows
        participant = LibraryParticipant(
            store: store, defaultLibraryID: { defaultLibraryID }, service: { _ in service },
            fetchProgress: { client in
                let id = ObjectIdentifier(client)
                meRequests.value.append(id)
                let skipped = skippedRows.value
                if let answer = try answer?(id, meRequests.value.count) {
                    return UserProgressResponse(mediaProgress: answer, skippedRows: skipped)
                }
                return UserProgressResponse(mediaProgress: try await me.call(id), skippedRows: skipped)
            },
            sleep: { sleeps.value.append($0) })
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
            for _ in 0..<20 { await Task.yield() }
            #expect(harness.meRequests.value.isEmpty)
            #expect(harness.libraryRequests.value == 0)
        }
    }

    /// Offline at start without a client; the reconnect attaches its client, refreshes the
    /// libraries and seeds the cache.
    @Test func offlineStartThenReconnectAttachesRefreshesAndSeeds() async throws {
        try await withLibrarySettings { settings in
            let harness = Harness(settings: settings, answer: { _, _ in [progress("a")] })
            let offline = harness.context(client: nil, isOffline: true)
            await harness.participant.sessionDidStart(offline)
            await harness.participant.beginSeed(offline)
            await harness.participant.seed(offline)
            #expect(harness.meRequests.value.isEmpty)
            // Loads keyed on it run again once a client attaches.
            #expect(harness.store.connectionKey == keyA)
            #expect(harness.store.connectedKey == nil)

            let client = try makeClient()
            let online = harness.context(client: client)
            await harness.participant.beginSeed(online)
            await harness.participant.sessionDidReconnect(online)
            await harness.participant.seed(online)

            #expect(harness.store.client != nil)
            #expect(harness.store.connectedKey == keyA)
            #expect(await eventually { harness.store.hasLoaded })
            #expect(harness.libraryRequests.value == 1)
            #expect(harness.meRequests.value == [ObjectIdentifier(client)])
            #expect(harness.cached == ["a"])
        }
    }

    /// Offline at start with a client (`AccountManager.goOffline` keeps it): ``connectedKey`` is
    /// the same before and after the reconnect, so the online revision is what tells failed
    /// loads to retry. Going offline again doesn't bump it.
    @Test func offlineStartWithAClientThenReconnectBumpsTheOnlineRevision() async throws {
        try await withLibrarySettings { settings in
            let harness = Harness(settings: settings)
            let client = try makeClient()
            let offline = harness.context(client: client, isOffline: true)
            await harness.participant.sessionDidStart(offline)
            let key = harness.store.connectedKey
            let revision = harness.store.onlineRevision
            #expect(key == keyA)

            await harness.participant.sessionDidReconnect(harness.context(client: client))
            #expect(harness.store.connectedKey == key)
            #expect(harness.store.onlineRevision > revision)

            let online = harness.store.onlineRevision
            await harness.participant.sessionDidReconnect(offline)
            #expect(harness.store.onlineRevision == online)
        }
    }

    /// A transient failure (timeout, 5xx) is retried after the backoff and still seeds.
    @Test func transientSeedFailureIsRetried() async throws {
        try await withLibrarySettings { settings in
            let harness = Harness(
                settings: settings,
                answer: { _, n in
                    if n == 1 { throw APIError.timedOut }
                    if n == 2 { throw APIError.http(status: 503, message: nil) }
                    return [progress("a")]
                })
            let context = harness.context(client: try makeClient())
            await harness.participant.sessionDidStart(context)
            await harness.participant.beginSeed(context)
            await harness.participant.seed(context)

            #expect(harness.cached == ["a"])
            #expect(harness.meRequests.value.count == 3)
            #expect(harness.sleeps.value == Array(LibraryParticipant.defaultRetryDelays.prefix(2)))
        }
    }

    /// Retries stop after the last backoff, and a permanent failure isn't retried.
    @Test func seedRetriesAreBounded() async throws {
        try await withLibrarySettings { settings in
            let permanent = Locked(false)
            let harness = Harness(
                settings: settings,
                answer: { _, _ in throw permanent.value ? APIError.notFound : APIError.timedOut })
            let context = harness.context(client: try makeClient())
            await harness.participant.sessionDidStart(context)
            await harness.participant.beginSeed(context)
            await harness.participant.seed(context)
            #expect(harness.meRequests.value.count == LibraryParticipant.defaultRetryDelays.count + 1)
            #expect(harness.sleeps.value == LibraryParticipant.defaultRetryDelays)

            permanent.value = true
            await harness.participant.beginSeed(context)
            await harness.participant.seed(context)
            #expect(harness.meRequests.value.count == LibraryParticipant.defaultRetryDelays.count + 2)
            #expect(harness.cached.isEmpty)
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

    /// A list with malformed rows is incomplete: the cache is kept instead of losing the
    /// skipped rows' progress as if the server had deleted it.
    @Test func incompleteSeedKeepsCachedProgress() async throws {
        try await withLibrarySettings { settings in
            let harness = Harness(
                settings: settings,
                answer: { _, n in n == 1 ? [progress("a"), progress("b")] : [progress("b", at: 5)] })
            let context = harness.context(client: try makeClient())
            await harness.participant.sessionDidStart(context)
            await harness.participant.beginSeed(context)
            await harness.participant.seed(context)
            #expect(harness.cached == ["a", "b"])

            harness.skippedRows.value = 1
            await harness.participant.beginSeed(context)
            await harness.participant.seed(context)
            #expect(harness.cached == ["a", "b"])
            #expect(harness.store.progress.progress(libraryItemID: "b")?.currentTime == 1)
            #expect(harness.sleeps.value.isEmpty)
        }
    }

    /// An old row with `libraryItemId: null` doesn't stop the account's other rows seeding.
    @Test func nullItemRowStillSeedsValidRows() async throws {
        try await withLibrarySettings { settings in
            let store = LibraryStore(settings: settings)
            let payload = Data(
                (#"{"mediaProgress":[{"id":"p-old","libraryItemId":null,"currentTime":3,"duration":10,"progress":0.3},"#
                    + #"{"id":"p-a","libraryItemId":"a","currentTime":12,"duration":100,"progress":0.12}]}"#).utf8)
            let participant = LibraryParticipant(
                store: store, service: { _ in FakeLibraryService() },
                fetchProgress: { _ in try JSONDecoder().decode(UserProgressResponse.self, from: payload) },
                sleep: { _ in })
            let context = SessionContext(identity: identityA, client: try makeClient(), isOffline: false, sessionID: 1)
            await participant.sessionDidStart(context)
            await participant.beginSeed(context)
            await participant.seed(context)

            #expect(store.progress.progress(libraryItemID: "a")?.currentTime == 12)
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

    /// A's seed, in flight or only starting after B's boundary, never lands in B's cache, and
    /// B's seed does. The late start is what the participant alone guards: B's boundary token
    /// is valid in the cache, so only the session check keeps A's request (through A's client)
    /// from seeding with it.
    @Test func staleSeedAfterSwitchIsDropped() async throws {
        try await withLibrarySettings { settings in
            let clientA = try makeClient()
            let clientB = try makeClient()
            let idA = ObjectIdentifier(clientA)
            let harness = Harness(
                settings: settings,
                answer: { client, n in client == idA ? (n == 1 ? nil : [progress("a")]) : [progress("b")] })
            var me = harness.me.calls.makeAsyncIterator()
            let contextA = harness.context(client: clientA)
            await harness.participant.sessionDidStart(contextA)
            await harness.participant.beginSeed(contextA)
            let seedA = Task { await harness.participant.seed(contextA) }
            let callA = try #require(await me.next())

            await harness.participant.sessionWillEnd(.switch)
            let contextB = harness.context(identityB, client: clientB, sessionID: 2)
            await harness.participant.sessionDidStart(contextB)
            await harness.participant.beginSeed(contextB)

            callA.reply.resume(returning: [progress("a")])
            await seedA.value
            await harness.participant.seed(contextA)
            #expect(harness.store.connectionKey == keyB)
            // A's shell, still up during the switch, no longer gets the store.
            #expect(!harness.store.serves(identityA))
            #expect(harness.store.serves(identityB))
            #expect(harness.cached.isEmpty)
            #expect(harness.meRequests.value == [idA])

            await harness.participant.seed(contextB)
            #expect(harness.cached == ["b"])
            #expect(harness.meRequests.value == [idA, ObjectIdentifier(clientB)])
        }
    }

    /// A reconnect replaces the refresh in flight: the old request's late answer is ignored.
    @Test func reconnectReplacesTheRefreshInFlight() async throws {
        try await withLibrarySettings { settings in
            let harness = Harness(settings: settings, gatesLibraries: true)
            var requests = harness.libraries.calls.makeAsyncIterator()
            let first = harness.context(client: try makeClient())
            await harness.participant.sessionDidStart(first)
            let old = try #require(await requests.next())

            await harness.participant.sessionDidReconnect(harness.context(client: try makeClient()))
            let new = try #require(await requests.next())
            new.reply.resume(returning: [makeLibrary("new")])
            #expect(await eventually { harness.store.hasLoaded })
            old.reply.resume(returning: [makeLibrary("old")])
            for _ in 0..<50 { await Task.yield() }

            #expect(harness.store.libraries.map(\.id) == ["new"])
            #expect(harness.libraryRequests.value == 2)
        }
    }

    @Test func endClearsWhileTheRefreshIsRunning() async throws {
        try await withLibrarySettings { settings in
            let harness = Harness(settings: settings, gatesLibraries: true)
            var requests = harness.libraries.calls.makeAsyncIterator()
            let context = harness.context(client: try makeClient())
            await harness.participant.sessionDidStart(context)
            let request = try #require(await requests.next())
            #expect(harness.store.progress.apply(progress("a")))

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

    // MARK: Playback progress

    /// The running session's playback moves its cached progress and keeps the row's other
    /// fields; media without a row gets one (#184).
    @Test func playbackProgressMovesTheRunningSessionsCache() async throws {
        try await withLibrarySettings { settings in
            let harness = Harness(settings: settings)
            await harness.participant.sessionDidStart(harness.context(client: nil, isOffline: true, sessionID: 7))
            var finished = progress("a", at: 10)
            finished.duration = 100
            finished.isFinished = true
            finished.lastUpdate = 1_000
            harness.store.progress.apply(finished)

            #expect(harness.participant.applyPlaybackProgress(playback("a", at: 40, duration: 0), sessionID: 7))
            let a = try #require(harness.store.progress.progress(libraryItemID: "a"))
            #expect(a.id == "p-a")
            #expect(a.currentTime == 40)
            #expect(a.duration == 100)
            #expect(a.progress == 0.4)
            #expect(a.isFinished)
            #expect(a.lastUpdate == 2_000)

            #expect(harness.participant.applyPlaybackProgress(playback("b", at: 30, duration: 60), sessionID: 7))
            let b = try #require(harness.store.progress.progress(libraryItemID: "b"))
            #expect(b.id == "b")
            #expect(b.progress == 0.5)
            #expect(!b.isFinished)
        }
    }

    /// The negative controls: nothing from another session, nor after the end cleared the cache.
    @Test func playbackProgressIsDroppedForAnotherSessionOrAfterTheEnd() async throws {
        try await withLibrarySettings { settings in
            let harness = Harness(settings: settings)
            await harness.participant.sessionDidStart(harness.context(client: nil, isOffline: true, sessionID: 7))

            #expect(!harness.participant.applyPlaybackProgress(playback("a", at: 40), sessionID: 6))
            #expect(harness.cached.isEmpty)

            await harness.participant.sessionWillEnd(.signOut)
            #expect(!harness.participant.applyPlaybackProgress(playback("a", at: 40), sessionID: 7))
            #expect(harness.cached.isEmpty)
        }
    }
}

/// Playback of `itemID` on account A at `time`, two seconds after the epoch.
private func playback(_ itemID: String, at time: Double, duration: Double = 100) -> PlaybackProgressUpdate {
    PlaybackProgressUpdate(
        key: MediaKey(serverConnectionID: identityA.connectionID, libraryItemId: itemID), currentTime: time,
        duration: duration, date: Date(timeIntervalSince1970: 2))
}
