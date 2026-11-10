import ABSCore
import ABSData
import Foundation
import Testing

@testable import ABSAPI

private func date(milliseconds: Int) -> Date {
    Date(timeIntervalSince1970: Double(milliseconds) / 1000)
}

extension MediaProgress {
    /// The server's values as `LocalProgressStore` merges them.
    fileprivate var baseline: ProgressBaseline {
        ProgressBaseline(
            currentTime: currentTime, progress: progress, duration: duration, isFinished: isFinished,
            finishedAt: finishedAt.map { date(milliseconds: $0) }, ebookLocation: ebookLocation,
            ebookProgress: ebookProgress, lastUpdate: date(milliseconds: lastUpdate ?? 0))
    }
}

extension ProgressSend {
    /// The PATCH body for the one group this send carries. The app has no such mapping yet, so
    /// this mirrors what `MediaProgressUpdate` documents.
    fileprivate var update: MediaProgressUpdate? {
        if let audio {
            return .audio(currentTime: audio.currentTime, duration: audio.duration, progress: audio.progress)
        }
        if let finished { return .finished(finished.isFinished, at: finished.finishedAt) }
        if let ebook, let location = ebook.ebookLocation {
            return .ebook(location: location, progress: ebook.ebookProgress ?? 0)
        }
        return nil
    }
}

/// One item's `LocalProgressStore` row, synced to the real server as ADR 0003 describes: a
/// PATCH per dirty group, then a fetch that confirms what the server holds.
private struct SyncedRow {
    let store: LocalProgressStore
    let session: ContractSession
    let key: MediaKey

    init(_ session: ContractSession, itemID: String) throws {
        store = LocalProgressStore(modelContainer: try DataStack(location: .inMemory).container)
        self.session = session
        key = MediaKey(serverConnectionID: UUID(), libraryItemId: itemID)
    }

    func edit(_ edit: ProgressEdit, seededFrom server: MediaProgress? = nil, at time: Date = .now) async throws {
        try await store.recordEdit(edit, for: key, serverProgress: server?.baseline, now: time)
    }

    /// Sends every dirty group, one PATCH each, and returns the groups in the order sent.
    @discardableResult
    func send() async throws -> [ProgressGroups] {
        var sent: [ProgressGroups] = []
        while let patch = try await store.beginSend(for: key) {
            sent.append(patch.values.groups)
            let update = try #require(patch.values.update)
            do {
                _ = try await session.client.send(
                    ProgressEndpoints.update(itemID: key.libraryItemId, episodeID: key.episodeId, update))
            } catch {
                try await store.failSend(patch, error: "\(error)")
                throw error
            }
            try await store.completeSend(patch, serverLastUpdate: nil)
        }
        return sent
    }

    /// The fetch after a PATCH whose response has no server time: capture the generation, read
    /// the server's row, merge it.
    func confirm() async throws {
        let generation = await store.captureGeneration()
        let server = try await serverRow()
        try await store.applyServerProgress([key: server.baseline], capturedAt: generation, source: .fetch)
    }

    func serverRow() async throws -> MediaProgress {
        try await session.progress(key.libraryItemId)
    }

    func local() async throws -> LocalMediaProgressDTO {
        try #require(try await store.progress(for: key))
    }
}

/// `LocalProgressStore` (ABSData) driven against a real server: what a row holds once the server
/// has applied, normalized or overridden what was sent.
@Suite("Server contract: local progress sync", .requiresServer, .tags(.serverContract))
struct LocalProgressContractTests {
    private static let audio = ProgressEdit(audio: .init(currentTime: 10, duration: 50, progress: 0.2))

    @Test("an audio edit is one PATCH and the row settles on the server's values")
    func audioEdit() async throws {
        let seed = try await ContractSeed.shared.data()
        try await ContractServer.require().withUser { session in
            let row = try SyncedRow(session, itemID: seed.taleID)
            try await row.edit(Self.audio)
            #expect(try await row.local().dirtyGroups == .audio)

            #expect(try await row.send() == [.audio])
            // The PATCH's response has no server time, so the row waits for a fetch.
            #expect(await row.store.needsConfirmationFetch == [row.key])
            try await row.confirm()

            let server = try await row.serverRow()
            let local = try await row.local()
            #expect(await row.store.needsConfirmationFetch.isEmpty)
            #expect(local.dirtyGroups.isEmpty)
            #expect(!local.needsServerSync)
            #expect(local.unacknowledgedSends.isEmpty)
            #expect(local.currentTime == 10)
            #expect(local.serverBaseline == server.baseline)
            #expect(try await row.send().isEmpty)
        }
    }

    @Test("audio and finished edits go as two PATCHes, audio first")
    func audioThenFinished() async throws {
        let seed = try await ContractSeed.shared.data()
        try await ContractServer.require().withUser { session in
            let row = try SyncedRow(session, itemID: seed.taleID)
            try await row.edit(Self.audio)
            try await row.edit(ProgressEdit(isFinished: true))
            #expect(try await row.send() == [.audio, .finished])
            try await row.confirm()

            let server = try await row.serverRow()
            #expect(server.isFinished)
            #expect(server.currentTime == 10)
            let local = try await row.local()
            #expect(local.isFinished)
            #expect(local.currentTime == 10)
            // The server set `progress` to 1 for the finished item; the row follows it.
            #expect(local.progress == 1)
            #expect(local.finishedAt == server.finishedAt.map { date(milliseconds: $0) })
            #expect(local.dirtyGroups.isEmpty)
        }
    }

    @Test("an audio edit near the end is auto-finished by the server, and the row follows")
    func autoFinish() async throws {
        let seed = try await ContractSeed.shared.data()
        try await ContractServer.require().withUser { session in
            let row = try SyncedRow(session, itemID: seed.taleID)
            // Only an update finishes an item near its end; the PATCH that creates the row does not.
            try await session.patch(seed.taleID, .audio(currentTime: 10, duration: 50, progress: 0.2))
            try await row.edit(
                ProgressEdit(audio: .init(currentTime: 45, duration: 50, progress: 0.9)),
                seededFrom: try await row.serverRow())
            #expect(try await row.local().isFinished == false)
            #expect(try await row.send() == [.audio])
            try await row.confirm()

            let server = try await row.serverRow()
            #expect(server.isFinished)
            let local = try await row.local()
            #expect(local.isFinished)
            #expect(local.finishedAt != nil)
            #expect(local.currentTime == 45)
            #expect(local.progress == 1)
            #expect(local.dirtyGroups.isEmpty)
        }
    }

    @Test("marking unfinished resets the position on the server, and the row follows")
    func finishedReset() async throws {
        let seed = try await ContractSeed.shared.data()
        try await ContractServer.require().withUser { session in
            let row = try SyncedRow(session, itemID: seed.taleID)
            try await session.patch(seed.taleID, .audio(currentTime: 10, duration: 50, progress: 0.2))
            try await session.patch(seed.taleID, .finished(true))
            try await row.edit(ProgressEdit(isFinished: false), seededFrom: try await row.serverRow())
            #expect(try await row.local().currentTime == 10)
            #expect(try await row.send() == [.finished])
            try await row.confirm()

            let server = try await row.serverRow()
            #expect(!server.isFinished)
            #expect(server.currentTime == 0)
            let local = try await row.local()
            #expect(!local.isFinished)
            #expect(local.currentTime == 0)
            #expect(local.progress == 0)
            #expect(local.dirtyGroups.isEmpty)
        }
    }

    @Test("an ebook edit with progress 0 is stored as 0 and settles")
    func ebookEdit() async throws {
        let seed = try await ContractSeed.shared.data()
        try await ContractServer.require().withUser { session in
            let row = try SyncedRow(session, itemID: seed.taleID)
            try await row.edit(ProgressEdit(ebook: .init(location: "epubcfi(/6/4)", progress: 0)))
            #expect(try await row.send() == [.ebook])
            try await row.confirm()

            let server = try await row.serverRow()
            #expect(server.ebookLocation == "epubcfi(/6/4)")
            #expect(server.ebookProgress == 0)
            let local = try await row.local()
            #expect(local.ebookLocation == "epubcfi(/6/4)")
            #expect(local.ebookProgress == 0)
            #expect(local.dirtyGroups.isEmpty)
        }
    }

    @Test("a PATCH whose response was lost is settled by the server's echo, not sent again")
    func lostResponse() async throws {
        let seed = try await ContractSeed.shared.data()
        try await ContractServer.require().withUser { session in
            let row = try SyncedRow(session, itemID: seed.taleID)
            try await row.edit(Self.audio)
            let patch = try #require(try await row.store.beginSend(for: row.key))
            try await session.patch(seed.taleID, #require(patch.values.update))
            try await row.store.failSend(patch, error: "The network connection was lost.")
            #expect(try await row.local().needsServerSync)

            try await row.confirm()
            let local = try await row.local()
            #expect(local.dirtyGroups.isEmpty)
            #expect(!local.needsServerSync)
            #expect(local.currentTime == 10)
            #expect(try await row.send().isEmpty)
        }
    }

    @Test("a conflict is decided by the edit time against the server's lastUpdate")
    func conflict() async throws {
        let seed = try await ContractSeed.shared.data()
        try await ContractServer.require().withUser { session in
            // This device last edited long ago, another saved since: the server's position wins.
            let behind = try SyncedRow(session, itemID: seed.taleID)
            try await session.patch(seed.taleID, .audio(currentTime: 10, duration: 50, progress: 0.2))
            try await behind.edit(
                ProgressEdit(audio: .init(currentTime: 20, duration: 50, progress: 0.4)),
                seededFrom: try await behind.serverRow(), at: Date(timeIntervalSince1970: 1_000_000_000))
            try await Task.sleep(for: .milliseconds(20))
            try await session.patch(seed.taleID, .audio(currentTime: 30, duration: 50, progress: 0.6))
            try await behind.confirm()
            let lost = try await behind.local()
            #expect(lost.currentTime == 30)
            #expect(lost.dirtyGroups.isEmpty)
            #expect(try await behind.send().isEmpty)

            // A device clock far ahead of the server's keeps its edit, which is then sent.
            let ahead = try SyncedRow(session, itemID: seed.singleFileID)
            try await session.patch(seed.singleFileID, .audio(currentTime: 5, duration: 40, progress: 0.125))
            try await ahead.edit(
                ProgressEdit(audio: .init(currentTime: 15, duration: 40, progress: 0.375)),
                seededFrom: try await ahead.serverRow(), at: Date(timeIntervalSince1970: 4_102_444_800))
            try await Task.sleep(for: .milliseconds(20))
            try await session.patch(seed.singleFileID, .audio(currentTime: 25, duration: 40, progress: 0.625))
            try await ahead.confirm()
            let kept = try await ahead.local()
            #expect(kept.currentTime == 15)
            #expect(kept.dirtyGroups == .audio)
            #expect(try await ahead.send() == [.audio])
            try await ahead.confirm()
            #expect(try await ahead.serverRow().currentTime == 15)
            #expect(try await ahead.local().dirtyGroups.isEmpty)
        }
    }
}
