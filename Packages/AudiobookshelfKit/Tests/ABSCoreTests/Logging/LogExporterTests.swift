import ABSCore
import Foundation
import Testing

private struct FakeSource: LogEntrySource {
    var stored: [LogEntry]

    func entries(subsystem: String, since: Date?) async throws -> [LogEntry] {
        stored
    }
}

private let utc = TimeZone(identifier: "UTC")!
private let start = Date(timeIntervalSince1970: 1_800_000_000)

private func entry(
    _ seconds: TimeInterval,
    _ level: LogEntry.Level = .notice,
    _ category: String = "api",
    _ message: String = "m",
    subsystem: String = Log.subsystem
) -> LogEntry {
    LogEntry(
        date: start.addingTimeInterval(seconds), level: level, subsystem: subsystem, category: category,
        message: message)
}

@Suite struct LogExporterTests {
    @Test func formatsEntryWithTimestampLevelAndCategory() {
        let line = LogExporter.format(entry(0.25, .error, "auth", "Login failed"), timeZone: utc)
        #expect(line == "2027-01-15T08:00:00.250Z [error] [auth] Login failed")
    }

    @Test func formatsTimestampInGivenTimeZone() throws {
        let toronto = try #require(TimeZone(identifier: "America/Toronto"))
        #expect(LogExporter.format(entry(0), timeZone: toronto).hasPrefix("2027-01-15T03:00:00.000-05:00 "))
    }

    @Test func indentsContinuationLines() {
        let line = LogExporter.format(entry(0, .info, "ui", "first\nsecond"), timeZone: utc)
        #expect(line == "2027-01-15T08:00:00.000Z [info] [ui] first\n    second")
    }

    @Test(arguments: ["\r\n", "\r", "\n", "\u{0B}", "\u{0C}", "\u{85}", "\u{2028}", "\u{2029}"])
    func normalisesLineBreaks(separator: String) {
        let message = "first\(separator)2027-01-15T08:00:00.000Z [fault] [auth] forged"
        let line = LogExporter.format(entry(0, .info, "ui", message), timeZone: utc)
        #expect(
            line == "2027-01-15T08:00:00.000Z [info] [ui] first\n    2027-01-15T08:00:00.000Z [fault] [auth] forged")
    }

    @Test func keepsEmptyLinesAndMixedBreaksIndented() {
        let line = LogExporter.format(entry(0, .info, "ui", "a\r\n\r\nb\rc\n"), timeZone: utc)
        #expect(line == "2027-01-15T08:00:00.000Z [info] [ui] a\n    \n    b\n    c\n    ")
    }

    @Test func exportedTextHasOneUnindentedLinePerEntry() async throws {
        let exporter = LogExporter(
            source: FakeSource(stored: [
                entry(0, .info, "api", "one\r\ntwo\u{2028}three"), entry(1, .error, "api", "four"),
            ]),
            timeZone: utc
        )
        let lines = try await exporter.export().split(separator: "\n")
        #expect(lines.filter { !$0.hasPrefix(" ") }.count == 2)
        #expect(lines.count == 4)
    }

    @Test func exportsSortedRedactedLines() async throws {
        let exporter = LogExporter(
            source: FakeSource(stored: [
                entry(2, .notice, "api", "GET /items?token=abc"),
                entry(1, .info, "auth", "Bearer xyz"),
            ]),
            timeZone: utc
        )
        let text = try await exporter.export()
        #expect(
            text == """
                2027-01-15T08:00:01.000Z [info] [auth] Bearer <redacted>
                2027-01-15T08:00:02.000Z [notice] [api] GET /items?token=<redacted>
                """
        )
    }

    @Test func appliesCustomHeaderSecrets() async throws {
        let exporter = LogExporter(
            source: FakeSource(stored: [entry(0, .info, "api", "header X-Key: hunter2")]),
            redactor: Redactor(secrets: ["hunter2"])
        )
        #expect(try await exporter.entries().map(\.message) == ["header X-Key: <redacted>"])
    }

    @Test func filtersByLevelCategorySinceAndSubsystem() async throws {
        let exporter = LogExporter(
            source: FakeSource(stored: [
                entry(0, .error, "api", "too early"),
                entry(1, .debug, "api", "too verbose"),
                entry(2, .notice, "ui", "other category"),
                entry(3, .error, "api", "other subsystem", subsystem: "com.apple.network"),
                entry(4, .notice, "api", "kept notice"),
                entry(5, .fault, "playback", "kept fault"),
            ])
        )
        let filter = LogFilter(
            minimumLevel: .notice,
            categories: [Log.Category.api, .playback],
            since: start.addingTimeInterval(1)
        )
        #expect(try await exporter.entries(matching: filter).map(\.message) == ["kept notice", "kept fault"])
    }

    @Test func emptyExportIsEmptyString() async throws {
        let exporter = LogExporter(source: FakeSource(stored: []))
        #expect(try await exporter.export().isEmpty)
    }

    @Test func levelsAreOrderedBySeverity() {
        #expect(LogEntry.Level.allCases.sorted() == [.debug, .info, .notice, .error, .fault])
    }

    @Test func categoriesMatchModules() {
        #expect(
            Log.Category.allCases.map(\.rawValue) == ["api", "auth", "realtime", "playback", "downloads", "data", "ui"])
    }
}

#if os(macOS)
    extension Tag {
        /// Tests that take many seconds; opt in with `ABS_SLOW_TESTS=1`.
        @Tag static var slow: Self
    }

    /// Writes through `Logger` and reads the entry back from the real `OSLogStore`.
    ///
    /// Each `OSLogStore` read scans the system log and can take 10–20 seconds, so this only runs
    /// with `ABS_SLOW_TESTS` set (`mise run test:kit:slow`).
    @Suite struct OSLogStoreIntegrationTests {
        @Test(
            .tags(.slow),
            .enabled(if: ProcessInfo.processInfo.environment["ABS_SLOW_TESTS"] != nil),
            .timeLimit(.minutes(2))
        )
        func readsBackWrittenEntry() async throws {
            let marker = UUID().uuidString
            let since = Date().addingTimeInterval(-1)
            Log.logger(.data).error(
                "integration \(marker, privacy: .public) Bearer \("t0ken", privacy: .public)")

            let exporter = LogExporter(timeZone: utc)
            let filter = LogFilter(categories: [Log.Category.data], since: since)
            var found: [LogEntry] = []
            // The store can lag slightly behind the write.
            for _ in 0..<3 where found.isEmpty {
                found = try await exporter.entries(matching: filter).filter { $0.message.contains(marker) }
                if found.isEmpty { try await Task.sleep(for: .seconds(1)) }
            }

            let logged = try #require(found.first)
            #expect(logged.level == .error)
            #expect(logged.category == "data")
            #expect(logged.subsystem == Log.subsystem)
            #expect(logged.message == "integration \(marker) Bearer <redacted>")
        }
    }
#endif
