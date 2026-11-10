import ABSCore
import Foundation
import Observation

/// State for the Logs screen (port of `pages/logs.vue`): this launch's log entries with
/// token redaction from ``LogExporter``, filtered by level, category and search text, shown
/// newest first, with server addresses masked unless the user turns masking off.
@MainActor
@Observable
public final class LogsModel {
    /// One displayed entry. Its message is already redacted and, if masking is on, masked.
    public struct Row: Identifiable, Sendable, Hashable {
        /// The entry's position in load order, unique within one load.
        public let id: Int
        public let entry: LogEntry
        /// The entry formatted like an exported line.
        public let text: String
    }

    /// Entries below this level are hidden. `.debug` shows every entry.
    public var minimumLevel: LogEntry.Level = .debug
    /// The category to show; `nil` shows every category.
    public var category: String?
    /// Text the shown message or category must contain, ignoring case and diacritics.
    public var searchText = ""
    /// Legacy "Mask server address", on by default. Applied after token redaction.
    public var masksServerAddress = true

    /// Redacted entries, oldest first.
    public private(set) var entries: [LogEntry] = []
    public private(set) var isLoading = false
    /// Whether the last load failed.
    public private(set) var loadFailed = false

    @ObservationIgnored private let exporter: LogExporter
    @ObservationIgnored private let serverAddresses: [String]
    @ObservationIgnored private let timeZone: TimeZone
    /// Incremented by each ``load()``; only the latest load's result is applied.
    @ObservationIgnored private var loadGeneration = 0
    /// Loads still running, so ``isLoading`` stays on until the last one finishes.
    @ObservationIgnored private var activeLoads = 0

    /// - Parameters:
    ///   - serverAddresses: Hosts (or full addresses) of the user's servers. Masking hides them
    ///     even where they appear without a URL scheme.
    ///   - timeZone: Time zone for formatted timestamps.
    public init(exporter: LogExporter = LogExporter(), serverAddresses: [String] = [], timeZone: TimeZone = .current) {
        self.exporter = exporter
        self.serverAddresses = serverAddresses
        self.timeZone = timeZone
    }

    /// Reads this launch's entries. Reading the system log can take several seconds.
    ///
    /// Loads can overlap (the first load and a pull to refresh): the most recently started one
    /// wins, so an older load finishing later never replaces newer entries or status.
    public func load() async {
        loadGeneration += 1
        let generation = loadGeneration
        activeLoads += 1
        isLoading = true
        defer {
            activeLoads -= 1
            isLoading = activeLoads > 0
        }
        do {
            let loaded = try await exporter.entries()
            guard generation == loadGeneration else { return }
            entries = loaded
            loadFailed = false
        } catch {
            guard generation == loadGeneration else { return }
            loadFailed = true
            Log.ui.error("Couldn't read the logs: \(String(describing: error), privacy: .public)")
        }
    }

    /// Every known category plus any found in the entries, sorted.
    public var categories: [String] {
        Set(Log.Category.allCases.map(\.rawValue)).union(entries.map(\.category)).sorted()
    }

    /// Entries passing the filters, newest first.
    public var rows: [Row] {
        matchingRows.reversed()
    }

    /// The entries passing the filters as text, one line per entry, oldest first like a log
    /// file. Copy, share and export use this.
    public var exportText: String {
        matchingRows.map(\.text).joined(separator: "\n")
    }

    /// Matching rows, oldest first.
    private var matchingRows: [Row] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return entries.enumerated().compactMap { index, entry in
            guard entry.level >= minimumLevel, category.map({ entry.category == $0 }) ?? true else { return nil }
            var shown = entry
            if masksServerAddress {
                shown.message = ServerAddressMask.apply(to: entry.message, serverAddresses: serverAddresses)
            }
            guard
                query.isEmpty || shown.message.localizedStandardContains(query)
                    || shown.category.localizedStandardContains(query)
            else { return nil }
            return Row(id: index, entry: shown, text: LogExporter.format(shown, timeZone: timeZone))
        }
    }
}

/// Hides server addresses in log text (legacy `maskLogMessage`).
public enum ServerAddressMask {
    /// Replaces each masked address.
    public static let placeholder = "[SERVER_ADDRESS]"

    /// Replaces every occurrence of `serverAddresses`, ignoring case, and everything after the
    /// scheme of each `http`, `https`, `ws` or `wss` URL up to the next whitespace.
    public static func apply(to text: String, serverAddresses: [String] = []) -> String {
        // A private-use sentinel stands in for the placeholder until the end, so a known address
        // such as `server` can't match inside an inserted placeholder.
        let sentinel = "\u{E000}"
        var result = text
        // Longest first, so one inside a longer known address doesn't leave part of it behind.
        for address in serverAddresses.filter({ !$0.isEmpty }).sorted(by: { $0.count > $1.count }) {
            result = result.replacingOccurrences(of: address, with: sentinel, options: .caseInsensitive)
        }
        result = result.replacing(/(?i)\b((?:https?|wss?):\/\/)\S+/) { match in "\(match.output.1)\(sentinel)" }
        return result.replacingOccurrences(of: sentinel, with: placeholder)
    }
}
