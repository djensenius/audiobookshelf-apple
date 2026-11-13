import ABSAPI
import Foundation
import Testing

@testable import ABSDownloads

/// Activation deletes resume data no download record references (#515).
@Suite(.timeLimit(.minutes(1))) struct ResumeDataSweepTests {
    /// A cancel whose resume-data delete failed still removes the record, leaving the blob with no
    /// part to find it; the next activation deletes it.
    @Test func activationDeletesABlobACancelLeftBehind() async throws {
        let gate = StubGate()
        let harness = try await DownloadHarness { request in
            request.url?.path().contains("/file/2/") == true
                ? .failure(resumeData: Data("resume".utf8), gate: gate) : .status(200)
        }
        let partIDs = [UUID(), UUID()]
        let record = try await harness.addRecord(parts: partIDs)
        let engine = harness.makeEngine(retryPolicy: RetryPolicy(baseDelay: .zero, maxDelay: .zero, maxRetries: 0))
        await engine.start(partIDs: partIDs)
        #expect(await engine.next { if case .partCompleted(partIDs[0], _) = $0 { true } else { false } } != nil)
        gate.open()
        #expect(await engine.nextPermanentFailure() != nil)
        let blob = harness.vault.fileURL(partID: partIDs[1]).path(percentEncoded: false)
        try #require(FileManager.default.fileExists(atPath: blob))
        let manager = DownloadManager(
            store: harness.store, localItems: harness.localItems, engine: engine, locations: harness.locations,
            capacity: FakeCapacity(), clock: harness.clock)

        // A read-only folder: the blob can't be deleted.
        let folder = harness.locations.resumeDataRoot.path(percentEncoded: false)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder) }
        #expect(try await manager.cancel(recordID: record.id))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder)
        try #require(try await harness.store.record(id: record.id) == nil)
        try #require(FileManager.default.fileExists(atPath: blob))

        #expect(await harness.makeEngine().activate())

        #expect(!FileManager.default.fileExists(atPath: blob))
    }

    /// Blobs of parts a record still has stay; only the unreferenced one goes. The record is
    /// paused, so activation restarts nothing that would use or replace its blobs.
    @Test func activationKeepsBlobsOfRecordedParts() async throws {
        let harness = try await DownloadHarness { _ in .status(200) }
        let kept = [UUID(), UUID()]
        let orphan = UUID()
        _ = try await harness.addRecord(parts: kept, state: .paused)
        for partID in kept + [orphan] {
            try harness.vault.seal(Data("resume".utf8), partID: partID, credentialTag: Data("tag".utf8))
        }
        let exists = { (partID: UUID) in
            FileManager.default.fileExists(atPath: harness.vault.fileURL(partID: partID).path(percentEncoded: false))
        }

        #expect(await harness.makeEngine().activate())

        #expect(kept.allSatisfy(exists))
        #expect(!exists(orphan))
    }

    /// A fallback store (not the App Group's) doesn't list the downloads the resume data belongs
    /// to, so an engine told not to sweep keeps every blob, even with no record at all.
    @Test func anEngineOnAFallbackStoreDeletesNoBlob() async throws {
        let harness = try await DownloadHarness { _ in .status(200) }
        let partIDs = [UUID(), UUID()]
        for partID in partIDs {
            try harness.vault.seal(Data("resume".utf8), partID: partID, credentialTag: Data("tag".utf8))
        }

        #expect(await harness.makeEngine(sweepsOrphanedResumeData: false).activate())

        #expect(
            partIDs.allSatisfy {
                FileManager.default.fileExists(atPath: harness.vault.fileURL(partID: $0).path(percentEncoded: false))
            })
    }

    /// The session outlives a failed sweep, so the same engine's next activation sweeps again.
    @Test func aFailedSweepIsRetriedOnTheNextActivation() async throws {
        let harness = try await DownloadHarness { _ in .status(200) }
        let orphan = UUID()
        try harness.vault.seal(Data("resume".utf8), partID: orphan, credentialTag: Data("tag".utf8))
        let blob = harness.vault.fileURL(partID: orphan).path(percentEncoded: false)
        let folder = harness.locations.resumeDataRoot.path(percentEncoded: false)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder) }
        let engine = harness.makeEngine()

        #expect(await engine.activate())
        try #require(FileManager.default.fileExists(atPath: blob))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder)
        await engine.deactivate()
        #expect(await engine.activate())

        #expect(!FileManager.default.fileExists(atPath: blob))
    }

    /// Only `<part id>.bin` files are swept, and a missing folder is nothing to do.
    @Test func theSweepLeavesOtherFilesAndAMissingFolder() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "sweep-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let vault = ResumeDataVault(directory: directory, keyStore: MemoryKeyStore())
        #expect(vault.deleteBlobs(except: []))

        let kept = UUID()
        let orphan = UUID()
        try vault.seal(Data("a".utf8), partID: kept, credentialTag: Data())
        try vault.seal(Data("b".utf8), partID: orphan, credentialTag: Data())
        let other = directory.appending(path: "notes.bin")
        try Data("x".utf8).write(to: other)

        #expect(vault.deleteBlobs(except: [kept]))

        #expect(FileManager.default.fileExists(atPath: vault.fileURL(partID: kept).path(percentEncoded: false)))
        #expect(!FileManager.default.fileExists(atPath: vault.fileURL(partID: orphan).path(percentEncoded: false)))
        #expect(FileManager.default.fileExists(atPath: other.path(percentEncoded: false)))
    }
}
