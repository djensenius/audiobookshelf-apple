import ABSCore
import Foundation
import Testing

@testable import ABSData

@Suite struct StartProgressStoreTests {
    private let key = MediaKey(serverConnectionID: UUID(), libraryItemId: "a", episodeId: "episode")
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func store() throws -> LocalProgressStore {
        try LocalProgressStore(modelContainer: DataStack(location: .inMemory).container)
    }

    private func server(_ time: Double = 800, seconds: Double = 30) -> MediaProgress {
        MediaProgress(
            id: "p", libraryItemId: key.libraryItemId, episodeId: key.episodeId,
            duration: 3600, progress: time / 3600, currentTime: time,
            ebookLocation: "server-page", ebookProgress: 0.4,
            lastUpdate: Int(t0.addingTimeInterval(seconds).timeIntervalSince1970 * 1000))
    }

    private func edit(_ time: Double = 200) -> ProgressEdit {
        ProgressEdit(audio: .init(currentTime: time, duration: 3600, progress: time / 3600))
    }

    @Test(arguments: ["edit", "ack", "datedAck"])
    func mutationAfterCaptureRejectsEvenANewerServerDate(kind: String) async throws {
        let store = try store()
        try await store.recordEdit(edit(), for: key, now: t0)
        let patch = try #require(try await store.beginSend(for: key))
        let capture = try await store.captureStartProgress(for: key)
        if kind == "edit" {
            try await store.recordEdit(edit(300), for: key, now: t0.addingTimeInterval(1))
        } else {
            try await store.completeSend(patch, serverLastUpdate: kind == "datedAck" ? t0 : nil)
        }
        let before = try await store.progress(for: key)
        #expect(try await store.applyStartProgress(server(), captured: capture) == false)
        #expect(try await store.progress(for: key) == before)
        #expect(await store.captureProgressFetch(for: key).acknowledgement == (kind == "ack" ? patch.token : nil))
    }

    @Test(arguments: ["delete", "replace", "missingABA", "prune"])
    func deletedIncarnationsCannotBeResurrected(kind: String) async throws {
        let store = try store()
        if kind != "missingABA" {
            let seed = try await store.captureStartProgress(for: key)
            #expect(try await store.applyStartProgress(server(), captured: seed))
        }
        let capture = try await store.captureStartProgress(for: key)
        if kind == "missingABA" { try await store.recordEdit(edit(), for: key, now: t0) }
        if kind == "prune" {
            #expect(try await store.pruneSynced() == 1)
        } else {
            #expect(try await store.deleteProgress(for: key))
        }
        if kind == "replace" { try await store.recordEdit(edit(300), for: key, now: t0) }
        let before = try await store.progress(for: key)
        #expect(try await store.applyStartProgress(server(), captured: capture) == false)
        #expect(try await store.progress(for: key) == before)
        #expect(await store.needsConfirmationFetch.isEmpty)
    }

    @Test func unrelatedDeletionDoesNotInvalidateCaptureAndOtherStoreCannotConsumeIt() async throws {
        let store = try store()
        let otherStore = try self.store()
        let capture = try await store.captureStartProgress(for: key)
        for other in [
            MediaKey(serverConnectionID: UUID(), libraryItemId: "a", episodeId: "episode"),
            MediaKey(serverConnectionID: key.serverConnectionID, libraryItemId: "a", episodeId: "other"),
        ] {
            try await store.recordEdit(edit(), for: other, now: t0)
            try await store.deleteProgress(for: other)
        }
        #expect(try await otherStore.applyStartProgress(server(), captured: capture) == false)
        #expect(try await store.applyStartProgress(server(), captured: capture))
        #expect(try await store.applyStartProgress(server(900), captured: capture) == false)
        #expect(try await store.progress(for: key)?.currentTime == 800)
        #expect(try await otherStore.progress(for: key) == nil)
    }

    @Test(arguments: ["undated", "item", "episode"])
    func invalidCanonicalInputDoesNotCreateRows(kind: String) async throws {
        let store = try store()
        let capture = try await store.captureStartProgress(for: key)
        var response = server()
        if kind == "undated" { response.lastUpdate = nil }
        if kind == "item" { response.libraryItemId = "wrong" }
        if kind == "episode" { response.episodeId = nil }
        #expect(try await store.applyStartProgress(response, captured: capture) == false)
        #expect(try await store.progress(for: key) == nil)
        #expect(await store.needsConfirmationFetch.isEmpty)
    }

    @Test(arguments: [false, true], ["read", "save"])
    func intakeFailureRollsBackWithoutAcknowledgement(existing: Bool, failure: String) async throws {
        let store = try store()
        if existing {
            try await store.recordEdit(edit(), for: key, now: t0)
            let patch = try #require(try await store.beginSend(for: key))
            try await store.completeSend(patch, serverLastUpdate: nil)
        }
        let before = try await store.progress(for: key)
        let acknowledgement = await store.captureProgressFetch(for: key).acknowledgement
        let capture = try await store.captureStartProgress(for: key)
        if failure == "read" {
            await store.failNextRowFetch(with: CocoaError(.fileReadNoPermission))
        } else {
            await store.failNextCommit(with: CocoaError(.fileWriteNoPermission))
        }
        await #expect(throws: CocoaError.self) {
            try await store.applyStartProgress(server(), captured: capture)
        }
        #expect(try await store.progress(for: key) == before)
        #expect(await store.captureProgressFetch(for: key).acknowledgement == acknowledgement)
        #expect(try await store.applyStartProgress(server(), captured: capture) == false, "No retry of consumed intake")
    }

    @Test func captureReadFailureIsNotAbsenceAndFailedDeletionDoesNotInvalidate() async throws {
        let store = try store()
        await store.failNextRowFetch(with: CocoaError(.fileReadNoPermission))
        await #expect(throws: CocoaError.self) { try await store.captureStartProgress(for: key) }
        try await store.recordEdit(edit(), for: key, now: t0)
        let capture = try await store.captureStartProgress(for: key)
        await store.failNextCommit(with: CocoaError(.fileWriteNoPermission))
        await #expect(throws: CocoaError.self) { try await store.deleteProgress(for: key) }
        #expect(try await store.applyStartProgress(server(), captured: capture))
        #expect(try await store.progress(for: key)?.currentTime == 800)
    }

    @Test(arguments: ["newerServer", "newerLocal", "equal", "unchangedAudio"])
    func existingRowsUseFetchConflictRulesAndKeepIndependentIntent(kind: String) async throws {
        let store = try store()
        let seed = try await store.captureStartProgress(for: key)
        #expect(try await store.applyStartProgress(server(100, seconds: -10), captured: seed))
        try await store.recordEdit(edit(), for: key, now: t0)
        try await store.recordEdit(
            ProgressEdit(isFinished: true, ebook: .init(location: "local-page", progress: 0.8)),
            for: key, now: t0.addingTimeInterval(100))
        let capture = try await store.captureStartProgress(for: key)
        let seconds: Double = kind == "newerLocal" ? -1 : kind == "equal" ? 0 : 30
        #expect(
            try await store.applyStartProgress(
                server(kind == "unchangedAudio" ? 100 : 800, seconds: seconds), captured: capture))
        let row = try #require(try await store.progress(for: key))
        let localAudio = kind == "newerLocal" || kind == "unchangedAudio"
        #expect(row.currentTime == (localAudio ? 200 : 800))
        #expect(row.audioDirty == localAudio)
        #expect(row.finishedDirty && row.isFinished)
        #expect(row.ebookDirty && row.ebookLocation == "local-page")
        #expect(row.serverBaseline?.ebookLocation == "server-page")
        #expect(await store.needsConfirmationFetch.isEmpty)
    }

    @Test func preexistingAcknowledgementIsConfirmedButObsoleteSettlementIsNotAnAcknowledgement() async throws {
        let store = try store()
        try await store.recordEdit(edit(), for: key, now: t0)
        let patch = try #require(try await store.beginSend(for: key))
        try await store.deleteProgress(for: key)
        #expect(try await store.completeSend(patch, serverLastUpdate: nil))
        #expect(await store.needsConfirmationFetch.isEmpty, "Recognized obsolete settlement isn't a current-row ACK")
        let seed = try await store.captureStartProgress(for: key)
        #expect(try await store.applyStartProgress(server(), captured: seed))
        try await store.recordEdit(edit(900), for: key, now: t0.addingTimeInterval(40))
        let current = try #require(try await store.beginSend(for: key))
        try await store.completeSend(current, serverLastUpdate: nil)
        let capture = try await store.captureStartProgress(for: key)
        #expect(try await store.applyStartProgress(server(900, seconds: 50), captured: capture))
        #expect(await store.needsConfirmationFetch.isEmpty)
        #expect(try await store.progress(for: key)?.serverBaseline?.lastUpdate == t0.addingTimeInterval(50))
    }
}
