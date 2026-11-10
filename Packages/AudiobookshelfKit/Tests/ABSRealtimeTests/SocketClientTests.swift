import ABSRealtime
import Foundation
import Testing

private let openPacket =
    #"0{"sid":"eio-1","upgrades":[],"pingInterval":25000,"pingTimeout":20000,"maxPayload":1000000}"#
private let initPacket = #"42["init",{"userId":"usr-1","username":"david"}]"#

/// Drives a ``SocketClient`` through a fake transport and a manual clock.
private struct Harness {
    let clock = ManualClock()
    let transport = FakeTransport()
    let client: SocketClient
    private var connections: AsyncStream<FakeConnection>.Iterator
    private var events: AsyncStream<RealtimeEvent>.Iterator

    init(token: String? = "tok", headers: [String: String] = [:]) throws {
        let configuration = RealtimeConfiguration(
            serverAddress: try #require(URL(string: "https://abs.example.com/abs")),
            token: token,
            customHeaders: headers
        )
        client = try SocketClient(configuration: configuration, transport: transport, clock: clock) { 0.5 }
        connections = transport.connections.makeAsyncIterator()
        events = client.events.makeAsyncIterator()
    }

    mutating func nextConnection() async throws -> FakeConnection {
        try #require(await connections.next())
    }

    mutating func nextEvent() async -> RealtimeEvent? {
        await events.next()
    }

    /// Plays the server side of the open, connect and auth exchange. Returns the client's frames.
    mutating func handshake(
        _ connection: FakeConnection, expectedToken: String = "tok"
    ) async -> AsyncStream<String>.Iterator {
        var sent = connection.sent.makeAsyncIterator()
        connection.push(openPacket)
        #expect(await sent.next() == "40")
        connection.push(#"40{"sid":"sio-1"}"#)
        #expect(await nextEvent() == .connected)
        #expect(await sent.next() == #"42["auth","\#(expectedToken)"]"#)
        connection.push(initPacket)
        #expect(await nextEvent() == .initialized(RealtimeSession(userId: "usr-1", username: "david")))
        return sent
    }
}

@Suite(.timeLimit(.minutes(1)))
struct SocketClientTests {
    @Test func connectsWithFilteredHeadersAndAuthenticates() async throws {
        var harness = try Harness(headers: ["Authorization": "Bearer x", "cookie": "a=b", "CF-Access-Client-Id": "id"])
        await harness.client.connect()
        let connection = try await harness.nextConnection()

        let request = try #require(harness.transport.requests.first)
        #expect(request.url.absoluteString == "wss://abs.example.com/abs/socket.io/?EIO=4&transport=websocket")
        #expect(request.headers == ["CF-Access-Client-Id": "id"])

        _ = await harness.handshake(connection)
        #expect(!connection.isClosed)
    }

    @Test func answersPingsWithPongs() async throws {
        var harness = try Harness()
        await harness.client.connect()
        let connection = try await harness.nextConnection()
        var sent = await harness.handshake(connection)

        connection.push("2")
        #expect(await sent.next() == "3")
        connection.push("2")
        #expect(await sent.next() == "3")
    }

    @Test func reconnectsWhenNoPacketArrivesWithinPingIntervalPlusTimeout() async throws {
        var harness = try Harness()
        let clock = harness.clock
        await harness.client.connect()
        let connection = try await harness.nextConnection()
        var sent = await harness.handshake(connection)
        await clock.waitUntilPending([.seconds(45)])

        // A ping restarts the liveness timer.
        clock.advance(by: .seconds(30))
        connection.push("2")
        #expect(await sent.next() == "3")
        await clock.waitUntilPending([.seconds(45)])
        clock.advance(by: .seconds(44))
        #expect(!connection.isClosed)

        clock.advance(by: .seconds(1))
        #expect(await harness.nextEvent() == .disconnected(.pingTimeout))
        #expect(connection.isClosed)

        await clock.waitUntilPending([.seconds(1)])
        clock.advance(by: .seconds(1))
        let reconnected = try await harness.nextConnection()
        _ = await harness.handshake(reconnected)
    }

    @Test func reconnectsWhenTheOpenPacketNeverArrives() async throws {
        var harness = try Harness()
        let clock = harness.clock
        await harness.client.connect()
        let connection = try await harness.nextConnection()

        await clock.waitUntilPending([.seconds(20)])
        clock.advance(by: .seconds(20))
        await clock.waitUntilPending([.seconds(1)])
        #expect(connection.isClosed)
        clock.advance(by: .seconds(1))
        _ = try await harness.nextConnection()
    }

    @Test func backsOffAfterTransportFailuresAndResetsOnConnect() async throws {
        var harness = try Harness()
        let clock = harness.clock
        await harness.client.connect()
        let first = try await harness.nextConnection()
        _ = await harness.handshake(first)

        first.fail()
        #expect(await harness.nextEvent() == .disconnected(.transportClosed))
        await clock.waitUntilPending([.seconds(1)])
        clock.advance(by: .seconds(1))

        let second = try await harness.nextConnection()
        second.fail()
        await clock.waitUntilPending([.seconds(2)])
        clock.advance(by: .seconds(2))

        let third = try await harness.nextConnection()
        _ = await harness.handshake(third)
        third.fail()
        #expect(await harness.nextEvent() == .disconnected(.transportClosed))
        await clock.waitUntilPending([.seconds(1)])
    }

    @Test func reconnectsAfterAConnectError() async throws {
        var harness = try Harness()
        let clock = harness.clock
        await harness.client.connect()
        let connection = try await harness.nextConnection()
        var sent = connection.sent.makeAsyncIterator()
        connection.push(openPacket)
        #expect(await sent.next() == "40")

        connection.push(#"44{"message":"Not authorized"}"#)
        await clock.waitUntilPending([.seconds(1)])
        #expect(connection.isClosed)
    }

    @Test func authFailedStopsReconnectingUntilTheTokenIsUpdated() async throws {
        var harness = try Harness()
        let clock = harness.clock
        await harness.client.connect()
        let connection = try await harness.nextConnection()
        var sent = connection.sent.makeAsyncIterator()
        connection.push(openPacket)
        #expect(await sent.next() == "40")
        connection.push(#"40{"sid":"sio-1"}"#)
        #expect(await harness.nextEvent() == .connected)
        #expect(await sent.next() == #"42["auth","tok"]"#)

        connection.push(#"42["auth_failed",{"message":"Token expired"}]"#)
        #expect(await harness.nextEvent() == .authFailed(message: "Token expired"))
        #expect(await harness.nextEvent() == .disconnected(.authFailed))
        #expect(connection.isClosed)

        await harness.client.networkChanged()
        clock.advance(by: .seconds(60))
        #expect(clock.pendingDelays.isEmpty)
        #expect(harness.transport.requests.count == 1)

        await harness.client.updateToken("fresh")
        let reconnected = try await harness.nextConnection()
        _ = await harness.handshake(reconnected, expectedToken: "fresh")
    }

    @Test func connectResumesAfterAuthFailed() async throws {
        var harness = try Harness()
        await harness.client.connect()
        let connection = try await harness.nextConnection()
        _ = await harness.handshake(connection)
        connection.push(#"42["auth_failed",{"message":"Invalid user"}]"#)
        #expect(await harness.nextEvent() == .authFailed(message: "Invalid user"))
        #expect(await harness.nextEvent() == .disconnected(.authFailed))

        await harness.client.connect()
        _ = await harness.handshake(try await harness.nextConnection())
    }

    @Test func networkChangeReconnectsImmediatelyAndResetsBackoff() async throws {
        var harness = try Harness()
        let clock = harness.clock
        await harness.client.connect()
        let first = try await harness.nextConnection()
        _ = await harness.handshake(first)

        first.fail()
        await clock.waitUntilPending([.seconds(1)])
        clock.advance(by: .seconds(1))
        let second = try await harness.nextConnection()
        second.fail()
        await clock.waitUntilPending([.seconds(2)])

        await harness.client.networkChanged()
        let third = try await harness.nextConnection()
        await clock.waitUntilPending([.seconds(20)])
        third.fail()
        await clock.waitUntilPending([.seconds(1)])
    }

    @Test func networkChangeWhileConnectedReplacesTheConnection() async throws {
        var harness = try Harness()
        await harness.client.connect()
        let first = try await harness.nextConnection()
        _ = await harness.handshake(first)

        await harness.client.networkChanged()
        #expect(await harness.nextEvent() == .disconnected(.networkChanged))
        #expect(first.isClosed)
        _ = await harness.handshake(try await harness.nextConnection())
    }

    @Test func updateTokenReconnectsWithTheNewToken() async throws {
        var harness = try Harness()
        await harness.client.connect()
        let first = try await harness.nextConnection()
        _ = await harness.handshake(first)

        await harness.client.updateToken("rotated")
        #expect(await harness.nextEvent() == .disconnected(.tokenUpdated))
        #expect(first.isClosed)
        _ = await harness.handshake(try await harness.nextConnection(), expectedToken: "rotated")
    }

    @Test func updateTokenWhileIdleOnlyStoresTheToken() async throws {
        var harness = try Harness()
        await harness.client.updateToken("later")
        await harness.client.networkChanged()
        #expect(harness.transport.requests.isEmpty)

        await harness.client.connect()
        _ = await harness.handshake(try await harness.nextConnection(), expectedToken: "later")
    }

    @Test func decodesEventsAndDropsMalformedOnes() async throws {
        var harness = try Harness()
        await harness.client.connect()
        let connection = try await harness.nextConnection()
        _ = await harness.handshake(connection)

        connection.push("x")
        connection.push(#"42["user_updated",{"id":"usr-1"}]"#)
        connection.push(#"42["item_updated",{"id":"li-1"}]"#)
        connection.push(#"42["user_updated",\#(RealtimeFixtures.user)]"#)
        connection.push(#"42["user_item_progress_updated",\#(RealtimeFixtures.progressUpdate)]"#)
        connection.push(#"42["playlist_added",\#(RealtimeFixtures.playlist)]"#)

        guard case .userUpdated(let user) = await harness.nextEvent() else {
            Issue.record("Expected userUpdated")
            return
        }
        #expect(user.username == "david")
        guard case .userItemProgressUpdated(let update) = await harness.nextEvent() else {
            Issue.record("Expected userItemProgressUpdated")
            return
        }
        #expect(update.progress.id == "mp-1")
        guard case .playlistAdded(let playlist) = await harness.nextEvent() else {
            Issue.record("Expected playlistAdded")
            return
        }
        #expect(playlist.name == "Road trip")
        #expect(!connection.isClosed)
    }

    @Test func disconnectSendsDisconnectPacketAndStopsReconnecting() async throws {
        var harness = try Harness()
        let clock = harness.clock
        await harness.client.connect()
        let connection = try await harness.nextConnection()
        var sent = await harness.handshake(connection)

        await harness.client.disconnect()
        #expect(await sent.next() == "41")
        #expect(await harness.nextEvent() == .disconnected(.clientRequested))
        #expect(connection.isClosed)

        await harness.client.networkChanged()
        #expect(clock.pendingDelays.isEmpty)
        #expect(harness.transport.requests.count == 1)
    }
}
