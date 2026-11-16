import ABSAPI
import ABSCore
import ABSRealtime
import Foundation
import Testing

private enum RealtimeContractError: Error, Sendable {
    case missingAccessToken
    case timeout
    case wrongIdentity(expected: String, actual: String)
    case unexpectedProgressEvent
}

/// One production Socket.IO client connected to the disposable contract server.
private actor RealtimeContractListener {
    private let client: SocketClient
    private let events: AsyncStream<RealtimeEvent>

    init(session: ContractSession) throws {
        guard let token = session.tokens.current?.accessToken else {
            throw RealtimeContractError.missingAccessToken
        }
        let client = try SocketClient(
            configuration: RealtimeConfiguration(
                serverAddress: session.configuration.baseURL,
                token: token,
                customHeaders: session.configuration.customHeaders))
        self.client = client
        events = client.events
    }

    func connect(as expectedUserID: String) async throws {
        await client.connect()
        let event = try await next(matching: {
            if case .initialized = $0 { return true }
            return false
        })
        guard case .initialized(let session) = event else { throw RealtimeContractError.timeout }
        guard session.userId == expectedUserID else {
            throw RealtimeContractError.wrongIdentity(expected: expectedUserID, actual: session.userId)
        }
    }

    func next(matching predicate: @escaping @Sendable (RealtimeEvent) -> Bool) async throws -> RealtimeEvent {
        guard let event = await waitForMatching(predicate, timeout: .seconds(15)) else {
            throw RealtimeContractError.timeout
        }
        return event
    }

    func assertNoProgressEvent(for duration: Duration) async throws {
        let event = await waitForMatching(
            {
                if case .userItemProgressUpdated = $0 { return true }
                return false
            }, timeout: duration)
        if event != nil {
            throw RealtimeContractError.unexpectedProgressEvent
        }
    }

    func disconnect() async {
        await client.disconnect(sendingFarewell: false)
    }

    private func waitForMatching(
        _ predicate: @escaping @Sendable (RealtimeEvent) -> Bool, timeout: Duration
    ) async -> RealtimeEvent? {
        let events = events
        return await withTaskGroup(of: RealtimeEvent?.self) { group in
            group.addTask {
                for await event in events where predicate(event) {
                    return event
                }
                return nil
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return nil
            }
            let event = await group.next() ?? nil
            group.cancelAll()
            return event
        }
    }
}

@Suite("Server contract: Socket.IO events", .requiresServer, .tags(.serverContract), .timeLimit(.minutes(2)))
struct RealtimeContractTests {
    @Test("progress updates reach their owner but not another user")
    func progressEventsAreScopedToTheOwningUser() async throws {
        let server = try ContractServer.require()
        let seed = try await ContractSeed.shared.data()
        try await server.withUser { owner in
            try await server.withUser { other in
                let ownerSocket = try RealtimeContractListener(session: owner)
                let otherSocket = try RealtimeContractListener(session: other)
                do {
                    try await ownerSocket.connect(as: owner.user.id)
                    try await otherSocket.connect(as: other.user.id)

                    let playback = try await owner.play(seed.taleID)
                    try await owner.sync(playback, to: 12, listened: 2)
                    let event = try await ownerSocket.next(matching: {
                        guard case .userItemProgressUpdated(let update) = $0 else { return false }
                        return update.progress.libraryItemId == seed.taleID && update.progress.currentTime == 12
                    })
                    guard case .userItemProgressUpdated(let update) = event else {
                        throw RealtimeContractError.timeout
                    }
                    #expect(update.progress.userId == owner.user.id)
                    #expect(update.progress.progress == 0.24)

                    #expect(try await owner.progress(seed.taleID) == update.progress)
                    try await otherSocket.assertNoProgressEvent(for: .seconds(2))
                } catch {
                    await ownerSocket.disconnect()
                    await otherSocket.disconnect()
                    throw error
                }
                await ownerSocket.disconnect()
                await otherSocket.disconnect()
            }
        }
    }

    @Test("RSS feed open and close events reach every authenticated user")
    func rssFeedEventsAreBroadcastAndMatchTheFeed() async throws {
        try await CollectionContractFixture.withFixture { fixture in
            let admin = fixture.admin
            let user = try await fixture.user(elevated: false)
            let adminSocket = try RealtimeContractListener(session: admin)
            let userSocket = try RealtimeContractListener(session: user)
            var openedID: String?
            do {
                try await adminSocket.connect(as: admin.user.id)
                try await userSocket.connect(as: user.user.id)

                let collection = try await fixture.create(as: admin, books: [fixture.seed.taleID])
                let target = RssFeedTarget(.collection, id: collection.id)
                let slug = "contract-" + UUID().uuidString.prefix(8).lowercased()
                let request = RssFeedOpenRequest(
                    serverAddress: admin.server.configuration.baseURL.absoluteString,
                    slug: slug,
                    metadataDetails: .init(preventIndexing: false, ownerName: "Ada", ownerEmail: "ada@example.com"))
                let opened = try await admin.client.send(FeedEndpoints.open(target, request)).feed
                openedID = opened.id

                let adminOpen = try await Self.feedEvent(adminSocket, id: opened.id, opened: true)
                let userOpen = try await Self.feedEvent(userSocket, id: opened.id, opened: true)
                #expect(adminOpen.feedUrl == opened.feedUrl)
                #expect(userOpen.feedUrl == opened.feedUrl)
                #expect(adminOpen.entityId == collection.id)
                #expect(userOpen.entityId == collection.id)

                _ = try await admin.client.send(FeedEndpoints.close(id: opened.id))
                _ = try await Self.feedEvent(adminSocket, id: opened.id, opened: false)
                _ = try await Self.feedEvent(userSocket, id: opened.id, opened: false)
                openedID = nil
            } catch {
                if let openedID {
                    _ = try? await admin.client.send(FeedEndpoints.close(id: openedID))
                }
                await adminSocket.disconnect()
                await userSocket.disconnect()
                throw error
            }
            await adminSocket.disconnect()
            await userSocket.disconnect()
        }
    }

    private static func feedEvent(
        _ listener: RealtimeContractListener, id: String, opened: Bool
    ) async throws -> RssFeed {
        let event = try await listener.next(matching: {
            guard case .rssFeedChanged(let change) = $0 else { return false }
            return change.feed.id == id
        })
        guard case .rssFeedChanged(let change) = event else { throw RealtimeContractError.timeout }
        switch change {
        case .opened(let feed) where opened, .closed(let feed) where !opened:
            return feed
        default:
            throw RealtimeContractError.timeout
        }
    }
}
