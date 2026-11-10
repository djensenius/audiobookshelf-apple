import Foundation

/// An `audiobookshelf://` link, parsed (ADR 0004, "Deep links and Handoff").
///
/// URLs, Handoff and later App Intents all become a `DeepLink`, and ``Router/open(_:)`` is the
/// only place that turns one into navigation. The format:
///
/// ```text
/// audiobookshelf://item/{itemID}[?episode={episodeID}]
/// audiobookshelf://play/{itemID}[?episode={episodeID}&t={start}]
/// audiobookshelf://series/{id}   …/author/{id}   …/collection/{id}   …/playlist/{id}
/// audiobookshelf://library/{libraryID}
/// audiobookshelf://search[?q={query}]
/// audiobookshelf://downloads
/// ```
///
/// Any link may add `server={connectionID}`. `audiobookshelf://oauth` is the OIDC callback,
/// which `ASWebAuthenticationSession` consumes, so it isn't a deep link.
public struct DeepLink: Hashable, Sendable {
    /// What the link opens.
    public enum Target: Hashable, Sendable {
        case item(id: String, episodeID: String?)
        case play(PlayLink)
        case series(id: String)
        case author(id: String)
        case collection(id: String)
        case playlist(id: String)
        case library(id: String)
        case search(query: String?)
        case downloads
    }

    public var target: Target
    /// The server connection the link is for (`server=`); `nil` means the active one.
    public var serverID: String?

    public init(_ target: Target, serverID: String? = nil) {
        self.target = target
        self.serverID = serverID
    }

    /// Parses an `audiobookshelf://` URL. Returns `nil` for another scheme, a URL without a
    /// host, `oauth`, an unknown kind, a missing, empty or invalid ID (``isValidID(_:)``),
    /// empty or extra path segments, a `server=` that is empty or doesn't decode, a query value
    /// that doesn't decode, or a `q=` longer than ``maxQueryLength``.
    ///
    /// The kind is the host (`audiobookshelf://item/li_1`); one trailing `/` is allowed. Path
    /// segments and query values are percent-decoded, `+` in a query value is a space, and
    /// query names are matched ignoring case, the first of a repeated name winning. A start
    /// time that isn't valid is ignored rather than rejecting the link.
    public init?(url: URL) {
        guard url.scheme?.lowercased() == "audiobookshelf",
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
            let kind = components.host?.lowercased(), !kind.isEmpty,
            let segments = Self.pathSegments(components), segments.count <= 1,
            let query = Self.queryValues(components)
        else { return nil }

        let id = segments.first
        if let id, !Self.isValidID(id) { return nil }
        let episodeID = query["episode"].flatMap { $0.isEmpty ? nil : $0 }
        if let episodeID, !Self.isValidID(episodeID) { return nil }

        switch kind {
        case "item":
            guard let id else { return nil }
            target = .item(id: id, episodeID: episodeID)
        case "play":
            guard let id else { return nil }
            let start = query["t"].flatMap(Self.parseStartTime)
            target = .play(PlayLink(itemID: id, episodeID: episodeID, startTime: start))
        case "series", "author", "collection", "playlist", "library":
            guard let id else { return nil }
            target = Self.idTarget(kind, id: id)
        case "search":
            guard id == nil else { return nil }
            let text = query["q"].flatMap { $0.isEmpty ? nil : $0 }
            if let text, text.count > Self.maxQueryLength { return nil }
            target = .search(query: text)
        case "downloads":
            guard id == nil else { return nil }
            target = .downloads
        default:
            // Includes "oauth", the OIDC callback handled by the sign-in flow.
            return nil
        }

        // A server the link names but we can't read must not fall back to the active server.
        if let server = query["server"] {
            guard Self.isValidID(server) else { return nil }
            serverID = server
        }
    }

    /// The longest ID (item, episode, series and so on, and `server=`) a link may carry.
    static let maxIDLength = 256
    /// The longest search query a link may carry.
    static let maxQueryLength = 1_024

    /// Whether `id` can be an ID: not blank, at most ``maxIDLength`` characters, no control
    /// characters, and not `.` or `..`.
    static func isValidID(_ id: String) -> Bool {
        !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && id.count <= maxIDLength
            && id != "." && id != ".."
            && !id.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }

    private static func idTarget(_ kind: String, id: String) -> Target {
        switch kind {
        case "series": .series(id: id)
        case "author": .author(id: id)
        case "collection": .collection(id: id)
        case "playlist": .playlist(id: id)
        default: .library(id: id)
        }
    }

    /// The decoded path segments after the host, or `nil` if one is empty (`item//li_1`) or
    /// doesn't decode. One trailing `/` is ignored.
    private static func pathSegments(_ components: URLComponents) -> [String]? {
        var path = Substring(components.percentEncodedPath)
        if path.hasPrefix("/") { path = path.dropFirst() }
        if path.hasSuffix("/") { path = path.dropLast() }
        guard !path.isEmpty else { return [] }
        var segments: [String] = []
        for raw in path.split(separator: "/", omittingEmptySubsequences: false) {
            guard let segment = String(raw).removingPercentEncoding, !segment.isEmpty else { return nil }
            segments.append(segment)
        }
        return segments
    }

    /// The decoded first value of each query parameter, keyed by lower-cased name; `nil` if a
    /// value doesn't decode. A parameter without a value (`?server`) is empty.
    private static func queryValues(_ components: URLComponents) -> [String: String]? {
        var values: [String: String] = [:]
        for item in components.percentEncodedQueryItems ?? [] {
            let name = item.name.lowercased()
            guard values[name] == nil else { continue }
            guard let value = (item.value ?? "").replacing("+", with: " ").removingPercentEncoding else {
                return nil
            }
            values[name] = value
        }
        return values
    }

    /// The largest start time a link may carry, about 115 days, so converting it (for
    /// example to `Duration`) can't overflow.
    static let maxStartTime: TimeInterval = 10_000_000

    /// Parses `t=`: seconds (`5025` or `5025.5`) or a clock time (`1:23:45` or `83:45`).
    /// Returns `nil` for anything else, including negative values and values above
    /// ``maxStartTime``.
    static func parseStartTime(_ text: String) -> TimeInterval? {
        guard let seconds = parseSeconds(text), seconds <= maxStartTime else { return nil }
        return seconds
    }

    private static func parseSeconds(_ text: String) -> TimeInterval? {
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count) else { return nil }
        if parts.count == 1 {
            guard text.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == ".") }),
                let seconds = TimeInterval(text), seconds.isFinite
            else { return nil }
            return seconds
        }
        var total: TimeInterval = 0
        for (index, part) in parts.enumerated() {
            guard !part.isEmpty, part.allSatisfy({ $0.isASCII && $0.isNumber }), let value = Int(part) else {
                return nil
            }
            // Every part after the first is minutes or seconds, so it must be below 60.
            if index > 0, value >= 60 { return nil }
            total = total * 60 + TimeInterval(value)
        }
        return total
    }
}

/// A `play/` link: an item (and episode) to offer to play, optionally from a start time.
/// It never starts playback by itself; see ``PlayLinkDecision``.
public struct PlayLink: Hashable, Sendable {
    public var itemID: String
    public var episodeID: String?
    /// Where to start, in seconds, from `t=`.
    public var startTime: TimeInterval?

    public init(itemID: String, episodeID: String? = nil, startTime: TimeInterval? = nil) {
        self.itemID = itemID
        self.episodeID = episodeID
        self.startTime = startTime
    }
}
