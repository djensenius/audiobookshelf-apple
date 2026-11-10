import Foundation

/// Errors from decoding Engine.IO or Socket.IO text packets.
enum RealtimeCodecError: Error, Sendable, Equatable {
    case emptyPacket
    case unknownPacketType(Character)
    case invalidPayload
    /// Binary Socket.IO packets (types 5 and 6) need attachment frames; this client is JSON only.
    case unsupportedBinaryPacket
}

/// The open packet's payload: `0{"sid":…,"upgrades":[],"pingInterval":25000,"pingTimeout":20000,…}`.
struct EngineIOHandshake: Sendable, Equatable, Codable {
    var sid: String
    var upgrades: [String]
    /// Milliseconds between server pings.
    var pingInterval: Int
    /// Milliseconds the server waits for a pong.
    var pingTimeout: Int
    /// Polling only; optional for a WebSocket-only client.
    var maxPayload: Int?

    init(sid: String, upgrades: [String] = [], pingInterval: Int, pingTimeout: Int, maxPayload: Int? = nil) {
        self.sid = sid
        self.upgrades = upgrades
        self.pingInterval = pingInterval
        self.pingTimeout = pingTimeout
        self.maxPayload = maxPayload
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sid = try container.decode(String.self, forKey: .sid)
        upgrades = try container.decodeIfPresent([String].self, forKey: .upgrades) ?? []
        pingInterval = try container.decode(Int.self, forKey: .pingInterval)
        pingTimeout = try container.decode(Int.self, forKey: .pingTimeout)
        maxPayload = try container.decodeIfPresent(Int.self, forKey: .maxPayload)
        // Bounded so `livenessTimeout` can't overflow; the defaults are 25 s and 20 s.
        guard Self.allowedMilliseconds.contains(pingInterval), Self.allowedMilliseconds.contains(pingTimeout) else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "pingInterval or pingTimeout out of range")
            )
        }
    }

    /// 0 to 1 hour.
    static let allowedMilliseconds = 0...3_600_000

    /// No ping within `pingInterval + pingTimeout` of the open packet or the last ping means the
    /// connection is dead. Other packets don't reset this timer (as in engine.io-client).
    var livenessTimeout: Duration {
        .milliseconds(pingInterval + pingTimeout)
    }
}

/// An Engine.IO v4 text packet. Over WebSocket each frame carries exactly one packet.
enum EngineIOPacket: Sendable, Equatable {
    case open(EngineIOHandshake)
    case close
    case ping(String)
    case pong(String)
    case message(String)
    case upgrade
    case noop

    init(decoding text: String) throws(RealtimeCodecError) {
        guard let type = text.first else { throw .emptyPacket }
        let data = String(text.dropFirst())
        switch type {
        case "0":
            guard let handshake = try? JSONDecoder().decode(EngineIOHandshake.self, from: Data(data.utf8)) else {
                throw .invalidPayload
            }
            self = .open(handshake)
        case "1": self = .close
        case "2": self = .ping(data)
        case "3": self = .pong(data)
        case "4": self = .message(data)
        case "5": self = .upgrade
        case "6": self = .noop
        default: throw .unknownPacketType(type)
        }
    }

    var encoded: String {
        switch self {
        case .open(let handshake):
            let json = (try? JSONEncoder().encode(handshake)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
            return "0" + json
        case .close: return "1"
        case .ping(let data): return "2" + data
        case .pong(let data): return "3" + data
        case .message(let data): return "4" + data
        case .upgrade: return "5"
        case .noop: return "6"
        }
    }
}

/// A Socket.IO v4 packet, carried inside an Engine.IO `message` packet.
///
/// JSON payloads are kept as raw bytes so callers decode them straight into their own types.
enum SocketIOPacket: Sendable, Equatable {
    static let mainNamespace = "/"

    case connect(namespace: String = mainNamespace, payload: Data? = nil)
    case disconnect(namespace: String = mainNamespace)
    /// `arguments` is the whole JSON array, including the event name at index 0.
    case event(namespace: String = mainNamespace, ackID: Int? = nil, name: String, arguments: Data)
    case ack(namespace: String = mainNamespace, ackID: Int, arguments: Data)
    case connectError(namespace: String = mainNamespace, message: String?)

    /// Builds an event packet, e.g. `["auth","<token>"]`.
    static func event(_ name: String, _ argument: some Encodable & Sendable) throws -> SocketIOPacket {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        let arguments = try encoder.encode(EventArgumentsEncoding(name: name, argument: argument))
        return .event(name: name, arguments: arguments)
    }

    init(decoding text: String) throws(RealtimeCodecError) {
        var rest = Substring(text)
        guard let typeCharacter = rest.popFirst() else { throw .emptyPacket }
        guard let type = typeCharacter.wholeNumberValue, ("0"..."6").contains(typeCharacter) else {
            throw .unknownPacketType(typeCharacter)
        }
        if type == 5 || type == 6 { throw .unsupportedBinaryPacket }

        var namespace = Self.mainNamespace
        if rest.first == "/" {
            if let comma = rest.firstIndex(of: ",") {
                namespace = String(rest[..<comma])
                rest = rest[rest.index(after: comma)...]
            } else {
                namespace = String(rest)
                rest = ""
            }
        }

        let digits = rest.prefix(while: \.isASCIIDigit)
        let ackID = digits.isEmpty ? nil : Int(digits)
        rest = rest.dropFirst(digits.count)
        try self.init(type: type, namespace: namespace, ackID: ackID, payload: rest)
    }

    private init(type: Int, namespace: String, ackID: Int?, payload: Substring) throws(RealtimeCodecError) {
        let data = payload.isEmpty ? nil : Data(payload.utf8)
        switch type {
        case 0:
            // Absent, or a JSON object such as `{"sid":…}`.
            if let data, !Self.isJSONObject(data) { throw .invalidPayload }
            self = .connect(namespace: namespace, payload: data)
        case 1:
            guard data == nil, ackID == nil else { throw .invalidPayload }
            self = .disconnect(namespace: namespace)
        case 2:
            guard let data, let head = try? JSONDecoder().decode(EventHead.self, from: data) else {
                throw .invalidPayload
            }
            self = .event(namespace: namespace, ackID: ackID, name: head.name, arguments: data)
        case 3:
            guard let ackID, let data else { throw .invalidPayload }
            self = .ack(namespace: namespace, ackID: ackID, arguments: data)
        default:
            // Absent, or an object like `{"message":"Not authorized"}`.
            var message: String?
            if let data {
                guard Self.isJSONObject(data),
                    let payload = try? JSONDecoder().decode(ConnectErrorPayload.self, from: data)
                else { throw .invalidPayload }
                message = payload.message
            }
            self = .connectError(namespace: namespace, message: message)
        }
    }

    private static func isJSONObject(_ data: Data) -> Bool {
        (try? JSONSerialization.jsonObject(with: data)) is [String: Any]
    }

    var encoded: String {
        switch self {
        case .connect(let namespace, let payload):
            Self.encode(type: 0, namespace: namespace, ackID: nil, payload: payload)
        case .disconnect(let namespace):
            Self.encode(type: 1, namespace: namespace, ackID: nil, payload: nil)
        case .event(let namespace, let ackID, _, let arguments):
            Self.encode(type: 2, namespace: namespace, ackID: ackID, payload: arguments)
        case .ack(let namespace, let ackID, let arguments):
            Self.encode(type: 3, namespace: namespace, ackID: ackID, payload: arguments)
        case .connectError(let namespace, let message):
            Self.encode(
                type: 4, namespace: namespace, ackID: nil,
                payload: message.flatMap { try? JSONEncoder().encode(ConnectErrorPayload(message: $0)) }
            )
        }
    }

    private static func encode(type: Int, namespace: String, ackID: Int?, payload: Data?) -> String {
        var text = String(type)
        if namespace != mainNamespace { text += namespace + "," }
        if let ackID { text += String(ackID) }
        if let payload { text += String(decoding: payload, as: UTF8.self) }
        return text
    }
}

/// Decodes the first argument after the event name of a Socket.IO event array.
struct EventArgument<Value: Decodable>: Decodable {
    let value: Value

    init(from decoder: any Decoder) throws {
        var container = try decoder.unkeyedContainer()
        _ = try container.decode(String.self)
        value = try container.decode(Value.self)
    }
}

private struct EventHead: Decodable {
    let name: String

    init(from decoder: any Decoder) throws {
        var container = try decoder.unkeyedContainer()
        name = try container.decode(String.self)
    }
}

private struct EventArgumentsEncoding<Argument: Encodable>: Encodable {
    let name: String
    let argument: Argument

    func encode(to encoder: any Encoder) throws {
        var container = encoder.unkeyedContainer()
        try container.encode(name)
        try container.encode(argument)
    }
}

private struct ConnectErrorPayload: Codable {
    let message: String?
}

extension Character {
    fileprivate var isASCIIDigit: Bool { isASCII && isWholeNumber }
}
