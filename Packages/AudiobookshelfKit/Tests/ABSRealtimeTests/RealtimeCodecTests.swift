import Foundation
import Testing

@testable import ABSRealtime

/// Wire examples from the Engine.IO v4 and Socket.IO v4 protocol READMEs.
@Suite struct RealtimeCodecTests {
    @Test func decodesOpenPacket() throws {
        let packet = try EngineIOPacket(
            decoding:
                #"0{"sid":"lv_VI97HAXpY6yYWAAAC","upgrades":[],"pingInterval":25000,"pingTimeout":20000,"maxPayload":1000000}"#
        )
        let handshake = EngineIOHandshake(
            sid: "lv_VI97HAXpY6yYWAAAC", pingInterval: 25000, pingTimeout: 20000, maxPayload: 1_000_000
        )
        #expect(packet == .open(handshake))
        #expect(handshake.livenessTimeout == .seconds(45))
    }

    @Test func rejectsOpenPacketWithoutPingSettings() {
        #expect(throws: RealtimeCodecError.invalidPayload) {
            try EngineIOPacket(decoding: #"0{"sid":"abc"}"#)
        }
    }

    @Test(arguments: [
        ("1", EngineIOPacket.close),
        ("2", .ping("")),
        ("3", .pong("")),
        ("2probe", .ping("probe")),
        ("3probe", .pong("probe")),
        ("4hello", .message("hello")),
        ("5", .upgrade),
        ("6", .noop),
    ])
    func roundTripsEngineIOPackets(wire: String, packet: EngineIOPacket) throws {
        #expect(try EngineIOPacket(decoding: wire) == packet)
        #expect(packet.encoded == wire)
    }

    @Test func rejectsEmptyAndUnknownEngineIOPackets() {
        #expect(throws: RealtimeCodecError.emptyPacket) { try EngineIOPacket(decoding: "") }
        #expect(throws: RealtimeCodecError.unknownPacketType("9")) { try EngineIOPacket(decoding: "9") }
    }

    @Test func encodesConnectToMainNamespace() {
        #expect(EngineIOPacket.message(SocketIOPacket.connect().encoded).encoded == "40")
        #expect(SocketIOPacket.connect(namespace: "/admin").encoded == "0/admin,")
    }

    @Test func decodesConnectAcknowledgement() throws {
        let packet = try SocketIOPacket(decoding: #"0{"sid":"wZX3oN0bSVIhsaknAAAI"}"#)
        #expect(packet == .connect(payload: Data(#"{"sid":"wZX3oN0bSVIhsaknAAAI"}"#.utf8)))
        #expect(packet.encoded == #"0{"sid":"wZX3oN0bSVIhsaknAAAI"}"#)
        #expect(try SocketIOPacket(decoding: "0") == .connect())
    }

    @Test func decodesConnectError() throws {
        let packet = try SocketIOPacket(decoding: #"4{"message":"Not authorized"}"#)
        #expect(packet == .connectError(message: "Not authorized"))
        #expect(packet.encoded == #"4{"message":"Not authorized"}"#)
    }

    @Test func decodesDisconnect() throws {
        #expect(try SocketIOPacket(decoding: "1") == .disconnect())
        #expect(SocketIOPacket.disconnect().encoded == "1")
        #expect(try SocketIOPacket(decoding: "1/admin,") == .disconnect(namespace: "/admin"))
    }

    @Test func decodesEvent() throws {
        let wire = #"2["foo",{"bar":1}]"#
        let packet = try SocketIOPacket(decoding: wire)
        #expect(packet == .event(name: "foo", arguments: Data(#"["foo",{"bar":1}]"#.utf8)))
        #expect(packet.encoded == wire)
    }

    @Test func decodesEventWithNamespaceAndAckID() throws {
        #expect(
            try SocketIOPacket(decoding: #"2/admin,12["foo"]"#)
                == .event(namespace: "/admin", ackID: 12, name: "foo", arguments: Data(#"["foo"]"#.utf8))
        )
        #expect(try SocketIOPacket(decoding: #"312["bar"]"#) == .ack(ackID: 12, arguments: Data(#"["bar"]"#.utf8)))
    }

    @Test func rejectsMalformedEvents() {
        #expect(throws: RealtimeCodecError.invalidPayload) { try SocketIOPacket(decoding: "2") }
        #expect(throws: RealtimeCodecError.invalidPayload) { try SocketIOPacket(decoding: "2[1]") }
        #expect(throws: RealtimeCodecError.invalidPayload) { try SocketIOPacket(decoding: "2{") }
        #expect(throws: RealtimeCodecError.unsupportedBinaryPacket) {
            try SocketIOPacket(decoding: #"51-["baz",{"_placeholder":true,"num":0}]"#)
        }
        #expect(throws: RealtimeCodecError.unknownPacketType("x")) { try SocketIOPacket(decoding: "x") }
    }

    @Test func encodesAuthEvent() throws {
        let packet = try SocketIOPacket.event("auth", "eyJhbGci.payload/sig")
        #expect(EngineIOPacket.message(packet.encoded).encoded == #"42["auth","eyJhbGci.payload/sig"]"#)
    }
}
