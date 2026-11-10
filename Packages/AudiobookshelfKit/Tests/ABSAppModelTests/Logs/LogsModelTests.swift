import ABSCore
import Foundation
import Testing

@testable import ABSAppModel

private struct FakeSource: LogEntrySource {
    var stored: [LogEntry]

    func entries(subsystem: String, since: Date?) async throws -> [LogEntry] {
        stored
    }
}

private struct FailingSource: LogEntrySource {
    struct Failure: Error {}

    func entries(subsystem: String, since: Date?) async throws -> [LogEntry] {
        throw Failure()
    }
}

private let start = Date(timeIntervalSince1970: 1_800_000_000)
private let jwt = "eyJhbGciOiJIUzI1NiJ9.eyJ1c2VySWQiOiIxIn0.c2lnbmF0dXJl"

private func entry(
    _ seconds: TimeInterval, _ level: LogEntry.Level = .notice, _ category: String = "api", _ message: String = "m"
) -> LogEntry {
    LogEntry(
        date: start.addingTimeInterval(seconds), level: level, subsystem: Log.subsystem, category: category,
        message: message)
}

/// A model loaded with `entries` (in any order) and UTC timestamps.
@MainActor
private func loadedModel(_ entries: [LogEntry], serverAddresses: [String] = []) async -> LogsModel {
    let exporter = LogExporter(source: FakeSource(stored: entries))
    let model = LogsModel(exporter: exporter, serverAddresses: serverAddresses, timeZone: .gmt)
    await model.load()
    return model
}

@MainActor
@Suite struct LogsModelTests {
    // MARK: Loading and order

    @Test func showsNewestFirstAndExportsOldestFirst() async {
        let model = await loadedModel([entry(1, .info, "api", "second"), entry(0), entry(2, .info, "ui", "third")])

        #expect(model.rows.map(\.entry.message) == ["third", "second", "m"])
        #expect(
            model.exportText.components(separatedBy: "\n").map { $0.components(separatedBy: "] ").last } == [
                "m", "second", "third",
            ])
        #expect(Set(model.rows.map(\.id)).count == 3)
    }

    @Test func formatsRowsLikeExportedLines() async {
        let model = await loadedModel([entry(0.25, .error, "auth", "Login failed")])
        #expect(model.rows.map(\.text) == ["2027-01-15T08:00:00.250Z [error] [auth] Login failed"])
        #expect(model.exportText == "2027-01-15T08:00:00.250Z [error] [auth] Login failed")
    }

    @Test func reportsAFailedLoad() async {
        let model = LogsModel(exporter: LogExporter(source: FailingSource()))
        await model.load()
        #expect(model.loadFailed)
        #expect(model.rows.isEmpty)
        #expect(!model.isLoading)
    }

    // MARK: Filters

    @Test func filtersByMinimumLevel() async {
        let model = await loadedModel([
            entry(0, .debug, "api", "d"), entry(1, .info, "api", "i"), entry(2, .notice, "api", "n"),
            entry(3, .error, "api", "e"), entry(4, .fault, "api", "f"),
        ])
        #expect(model.minimumLevel == .debug)
        #expect(model.rows.count == 5)

        model.minimumLevel = .error
        #expect(model.rows.map(\.entry.message) == ["f", "e"])
        #expect(!model.exportText.contains("[notice]"))
    }

    @Test func filtersByCategory() async {
        let model = await loadedModel([
            entry(0, .info, "api", "a"), entry(1, .info, "auth", "b"), entry(2, .info, "custom", "c"),
        ])
        #expect(model.categories.contains("custom"))
        #expect(model.categories.contains("playback"))
        #expect(model.categories == model.categories.sorted())

        model.category = "auth"
        #expect(model.rows.map(\.entry.message) == ["b"])
        model.category = nil
        #expect(model.rows.count == 3)
    }

    @Test func searchesMessagesAndCategoriesIgnoringCase() async {
        let model = await loadedModel([
            entry(0, .info, "api", "GET /api/libraries"), entry(1, .info, "playback", "Started Café session"),
        ])
        model.searchText = "LIBRARIES"
        #expect(model.rows.map(\.entry.message) == ["GET /api/libraries"])
        model.searchText = "cafe"
        #expect(model.rows.map(\.entry.message) == ["Started Café session"])
        model.searchText = " playback "
        #expect(model.rows.count == 1)
        model.searchText = "nothing"
        #expect(model.rows.isEmpty)
        #expect(model.exportText.isEmpty)
    }

    @Test func combinesFilters() async {
        let model = await loadedModel([
            entry(0, .error, "api", "timeout"), entry(1, .info, "api", "timeout"), entry(2, .error, "ui", "timeout"),
        ])
        model.minimumLevel = .error
        model.category = "api"
        model.searchText = "time"
        #expect(model.rows.map(\.id) == [0])
    }

    // MARK: Server address masking

    @Test func masksServerAddressesByDefault() async {
        let model = await loadedModel([entry(0, .info, "api", "GET https://abs.example.com:13378/api/me failed")])
        #expect(model.masksServerAddress)
        #expect(model.rows.map(\.entry.message) == ["GET https://[SERVER_ADDRESS] failed"])
        #expect(!model.exportText.contains("abs.example.com"))
    }

    @Test func turningMaskingOffShowsTheAddress() async {
        let model = await loadedModel([entry(0, .info, "api", "GET https://abs.example.com/api/me failed")])
        model.masksServerAddress = false
        #expect(model.rows.map(\.entry.message) == ["GET https://abs.example.com/api/me failed"])
        #expect(model.exportText.contains("https://abs.example.com/api/me"))
    }

    @Test func searchMatchesOnlyShownText() async {
        let model = await loadedModel([entry(0, .info, "api", "Connected to wss://abs.example.com/socket.io")])
        model.searchText = "example"
        #expect(model.rows.isEmpty)
        model.masksServerAddress = false
        #expect(model.rows.count == 1)
    }

    @Test func masksKnownServerAddressesWithoutAScheme() async {
        let model = await loadedModel(
            [entry(0, .info, "realtime", "Reconnecting to ABS.example.com in 5 s")],
            serverAddresses: ["abs.example.com"])
        #expect(model.rows.map(\.entry.message) == ["Reconnecting to [SERVER_ADDRESS] in 5 s"])
        model.masksServerAddress = false
        #expect(model.rows.map(\.entry.message) == ["Reconnecting to ABS.example.com in 5 s"])
    }

    @Test(arguments: [
        ("Opened http://10.0.0.2:13378/login now", "Opened http://[SERVER_ADDRESS] now"),
        ("a https://x.test b wss://y.test c", "a https://[SERVER_ADDRESS] b wss://[SERVER_ADDRESS] c"),
        ("HTTPS://Upper.Example", "HTTPS://[SERVER_ADDRESS]"),
        ("no address here", "no address here"),
    ])
    func masksURLsAnywhereInText(input: String, expected: String) {
        #expect(ServerAddressMask.apply(to: input) == expected)
    }

    @Test func masksLongerKnownAddressesFirstAndLeavesPlaceholdersAlone() {
        let masked = ServerAddressMask.apply(
            to: "host abs.example.com, server x", serverAddresses: ["example.com", "abs.example.com", "server", ""])
        #expect(masked == "host [SERVER_ADDRESS], [SERVER_ADDRESS] x")
    }

    // MARK: Tokens

    @Test(arguments: [true, false])
    func exportContainsNoTokens(masksServerAddress: Bool) async {
        let model = await loadedModel([
            entry(0, .info, "auth", "Got access token \(jwt)"),
            entry(1, .info, "api", "GET https://abs.example.com/api/items/1/cover?token=s3cr3t-value&w=400"),
            entry(2, .error, "api", "Retrying /hls/stream.m3u8?token=0paque-token-123 with Bearer \(jwt)"),
        ])
        model.masksServerAddress = masksServerAddress

        let text = model.exportText
        #expect(text.components(separatedBy: "\n").count == 3)
        for secret in [jwt, "eyJhbGciOiJIUzI1NiJ9", "s3cr3t-value", "0paque-token-123"] {
            #expect(!text.contains(secret))
        }
        #expect(text.contains(Redactor.placeholder))
        #expect(text.contains("token=\(Redactor.placeholder)"))
    }
}
