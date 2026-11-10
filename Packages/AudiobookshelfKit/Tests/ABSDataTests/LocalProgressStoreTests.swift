import ABSCore
import Foundation
import SwiftData
import Testing

@testable import ABSData

@Suite struct LocalProgressStoreTests {
    private static let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private let key = MediaKey(serverConnectionID: Fixtures.connectionID, libraryItemId: "li_1")

    private static func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

    private func makeStore() throws -> (LocalProgressStore, ModelContainer) {
        let container = try DataStack(location: .inMemory).container
        return (LocalProgressStore(modelContainer: container), container)
    }

    private static func server(currentTime: Double = 100, ebookLocation: String? = nil, lastUpdate: Date)
        -> ProgressBaseline
    {
        ProgressBaseline(
            currentTime: currentTime, progress: currentTime / 1000, duration: 1000, isFinished: false,
            ebookLocation: ebookLocation, lastUpdate: lastUpdate)
    }

    private static func seek(_ currentTime: Double) -> ProgressEdit {
        ProgressEdit(audio: .init(currentTime: currentTime, duration: 1000, progress: currentTime / 1000))
    }

    // MARK: - CRUD and uniqueness

    @Test func recordEditCreatesSeededRowAndUpdatesInPlace() async throws {
        let (store, container) = try makeStore()
        let item = UUID()
        let created = try await store.recordEdit(
            Self.seek(200), for: key, serverProgress: Self.server(lastUpdate: Self.t0), localLibraryItemID: item,
            now: Self.at(10))
        #expect(created.key == key)
        #expect(created.localLibraryItemID == item)
        #expect(created.startedAt == Self.at(10))
        #expect(created.serverBaseline == Self.server(lastUpdate: Self.t0))
        #expect(created.dirtyGroups == .audio)
        #expect(created.needsServerSync)

        let updated = try await store.recordEdit(Self.seek(250), for: key, now: Self.at(20))
        #expect(updated.currentTime == 250)
        #expect(updated.localLibraryItemID == item)
        #expect(updated.startedAt == Self.at(10))
        #expect(try await store.progress(for: key) == updated)
        #expect(try await store.progress(localLibraryItemID: item) == [updated])
        #expect(try ModelContext(container).fetchCount(FetchDescriptor<LocalMediaProgress>()) == 1)
    }

    @Test func ebookOnlySaveCarriesNoAudioFields() async throws {
        let (store, _) = try makeStore()
        try await store.recordEdit(
            ProgressEdit(ebook: .init(location: "epubcfi(/6/4)", progress: 0.3)), for: key,
            serverProgress: Self.server(lastUpdate: Self.t0), now: Self.at(5))
        let pending = try await store.pendingSync(for: Fixtures.connectionID)
        #expect(pending.count == 1)
        #expect(pending[0].audioDirty == false)
        #expect(pending[0].finishedDirty == false)
        #expect(pending[0].dirtyValues.audio == nil)
        #expect(pending[0].dirtyValues.finished == nil)

        let patch = try #require(try await store.beginSend(for: key))
        #expect(patch.values.groups == .ebook)
        #expect(patch.values.ebook?.ebookLocation == "epubcfi(/6/4)")
    }

    @Test func pendingSyncIsPerConnectionAndPruneKeepsDirtyAndLinkedRows() async throws {
        let (store, _) = try makeStore()
        let other = MediaKey(serverConnectionID: UUID(), libraryItemId: "li_1")
        let synced = MediaKey(serverConnectionID: Fixtures.connectionID, libraryItemId: "li_2")
        let linked = MediaKey(serverConnectionID: Fixtures.connectionID, libraryItemId: "li_3")
        try await store.recordEdit(Self.seek(1), for: key, now: Self.at(1))
        try await store.recordEdit(Self.seek(1), for: other, now: Self.at(1))
        for clean in [synced, linked] {
            try await store.recordEdit(Self.seek(1), for: clean, now: Self.at(1))
            let patch = try #require(try await store.beginSend(for: clean))
            try await store.completeSend(patch, serverLastUpdate: Self.at(2))
        }
        #expect(try await store.setLocalLibraryItemID(UUID(), for: linked))

        #expect(try await store.pendingSync(for: Fixtures.connectionID).map(\.key) == [key])
        #expect(try await store.pruneSynced() == 1)
        #expect(try await store.progress(for: synced) == nil)
        #expect(try await store.progress(for: linked) != nil)
        #expect(try await store.deleteProgress(for: key))
        #expect(try await store.deleteProgress(for: key) == false)
        #expect(try await store.setLocalLibraryItemID(nil, for: key) == false)
    }

    // MARK: - Sends

    @Test func onePatchInFlightPerRow() async throws {
        let (store, _) = try makeStore()
        try await store.recordEdit(Self.seek(200), for: key, now: Self.at(1))
        let first = try #require(try await store.beginSend(for: key, now: Self.at(2)))
        #expect(try await store.beginSend(for: key) == nil)
        try await store.failSend(first, error: "offline")
        let row = try #require(try await store.progress(for: key))
        #expect(row.lastSyncError == "offline")
        #expect(row.lastSyncAttemptAt == Self.at(2))
        #expect(row.unacknowledgedSends == [first.values])
        #expect(row.needsServerSync)
        #expect(try await store.beginSend(for: key) != nil)
        #expect(try await store.beginSend(for: MediaKey(serverConnectionID: UUID(), libraryItemId: "none")) == nil)
    }

    @Test func editDuringPatchAdvancesBaselineAndSurvivesNextFetch() async throws {
        let (store, _) = try makeStore()
        try await store.recordEdit(
            Self.seek(200), for: key, serverProgress: Self.server(lastUpdate: Self.t0), now: Self.at(1))
        let patch = try #require(try await store.beginSend(for: key))
        try await store.recordEdit(Self.seek(300), for: key, now: Self.at(2))
        try await store.completeSend(patch, serverLastUpdate: Self.at(3))

        let acked = try #require(try await store.progress(for: key))
        #expect(acked.serverBaseline?.currentTime == 200)
        #expect(acked.currentTime == 300)
        #expect(acked.audioDirty)
        #expect(acked.unacknowledgedSends.isEmpty)

        let capture = await store.captureGeneration()
        try await store.applyServerProgress(
            [key: Self.server(currentTime: 200, lastUpdate: Self.at(3))], capturedAt: capture)
        let fetched = try #require(try await store.progress(for: key))
        #expect(fetched.currentTime == 300)
        #expect(fetched.audioDirty)
    }

    // MARK: - Stale and in-flight server values

    @Test func fetchIssuedBeforeLocalSeekChangesNothing() async throws {
        let (store, _) = try makeStore()
        try await store.recordEdit(
            Self.seek(200), for: key, serverProgress: Self.server(lastUpdate: Self.t0), now: Self.at(1))
        let capture = await store.captureGeneration()
        try await store.recordEdit(Self.seek(300), for: key, now: Self.at(2))
        let before = try await store.progress(for: key)
        let merged = try await store.applyServerProgress(
            [key: Self.server(currentTime: 900, lastUpdate: Self.at(50))], capturedAt: capture)
        #expect(merged.isEmpty)
        #expect(try await store.progress(for: key) == before)
    }

    @Test func fetchIssuedBeforePatchSettlesChangesNothing() async throws {
        let (store, _) = try makeStore()
        try await store.recordEdit(
            Self.seek(200), for: key, serverProgress: Self.server(lastUpdate: Self.t0), now: Self.at(1))
        let patch = try #require(try await store.beginSend(for: key))
        let capture = await store.captureGeneration()
        try await store.failSend(patch, error: nil)
        let before = try await store.progress(for: key)
        #expect(
            try await store.applyServerProgress(
                [key: Self.server(currentTime: 900, lastUpdate: Self.at(50))], capturedAt: capture
            )
            .isEmpty)
        #expect(try await store.progress(for: key) == before)
    }

    @Test(arguments: [true, false])
    func echoOfInFlightPatchAfterNewerSeekIsDeferred(_ succeeds: Bool) async throws {
        let (store, _) = try makeStore()
        try await store.recordEdit(
            Self.seek(200), for: key, serverProgress: Self.server(lastUpdate: Self.t0), now: Self.at(1))
        let patch = try #require(try await store.beginSend(for: key))
        try await store.recordEdit(Self.seek(300), for: key, now: Self.at(2))
        // A socket echo of the PATCH (newer `lastUpdate`, older values) received after the seek.
        let capture = await store.captureGeneration()
        try await store.applyServerProgress(
            [key: Self.server(currentTime: 200, lastUpdate: Self.at(5))], capturedAt: capture)
        var row = try #require(try await store.progress(for: key))
        #expect(row.currentTime == 300)
        #expect(row.audioDirty)
        #expect(row.serverBaseline?.currentTime == 100)

        if succeeds {
            try await store.completeSend(patch, serverLastUpdate: Self.at(5))
        } else {
            try await store.failSend(patch, error: "lost")
        }
        row = try #require(try await store.progress(for: key))
        #expect(row.currentTime == 300)
        #expect(row.audioDirty)
        #expect(try await store.beginSend(for: key)?.values.audio?.currentTime == 300)
    }

    @Test func lostResponseIsRecognisedAfterRelaunch() async throws {
        let (store, container) = try makeStore()
        try await store.recordEdit(
            Self.seek(200), for: key, serverProgress: Self.server(lastUpdate: Self.t0), now: Self.at(1))
        let patchA = try #require(try await store.beginSend(for: key))
        try await store.recordEdit(Self.seek(300), for: key, now: Self.at(2))
        try await store.failSend(patchA, error: "timed out")  // A committed; its response was lost.
        let patchB = try #require(try await store.beginSend(for: key))
        try await store.failSend(patchB, error: "offline")  // B never reached the server.

        // A new process: in-memory generations are gone, the send history is persisted.
        let relaunched = LocalProgressStore(modelContainer: container)
        let capture = await relaunched.captureGeneration()
        try await relaunched.applyServerProgress(
            [key: Self.server(currentTime: 200, lastUpdate: Self.at(3))], capturedAt: capture)
        let row = try #require(try await relaunched.progress(for: key))
        #expect(row.currentTime == 300)
        #expect(row.audioDirty)
        #expect(row.unacknowledgedSends == [patchB.values])
        #expect(try await relaunched.beginSend(for: key)?.values.audio?.currentTime == 300)
    }

    @Test func serverProgressForUnknownMediaIsIgnored() async throws {
        let (store, _) = try makeStore()
        let capture = await store.captureGeneration()
        #expect(
            try await store.applyServerProgress([key: Self.server(lastUpdate: Self.t0)], capturedAt: capture).isEmpty)
        #expect(try await store.progress(for: key) == nil)
    }

    // MARK: - Connections

    @Test func removedConnectionKeepsProgressForTheNextLogin() async throws {
        let (store, container) = try makeStore()
        let connections = ServerConnectionStore(modelContainer: container)
        let address = try #require(ServerAddress("https://abs.example.com"))
        let connection = try await connections.upsertLogin(
            address: address, userId: "usr_1", username: "reader", authMethod: .local, serverVersion: nil)
        let progressKey = MediaKey(serverConnectionID: connection.id, libraryItemId: "li_1")
        try await store.recordEdit(Self.seek(42), for: progressKey)

        #expect(try await connections.remove(id: connection.id) == .disconnected)
        let again = try await connections.upsertLogin(
            address: address, userId: "usr_1", username: "reader", authMethod: .local, serverVersion: nil)
        #expect(again.id == connection.id)
        #expect(try await store.pendingSync(for: again.id).map(\.key) == [progressKey])
    }

    // MARK: - Pending sessions

    private func session(_ id: String, startedAt: Date, updatedAt: Date, isActive: Bool = false)
        -> PendingLocalSessionDTO
    {
        PendingLocalSessionDTO(
            id: id, key: key, userId: "usr_1", mediaType: .book, displayTitle: "The Book", duration: 1000,
            startTime: 10, startedAt: startedAt, updatedAt: updatedAt, timeListening: 30, currentTime: 40,
            isActive: isActive)
    }

    @Test func savesReadsAndDeletesSessions() async throws {
        let (store, container) = try makeStore()
        let later = session("b", startedAt: Self.at(10), updatedAt: Self.at(10))
        var earlier = session("a", startedAt: Self.at(1), updatedAt: Self.at(1))
        try await store.saveSession(later)
        try await store.saveSession(earlier)
        earlier.currentTime = 90
        earlier.updatedAt = Self.at(2)
        try await store.saveSession(earlier)

        #expect(try await store.session(id: "a") == earlier)
        #expect(try await store.pendingSessions(for: Fixtures.connectionID) == [earlier, later])
        #expect(try await store.pendingSessions(for: UUID()).isEmpty)
        #expect(try ModelContext(container).fetchCount(FetchDescriptor<PendingLocalSession>()) == 2)
        #expect(try await store.deleteSession(id: "a"))
        #expect(try await store.deleteSession(id: "a") == false)
    }

    @Test func settlesUploadPerSessionResult() async throws {
        let (store, _) = try makeStore()
        let done = session("done", startedAt: Self.at(1), updatedAt: Self.at(1))
        let changed = session("changed", startedAt: Self.at(2), updatedAt: Self.at(2))
        let active = session("active", startedAt: Self.at(3), updatedAt: Self.at(3), isActive: true)
        let failed = session("failed", startedAt: Self.at(4), updatedAt: Self.at(4))
        let missing = session("missing", startedAt: Self.at(5), updatedAt: Self.at(5))
        for item in [done, changed, active, failed, missing] {
            try await store.saveSession(item)
        }
        var sent = Dictionary(
            uniqueKeysWithValues: [done, changed, active, failed, missing].map { ($0.id, $0.updatedAt) })
        // Changed while the upload was in flight.
        var newer = changed
        newer.updatedAt = Self.at(20)
        try await store.saveSession(newer)

        let results: [String: SessionUploadResult] = [
            "done": .success, "changed": .success, "active": .success, "failed": .failure("Media item not found"),
        ]
        let deleted = try await store.settleSessionUpload(sent: sent, results: results, isFirstSync: false)
        #expect(deleted == ["done"])
        let failedRow = try #require(try await store.session(id: "failed"))
        #expect(failedRow.uploadAttempts == 1)
        #expect(failedRow.lastUploadError == "Media item not found")
        #expect(try await store.session(id: "missing")?.uploadAttempts == 0)

        // The first sync after login also deletes acknowledged active sessions.
        sent["changed"] = Self.at(20)
        let firstSync = try await store.settleSessionUpload(sent: sent, results: results, isFirstSync: true)
        #expect(firstSync == ["changed", "active"])

        // Two failures so far; discarded after the fifth.
        #expect(try await store.session(id: "failed")?.uploadAttempts == 2)
        for _ in 3..<LocalProgressStore.maxUploadFailures {
            try await store.settleSessionUpload(sent: sent, results: results, isFirstSync: false)
        }
        #expect(try await store.session(id: "failed")?.uploadAttempts == 4)
        #expect(try await store.settleSessionUpload(sent: sent, results: results, isFirstSync: false) == ["failed"])
        #expect(try await store.pendingSessions(for: Fixtures.connectionID).map(\.id) == ["missing"])
    }
}
