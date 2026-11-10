import os

/// Unified logging for the app and its packages.
///
/// Privacy defaults depend on the interpolated type. Dynamic strings and objects are private by
/// default, but integers, floating-point values, and `Bool`s are **public** by default, so they
/// appear in the exported log as is. Don't rely on the defaults:
///
/// - Give every interpolation an explicit `privacy:` argument.
/// - Mark a string `.public` only after passing it through ``Log/redact(_:)`` (or a ``Redactor``
///   that knows the custom header values). ``Redactor`` matches text patterns and can't recognise
///   a sensitive number.
/// - Mark sensitive numbers `.private`, or `.private(mask: .hash)` when entries need to be
///   correlated, for example user or library item identifiers held as integers, playback
///   positions, and durations.
///
/// ```swift
/// Log.api.info("GET \(Log.redact(url.absoluteString), privacy: .public)")
/// Log.playback.info("Seek to \(position, privacy: .private) in \(itemID, privacy: .private(mask: .hash))")
/// Log.downloads.info("Queued \(count, privacy: .public) files")
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
