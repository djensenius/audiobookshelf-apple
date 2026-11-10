import Foundation
import OSLog

/// One unified logging entry, independent of `OSLogStore`.
public struct LogEntry: Sendable, Hashable {
    /// Severity, ordered from least to most severe.
    public enum Level: Int, Sendable, Comparable, CaseIterable, CustomStringConvertible {
        case debug
        case info
        case notice
        case error
        case fault

        public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

        public var description: String {
            switch self {
            case .debug: "debug"
            case .info: "info"
            case .notice: "notice"
            case .error: "error"
            case .fault: "fault"
            }
        }
    }

    public var date: Date
    public var level: Level
    public var subsystem: String
    public var category: String
    public var message: String

    public init(date: Date, level: Level, subsystem: String, category: String, message: String) {
        self.date = date
        self.level = level
        self.subsystem = subsystem
        self.category = category
        self.message = message
    }
}

/// Supplies log entries to ``LogExporter``.
public protocol LogEntrySource: Sendable {
    /// Entries for `subsystem` logged at or after `since` (all entries when `nil`), oldest first.
    func entries(subsystem: String, since: Date?) async throws -> [LogEntry]
}

/// Reads entries logged by the current process from `OSLogStore`.
///
/// The store only covers the current launch; earlier launches aren't available. Reading
/// scans the system log and can take several seconds, so never call it on the main actor.
public struct OSLogStoreSource: LogEntrySource {
    public init() {}

    public func entries(subsystem: String, since: Date?) async throws -> [LogEntry] {
        let store = try OSLogStore(scope: .currentProcessIdentifier)
        let position = since.map { store.position(date: $0) }
        let predicate = NSPredicate(format: "subsystem == %@", subsystem)
        return try store.getEntries(at: position, matching: predicate).compactMap { entry in
            guard let log = entry as? OSLogEntryLog else { return nil }
            return LogEntry(
                date: log.date,
                level: LogEntry.Level(log.level),
                subsystem: log.subsystem,
                category: log.category,
                message: log.composedMessage
            )
        }
    }
}

extension LogEntry.Level {
    init(_ level: OSLogEntryLog.Level) {
        switch level {
        case .debug: self = .debug
        case .info: self = .info
        case .error: self = .error
        case .fault: self = .fault
        // `Logger.log` writes at the default level, which `OSLogStore` reports as notice.
        default: self = .notice
        }
    }
}

/// Which entries to export.
public struct LogFilter: Sendable, Equatable {
    /// Entries below this level are dropped.
    public var minimumLevel: LogEntry.Level
    /// Categories to keep; `nil` keeps every category.
    public var categories: Set<String>?
    /// Entries before this date are dropped; `nil` keeps the whole launch.
    public var since: Date?

    public init(minimumLevel: LogEntry.Level = .debug, categories: Set<String>? = nil, since: Date? = nil) {
        self.minimumLevel = minimumLevel
        self.categories = categories
        self.since = since
    }

    public init(minimumLevel: LogEntry.Level = .debug, categories: Set<Log.Category>, since: Date? = nil) {
        self.init(minimumLevel: minimumLevel, categories: Set(categories.map(\.rawValue)), since: since)
    }

    func includes(_ entry: LogEntry) -> Bool {
        entry.level >= minimumLevel
            && (categories?.contains(entry.category) ?? true)
            && (since.map { entry.date >= $0 } ?? true)
    }
}

/// Collects the app's log entries for the current launch and formats them as text.
public actor LogExporter {
    private let source: any LogEntrySource
    private let subsystem: String
    private let redactor: Redactor
    private let timeZone: TimeZone

    /// - Parameters:
    ///   - redactor: Applied to every message; give it the custom header values so they're removed too.
    ///   - timeZone: Time zone for formatted timestamps.
    public init(
        source: any LogEntrySource = OSLogStoreSource(),
        subsystem: String = Log.subsystem,
        redactor: Redactor = Redactor(),
        timeZone: TimeZone = .current
    ) {
        self.source = source
        self.subsystem = subsystem
        self.redactor = redactor
        self.timeZone = timeZone
    }

    /// Matching entries, oldest first, with redacted messages.
    public func entries(matching filter: LogFilter = LogFilter()) async throws -> [LogEntry] {
        try await source.entries(subsystem: subsystem, since: filter.since)
            .filter { $0.subsystem == subsystem && filter.includes($0) }
            .sorted { $0.date < $1.date }
            .map { entry in
                var entry = entry
                entry.message = redactor.redact(entry.message)
                return entry
            }
    }

    /// Matching entries as text, one line per entry, oldest first.
    public func export(matching filter: LogFilter = LogFilter()) async throws -> String {
        try await entries(matching: filter).map { Self.format($0, timeZone: timeZone) }.joined(separator: "\n")
    }

    /// Formats `entry` as `2026-11-09T20:27:13.197-05:00 [notice] [api] message`.
    ///
    /// Line breaks inside the message are indented so each entry stays distinguishable.
    public static func format(_ entry: LogEntry, timeZone: TimeZone = .current) -> String {
        let timestamp = entry.date.formatted(
            Date.ISO8601FormatStyle(timeZoneSeparator: .colon, includingFractionalSeconds: true, timeZone: timeZone)
        )
        let message = entry.message.split(separator: "\n", omittingEmptySubsequences: false)
            .joined(separator: "\n    ")
        return "\(timestamp) [\(entry.level)] [\(entry.category)] \(message)"
    }
}
