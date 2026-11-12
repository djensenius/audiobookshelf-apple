import ABSAPI
import ABSCore
import ABSData
import Foundation
import Observation
import Testing

@testable import ABSAppModel

/// Records what the participant gives the pipeline.
@MainActor
private final class FakeBuilderSink: ImageRequestBuilderSink {
    enum Event: Equatable {
        case set(UUID, URLRequest?)
        case cleared(UUID)
        case removed(UUID)
    }

    private(set) var events: [Event] = []

    func setRequestBuilder(_ builder: (any ImageRequestBuilding)?, for serverID: UUID) async {
        if let builder {
            events.append(.set(serverID, builder.imageRequest(for: Self.cover)))
        } else {
            events.append(.cleared(serverID))
        }
    }

    func removeServer(_ serverID: UUID) async {
        events.append(.removed(serverID))
    }

    /// The request the latest builder makes for ``cover``.
    var latestRequest: URLRequest? {
        for event in events.reversed() {
            if case .set(_, let request) = event { return request }
        }
        return nil
    }

    var removals: [UUID] {
        events.compactMap { if case .removed(let id) = $0 { id } else { nil } }
    }

    static let cover = ImageSource.server(kind: .itemCover, entityID: "li_1", updatedAt: nil, width: .small)
}

/// Stands in for `AccountManager`'s observable connections.
@MainActor @Observable
private final class FakeConnections {
    var active: ServerConnectionDTO?
    var saved: Set<UUID> = []
}

private func connection(_ identity: SessionIdentity, usedAt: Date = .distantPast) -> ServerConnectionDTO {
    ServerConnectionDTO(
        id: identity.connectionID, address: "https://abs.example", userId: identity.userID, username: "user",
        authMethod: .local, createdAt: .distantPast, lastUsedAt: usedAt)
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

@MainActor
@Suite struct ImageParticipantTests {
    private let sink = FakeBuilderSink()
    private let connections = FakeConnections()

    private func makeParticipant() -> ImageParticipant {
        let connections = self.connections
        return ImageParticipant(sink: sink, activeConnection: { connections.active })
    }

    @Test func startSetsTheBuilderFromTheClientsConfiguration() async throws {
        let participant = makeParticipant()

        await participant.sessionDidStart(
            context(identityA, client: try client("https://abs.example", headers: ["X-Proxy": "1"])))

        let request = try #require(sink.latestRequest)
        #expect(request.url?.host() == "abs.example")
        #expect(request.value(forHTTPHeaderField: "X-Proxy") == "1")
        #expect(sink.events.count == 1)
        guard case .set(let serverID, _) = sink.events.first else { return }
        #expect(serverID == identityA.connectionID)
    }

    @Test(arguments: [SessionEndReason.signOut, .switch, .removed, .expired])
    func endClearsTheBuilderWithoutRemovingTheServer(reason: SessionEndReason) async throws {
        let participant = makeParticipant()
        await participant.sessionDidStart(context(identityA, client: try client("https://abs.example")))

        await participant.sessionWillEnd(reason)

        #expect(sink.events.last == .cleared(identityA.connectionID))
        #expect(sink.removals.isEmpty)
        #expect(participant.observation == nil)
    }

    @Test func endWithoutAStartDoesNothing() async {
        let participant = makeParticipant()

        await participant.sessionWillEnd(.signOut)

        #expect(sink.events.isEmpty)
    }

    @Test func removeRemovesTheServer() async {
        let participant = makeParticipant()

        await participant.remove(identityB.connectionID)

        #expect(sink.events == [.removed(identityB.connectionID)])
    }

    @Test func aChangedConnectionRebuildsTheBuilderWithItsNewHeaders() async throws {
        connections.active = connection(identityA)
        let participant = makeParticipant()
        let client = try client("https://abs.example", headers: ["X-Proxy": "1"])
        await participant.sessionDidStart(context(identityA, client: client))

        try await client.setCustomHeaders(["X-Proxy": "2"])
        connections.active = connection(identityA, usedAt: .now)

        #expect(await eventually { sink.latestRequest?.value(forHTTPHeaderField: "X-Proxy") == "2" })
    }

    @Test func anotherConnectionDoesntRebuildTheBuilder() async throws {
        connections.active = connection(identityA)
        let participant = makeParticipant()
        await participant.sessionDidStart(context(identityA, client: try client("https://abs.example")))

        // Switching, before the lifecycle ends this session.
        connections.active = connection(identityB)
        for _ in 0..<100 { await Task.yield() }

        #expect(sink.events.count == 1)
    }

    @Test func aReconnectUsesTheNewClientsConfiguration() async throws {
        let participant = makeParticipant()
        await participant.sessionDidStart(context(identityA, client: nil, isOffline: true))
        #expect(sink.events == [.cleared(identityA.connectionID)])

        await participant.sessionDidReconnect(
            context(identityA, client: try client("https://new.example", headers: ["X-Proxy": "new"])))

        let request = try #require(sink.latestRequest)
        #expect(request.url?.host() == "new.example")
        #expect(request.value(forHTTPHeaderField: "X-Proxy") == "new")
    }

    @Test func nothingIsRebuiltAfterTheEnd() async throws {
        connections.active = connection(identityA)
        let participant = makeParticipant()
        let client = try client("https://abs.example")
        await participant.sessionDidStart(context(identityA, client: client))
        await participant.sessionWillEnd(.signOut)
        let ended = sink.events

        try await client.setCustomHeaders(["X-Proxy": "2"])
        connections.active = connection(identityA, usedAt: .now)
        await participant.sessionDidReconnect(context(identityA, client: client))
        for _ in 0..<100 { await Task.yield() }

        #expect(sink.events == ended)
        #expect(sink.events.last == .cleared(identityA.connectionID))
    }

    @Test func aRebuildInFlightLandsBeforeTheEndClearsIt() async throws {
        connections.active = connection(identityA)
        let participant = makeParticipant()
        await participant.sessionDidStart(context(identityA, client: try client("https://abs.example")))

        // The change's rebuild is queued, and the end clears after it whatever the order.
        connections.active = connection(identityA, usedAt: .now)
        await participant.sessionWillEnd(.switch)
        for _ in 0..<100 { await Task.yield() }

        #expect(sink.events.last == .cleared(identityA.connectionID))
    }

    @Test func followsRemovedConnectionsButNotSignedOutOnes() async {
        connections.saved = [identityA.connectionID, identityB.connectionID]
        let participant = makeParticipant()
        let connections = self.connections
        participant.followRemovals { connections.saved }

        connections.saved = [identityA.connectionID]

        #expect(await eventually { sink.removals == [identityB.connectionID] })
        // A sign-out keeps the connection listed.
        connections.saved = [identityA.connectionID]
        for _ in 0..<100 { await Task.yield() }
        #expect(sink.removals == [identityB.connectionID])
    }
}
