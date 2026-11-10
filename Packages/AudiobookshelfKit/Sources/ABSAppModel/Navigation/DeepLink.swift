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

    /// Parses an `audiobookshelf://` URL. Returns `nil` for another scheme, `oauth`, an unknown
    /// kind, a missing or empty ID, or extra path segments.
    ///
    /// The kind is the host (`audiobookshelf://item/li_1`). When the URL has no host
    /// (`audiobookshelf:item/li_1` or `audiobookshelf:///item/li_1`) the kind is the first path
    /// segment instead, the form Android's `URL` reports. Path segments and query values are
    /// percent-decoded, and `+` in a query value is a space. A start time that isn't valid is
    /// ignored rather than rejecting the link.
    public init?(url: URL) {
        guard url.scheme?.lowercased() == "audiobookshelf",
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return nil }

        var segments: [String] = []
        for raw in components.percentEncodedPath.split(separator: "/") {
            guard let segment = String(raw).removingPercentEncoding else { return nil }
            segments.append(segment)
        }
        let kind: String
        if let host = components.host, !host.isEmpty {
            kind = host.lowercased()
        } else if !segments.isEmpty {
            kind = segments.removeFirst().lowercased()
        } else {
            return nil
        }

        let query = Self.queryValues(components)
        guard segments.count <= 1 else { return nil }
        let id = segments.first

        switch kind {
        case "item":
            guard let id else { return nil }
            target = .item(id: id, episodeID: query["episode"])
        case "play":
            guard let id else { return nil }
            let start = query["t"].flatMap(Self.parseStartTime)
            target = .play(PlayLink(itemID: id, episodeID: query["episode"], startTime: start))
        case "series", "author", "collection", "playlist", "library":
            guard let id else { return nil }
            target = Self.idTarget(kind, id: id)
        case "search":
            guard segments.isEmpty else { return nil }
            target = .search(query: query["q"])
        case "downloads":
            guard segments.isEmpty else { return nil }
            target = .downloads
        default:
            // Includes "oauth", the OIDC callback handled by the sign-in flow.
            return nil
        }
        serverID = query["server"]
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

    /// The first non-empty value of each query parameter, decoded.
    private static func queryValues(_ components: URLComponents) -> [String: String] {
        var values: [String: String] = [:]
        for item in components.percentEncodedQueryItems ?? [] {
            guard values[item.name] == nil,
                let value = item.value?.replacing("+", with: " ").removingPercentEncoding,
                !value.isEmpty
            else { continue }
            values[item.name] = value
        }
        return values
    }

    /// Parses `t=`: seconds (`5025` or `5025.5`) or a clock time (`1:23:45` or `83:45`).
    /// Returns `nil` for anything else, including negative values.
    static func parseStartTime(_ text: String) -> TimeInterval? {
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
