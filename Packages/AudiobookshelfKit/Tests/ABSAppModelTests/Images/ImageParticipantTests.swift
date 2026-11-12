import ABSAPI
import ABSCore
import Foundation
import Observation
import Testing

@testable import ABSAppModel

/// Records what the participant gives the pipeline, in the order the pipeline applies it. Calls
/// of the kinds in ``holding`` wait inside the pipeline until ``release()``.
@MainActor
private final class FakeBuilderSink: ImageRequestBuilderSink {
    enum Event: Equatable {
        case set(UUID, URLRequest?)
        case cleared(UUID)
        case removed(UUID)
        case swept(keeping: Set<UUID>)
    }

    enum Call: Hashable {
        case set, clear, remove
    }

    private(set) var events: [Event] = []
    var holding: Set<Call> = []
    /// The servers with cached covers, for a sweep.
    var cachedServers: Set<UUID> = []
    /// The servers given a builder, as the pipeline tracks them: a sweep keeps them.
    private var sessionServers: Set<UUID> = []
    private var held: [CheckedContinuation<Void, Never>] = []

    var heldCount: Int { held.count }

    /// Lets the held calls through, and stops holding.
    func release() {
        holding = []
        let waiting = held
        held = []
        for call in waiting { call.resume() }
    }

    func setRequestBuilder(_ builder: (any ImageRequestBuilding)?, for serverID: UUID) async {
        sessionServers.insert(serverID)
        if let builder {
            await hold(.set)
            events.append(.set(serverID, builder.imageRequest(for: Self.cover)))
        } else {
            await hold(.clear)
            events.append(.cleared(serverID))
        }
    }

    func removeServer(_ serverID: UUID) async {
        await hold(.remove)
        events.append(.removed(serverID))
    }

    func serversToSweep(keepingOnly saved: Set<UUID>) async -> Set<UUID> {
        events.append(.swept(keeping: saved))
        return cachedServers.subtracting(saved)
    }

    func removeServerUnlessInSession(_ serverID: UUID) async -> Bool {
        await hold(.remove)
        guard !sessionServers.contains(serverID) else { return false }
        events.append(.removed(serverID))
        return true
    }

    private func hold(_ call: Call) async {
        guard holding.contains(call) else { return }
        await withCheckedContinuation { held.append($0) }
    }

    /// The request the latest builder makes for ``cover``.
    var latestRequest: URLRequest? {
        for event in events.reversed() {
            if case .set(_, let request) = event { return request }
        }
        return nil
    }

    func didSet(_ identity: SessionIdentity) -> Bool {
        events.contains { if case .set(identity.connectionID, _) = $0 { true } else { false } }
    }

    var removals: [UUID] {
        events.compactMap { if case .removed(let id) = $0 { id } else { nil } }
    }

    static let cover = ImageSource.server(kind: .itemCover, entityID: "li_1", updatedAt: nil, width: .small)
}

/// Stands in for `AccountManager`'s observable saved connections.
@MainActor @Observable
private final class FakeConnections {
    var saved: Set<UUID> = []
}

private func client(_ address: String, headers: [String: String] = [:]) throws -> APIClient {
    APIClient(
        configuration: try APIClientConfiguration(baseURL: URL(string: address)!, customHeaders: headers),
        tokenProvider: ImageTestTokens())
}

private struct ImageTestTokens: TokenProvider {
    func tokens() async -> AuthTokens? { nil }
    func replaceTokens(expected: AuthTokens, with new: AuthTokens) async -> Bool { false }
    func expireSession(ifCurrent rejected: AuthTokens) async -> Bool { false }
}

private func context(_ identity: SessionIdentity, client: APIClient?, isOffline: Bool = false) -> SessionContext {
    SessionContext(identity: identity, client: client, isOffline: isOffline, sessionID: 1)
}

/// Lets queued tasks run, so a call that isn't ordered behind a held one reaches the sink.
@MainActor
private func settle() async {
    for _ in 0..<100 { await Task.yield() }
}

@MainActor
@Suite struct ImageParticipantTests {
    private let sink = FakeBuilderSink()

    @Test func startSetsTheBuilderFromTheClientsConfiguration() async throws {
        let participant = ImageParticipant(sink: sink)

        await participant.sessionDidStart(
            context(identityA, client: try client("https://abs.example", headers: ["X-Proxy": "1"])))

        let request = try #require(sink.latestRequest)
        #expect(request.url?.host() == "abs.example")
        #expect(request.value(forHTTPHeaderField: "X-Proxy") == "1")
        #expect(sink.events.count == 1)
        #expect(sink.didSet(identityA))
    }

    @Test(arguments: [SessionEndReason.signOut, .switch, .removed, .expired])
    func endClearsTheBuilderWithoutRemovingTheServer(reason: SessionEndReason) async throws {
        let participant = ImageParticipant(sink: sink)
        await participant.sessionDidStart(context(identityA, client: try client("https://abs.example")))

        await participant.sessionWillEnd(reason)

        #expect(sink.events.last == .cleared(identityA.connectionID))
        #expect(sink.removals.isEmpty)
    }

    @Test func endWithoutAStartDoesNothing() async {
        let participant = ImageParticipant(sink: sink)

        await participant.sessionWillEnd(.signOut)

        #expect(sink.events.isEmpty)
    }

    @Test func removeRemovesTheServer() async {
        let participant = ImageParticipant(sink: sink)

        await participant.remove(identityB.connectionID)

        #expect(sink.events == [.removed(identityB.connectionID)])
    }

    @Test func aReconnectUsesTheNewClientsConfiguration() async throws {
        let participant = ImageParticipant(sink: sink)
        await participant.sessionDidStart(context(identityA, client: nil, isOffline: true))
        #expect(sink.events == [.cleared(identityA.connectionID)])

        await participant.sessionDidReconnect(
            context(identityA, client: try client("https://new.example", headers: ["X-Proxy": "new"])))

        let request = try #require(sink.latestRequest)
        #expect(request.url?.host() == "new.example")
        #expect(request.value(forHTTPHeaderField: "X-Proxy") == "new")
    }

    @Test func aReconnectAfterTheEndInstallsNothing() async throws {
        let participant = ImageParticipant(sink: sink)
        let client = try client("https://abs.example")
        await participant.sessionDidStart(context(identityA, client: client))
        await participant.sessionWillEnd(.signOut)
        let ended = sink.events

        await participant.sessionDidReconnect(context(identityA, client: client))
        await settle()

        #expect(sink.events == ended)
    }

    // MARK: - Ordering

    @Test func anInstallStillInThePipelineLandsBeforeTheEndsClear() async throws {
        let participant = ImageParticipant(sink: sink)
        sink.holding = [.set]
        let start = Task {
            await participant.sessionDidStart(context(identityA, client: try? client("https://abs.example")))
        }
        #expect(await eventually { sink.heldCount == 1 })

        // The install passed its session check before the end, so only the order keeps it first.
        let end = Task { await participant.sessionWillEnd(.signOut) }
        await settle()
        #expect(sink.events.isEmpty)
        sink.release()
        await start.value
        await end.value

        #expect(sink.events.count == 2)
        #expect(sink.events.last == .cleared(identityA.connectionID))
    }

    @Test func anEndTheLifecycleStoppedWaitingForLandsBeforeTheConnectionsNextBuilder() async throws {
        let participant = ImageParticipant(sink: sink)
        await participant.sessionDidStart(context(identityA, client: try client("https://abs.example")))
        sink.holding = [.clear]
        // The lifecycle gives up on the end and signs in to the same connection again.
        let end = Task { await participant.sessionWillEnd(.switch) }
        #expect(await eventually { sink.heldCount == 1 })
        let restart = Task {
            await participant.sessionDidStart(context(identityA, client: try? client("https://abs.example")))
        }
        await settle()
        #expect(sink.events.count == 1)

        sink.release()
        await end.value
        await restart.value

        #expect(sink.events.count == 3)
        #expect(sink.events[1] == .cleared(identityA.connectionID))
        guard case .set(identityA.connectionID, _) = sink.events.last else {
            Issue.record("Expected A's new builder last, got \(sink.events)")
            return
        }
    }

    @Test func anotherConnectionsStartDoesntWaitForAnEnd() async throws {
        let participant = ImageParticipant(sink: sink)
        await participant.sessionDidStart(context(identityA, client: try client("https://abs.example")))
        sink.holding = [.clear]
        let end = Task { await participant.sessionWillEnd(.switch) }
        #expect(await eventually { sink.heldCount == 1 })

        // Builders are per connection, so B's needn't wait for A's to go.
        let start = Task {
            await participant.sessionDidStart(context(identityB, client: try? client("https://b.example")))
        }
        #expect(await eventually { sink.didSet(identityB) })

        sink.release()
        await end.value
        await start.value
        #expect(sink.events.last == .cleared(identityA.connectionID))
    }

    @Test func aRemovedServersCoverDeletionDoesntHoldUpAnotherConnectionsStart() async throws {
        let participant = ImageParticipant(sink: sink)
        sink.holding = [.remove]
        let removal = Task { await participant.remove(identityB.connectionID) }
        #expect(await eventually { sink.heldCount == 1 })

        let start = Task {
            await participant.sessionDidStart(context(identityA, client: try? client("https://abs.example")))
        }
        #expect(await eventually { sink.didSet(identityA) })

        sink.release()
        await removal.value
        await start.value
        #expect(sink.removals == [identityB.connectionID])
    }

    // MARK: - Removal

    @Test func followsRemovedConnectionsButNotSignedOutOnes() async {
        let connections = FakeConnections()
        connections.saved = [identityA.connectionID, identityB.connectionID]
        let participant = ImageParticipant(sink: sink)
        participant.followRemovals { connections.saved }

        connections.saved = [identityA.connectionID]

        #expect(await eventually { sink.removals == [identityB.connectionID] })
        // A sign-out keeps the connection listed.
        connections.saved = [identityA.connectionID]
        await settle()
        #expect(sink.removals == [identityB.connectionID])
    }

    // MARK: - Sweep (#421)

    @Test func sweepKeepsTheSavedConnectionsOncePerLaunch() async {
        let participant = ImageParticipant(sink: sink)
        let saved: Set = [identityA.connectionID]

        await participant.sweepRemovedConnections { saved }
        await participant.sweepRemovedConnections { [] }

        #expect(sink.events == [.swept(keeping: saved)])
    }

    @Test func sweepRemovesUnsavedServersButNotOnesWithASession() async throws {
        let participant = ImageParticipant(sink: sink)
        let removed = UUID()
        sink.cachedServers = [identityA.connectionID, identityB.connectionID, removed]
        // B signed in before the sweep but after the saved connections were read.
        await participant.sessionDidStart(context(identityB, client: try client("https://b.example")))

        await participant.sweepRemovedConnections { [identityA.connectionID] }

        #expect(sink.removals == [removed])
    }

    /// A session started for a server while the sweep removes it (a disconnected connection
    /// signed in again) installs its builder only after the removal, lease wait included, so it
    /// can't cache covers the removal then deletes.
    @Test func aSessionStartedDuringASweptRemovalWaitsForIt() async throws {
        let participant = ImageParticipant(sink: sink)
        sink.cachedServers = [identityA.connectionID]
        sink.holding = [.remove]
        let sweep = Task { await participant.sweepRemovedConnections { [] } }
        #expect(await eventually { sink.heldCount == 1 })

        let start = Task {
            await participant.sessionDidStart(context(identityA, client: try? client("https://abs.example")))
        }
        await settle()
        #expect(!sink.didSet(identityA))

        sink.release()
        await sweep.value
        await start.value
        #expect(sink.removals == [identityA.connectionID])
        guard case .set(identityA.connectionID, _) = sink.events.last else {
            Issue.record("Expected A's builder after its removal, got \(sink.events)")
            return
        }
    }

    @Test func sweepDeletesNothingWhenTheStoreCantBeRead() async {
        let participant = ImageParticipant(sink: sink)

        await participant.sweepRemovedConnections { nil }

        #expect(sink.events.isEmpty)
        // A later launch's read that works still sweeps.
        await participant.sweepRemovedConnections { [identityA.connectionID] }
        #expect(sink.events == [.swept(keeping: [identityA.connectionID])])
    }
}
