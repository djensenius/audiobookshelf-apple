import os

/// Unified logging for the app and its packages.
///
/// Interpolated values are private by default in unified logging, which hides them from
/// the exported log. Mark a value `.public` only after passing it through
/// ``Log/redact(_:)`` (or a ``Redactor`` that knows the custom header values):
///
/// ```swift
/// Log.api.info("GET \(Log.redact(url.absoluteString), privacy: .public)")
/// ```
public enum Log {
    /// The unified logging subsystem shared by every category.
    public static let subsystem = "org.davidjensenius.Audiobookshelf"

    /// A per-module logging category.
    public enum Category: String, CaseIterable, Sendable {
        case api
        case auth
        case realtime
        case playback
        case downloads
        case data
        case ui
    }

    public static let api = logger(.api)
    public static let auth = logger(.auth)
    public static let realtime = logger(.realtime)
    public static let playback = logger(.playback)
    public static let downloads = logger(.downloads)
    public static let data = logger(.data)
    public static let ui = logger(.ui)

    /// Creates a logger for `category` in ``subsystem``.
    public static func logger(_ category: Category) -> Logger {
        Logger(subsystem: subsystem, category: category.rawValue)
    }

    /// Removes bearer tokens, token query values, and JWTs from `text`.
    public static func redact(_ text: String) -> String {
        Redactor().redact(text)
    }
}
