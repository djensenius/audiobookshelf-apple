import ABSCore
import Foundation
import Observation
import Testing

@testable import ABSAppModel

@MainActor
private final class FakeReloader: WidgetTimelineReloading {
    private(set) var kinds: [String] = []

    func reloadTimelines(ofKind kind: String) {
        kinds.append(kind)
    }
}

/// A clock the test moves by hand.
@MainActor
private final class FakeClock {
    var now = Date(timeIntervalSince1970: 1_000_000)

    func advance(by seconds: TimeInterval) {
        now += seconds
    }
}

@MainActor
@Observable
private final class FakeConnections {
    var saved: Set<UUID> = []
}

@MainActor
@Observable
private final class FakeGate {
    var gate = AuthGate.launching
}

/// The writer's trailing-write timer: it waits until the test wakes it, or it's cancelled.
@MainActor
private final class FakeSleeper {
    private(set) var waits: [TimeInterval] = []
    private var sleepers: [UUID: CheckedContinuation<Void, any Error>] = [:]
    var sleeping: Int { sleepers.count }

    func sleep(_ seconds: TimeInterval) async throws {
        let id = UUID()
        waits.append(seconds)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { sleepers[id] = $0 }
        } onCancel: {
            Task { @MainActor in self.sleepers.removeValue(forKey: id)?.resume(throwing: CancellationError()) }
        }
    }

    func wake() {
        let woken = sleepers
        sleepers = [:]
        for sleeper in woken.values { sleeper.resume() }
    }
}

private let serverA = UUID(uuidString: "0A0A0A0A-0000-4000-8000-000000000001")!
private let serverB = UUID(uuidString: "0B0B0B0B-0000-4000-8000-000000000002")!

private func snapshot(
    server: UUID = serverA, item: String = "li_1", at time: Double = 10, playing: Bool = true,
    chapter: String? = "One"
) -> WidgetSnapshot {
    WidgetSnapshot(
        serverID: server, itemID: item, title: "Dune", author: "Frank Herbert", chapterTitle: chapter,
        currentTime: time, duration: 400, isPlaying: playing,
        cover: CoverLocator(
            ImageKey(serverID: server, kind: .itemCover, entityID: item, updatedAt: 7, bucket: .small)))
}

private func context(_ server: UUID) -> SessionContext {
    SessionContext(
        identity: SessionIdentity(connectionID: server, userID: "u1"), client: nil, isOffline: false, sessionID: 1)
}

@MainActor
@Suite struct WidgetSnapshotWriterTests {
    private let directory: URL
    private let file: URL
    private let reloader = FakeReloader()
    private let clock = FakeClock()
    private let sleeper = FakeSleeper()

    init() throws {
        directory = FileManager.default.temporaryDirectory.appending(path: "WidgetSnapshotWriterTests-\(UUID())")
        file = directory.appending(path: "Widgets/continue-listening.json")
    }

    private func writer(server: UUID? = serverA) async -> WidgetSnapshotWriter {
        let clock = self.clock
        let sleeper = self.sleeper
        let writer = WidgetSnapshotWriter(
            fileURL: file, reloader: reloader, now: { clock.now }, sleep: { try await sleeper.sleep($0) })
        if let server { await writer.sessionDidStart(context(server)) }
        return writer
    }

    private var onDisk: WidgetSnapshot? { WidgetSnapshot.read(from: file) }

    // MARK: Encoding

    @Test func writesTheSnapshotWithoutTokensAndReloadsTheWidget() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let writer = await writer()

        writer.update(snapshot())

        #expect(onDisk == snapshot())
        #expect(reloader.kinds == [WidgetSnapshot.continueListeningKind])
        let json = try #require(
            try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        #expect(
            Set(json.keys) == [
                "serverID", "itemID", "title", "author", "chapterTitle", "currentTime", "duration", "isPlaying",
                "cover",
            ])
        let text = try String(contentsOf: file, encoding: .utf8).lowercased()
        #expect(!text.contains("token"))
    }

    @Test func aSignedExternalCoverURLIsNotWritten() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let writer = await writer()
        let key = ImageKey(
            serverID: serverA, kind: .itemCover, entityID: "li_1", updatedAt: 7, bucket: .small,
            externalURL: URL(string: "https://covers.example/image.jpg?token=secret"))
        var signed = snapshot()
        signed.cover = CoverLocator(key)

        writer.update(signed)

        let text = try String(contentsOf: file, encoding: .utf8).lowercased()
        for leak in ["token", "secret", "covers.example", "image.jpg", "http"] {
            #expect(!text.contains(leak), "\(leak)")
        }
        #expect(onDisk?.cover == CoverLocator(key))
        // The digest still tells it from the server route's cover of the same item.
        var route = key
        route.externalURL = nil
        #expect(onDisk?.cover != CoverLocator(route))
    }

    @Test func deepLinkOpensTheItemOnItsServer() throws {
        var podcast = snapshot(item: "li/1+a&b%")
        podcast.episodeID = "ep 1+2"
        let url = try #require(podcast.deepLinkURL)

        #expect(
            DeepLink(url: url) == DeepLink(.item(id: "li/1+a&b%", episodeID: "ep 1+2"), serverID: serverA.uuidString))
        #expect(
            DeepLink(url: try #require(snapshot().deepLinkURL))
                == DeepLink(.item(id: "li_1", episodeID: nil), serverID: serverA.uuidString))
    }

    // MARK: Throttling

    @Test func positionTicksWaitForTheMinimumInterval() async {
        defer { try? FileManager.default.removeItem(at: directory) }
        let writer = await writer()
        writer.update(snapshot(at: 10))

        clock.advance(by: 299)
        writer.update(snapshot(at: 309))
        #expect(onDisk?.currentTime == 10)
        #expect(reloader.kinds.count == 1)

        clock.advance(by: 1)
        writer.update(snapshot(at: 310))
        #expect(onDisk?.currentTime == 310)
        #expect(reloader.kinds.count == 2)
    }

    @Test func aThrottledPositionIsWrittenOnceTheIntervalPasses() async {
        defer { try? FileManager.default.removeItem(at: directory) }
        let writer = await writer()
        writer.update(snapshot(at: 10))
        clock.advance(by: 1)
        writer.update(snapshot(at: 11, playing: false))

        // A seek while paused: nothing follows it, so it's written when the interval passes.
        clock.advance(by: 5)
        writer.update(snapshot(at: 200, playing: false))
        #expect(onDisk?.currentTime == 11)
        #expect(await eventually { sleeper.sleeping == 1 })
        #expect(sleeper.waits == [295])

        clock.advance(by: 295)
        sleeper.wake()
        #expect(await eventually { onDisk?.currentTime == 200 })
        #expect(reloader.kinds.count == 3)
    }

    @Test func aThrottledPositionIsDroppedWhenSupersededOrCleared() async {
        defer { try? FileManager.default.removeItem(at: directory) }
        let writer = await writer()
        writer.update(snapshot(at: 10, playing: false))

        // Seeking back to the written position cancels the pending one.
        clock.advance(by: 5)
        writer.update(snapshot(at: 200, playing: false))
        #expect(await eventually { sleeper.sleeping == 1 })
        writer.update(snapshot(at: 10, playing: false))
        #expect(await eventually { sleeper.sleeping == 0 })
        #expect(onDisk?.currentTime == 10)

        // Signing out cancels it too, so it can't bring the snapshot back.
        writer.update(snapshot(at: 300, playing: false))
        #expect(await eventually { sleeper.sleeping == 1 })
        await writer.sessionWillEnd(.signOut)
        #expect(await eventually { sleeper.sleeping == 0 })
        #expect(onDisk == nil)
        #expect(reloader.kinds.count == 2)
    }

    @Test func playPauseChapterAndItemChangesWriteAtOnce() async {
        defer { try? FileManager.default.removeItem(at: directory) }
        let writer = await writer()
        writer.update(snapshot(at: 10))

        clock.advance(by: 1)
        writer.update(snapshot(at: 11, playing: false))
        #expect(onDisk == snapshot(at: 11, playing: false))
        writer.update(snapshot(at: 12, playing: false, chapter: "Two"))
        #expect(onDisk == snapshot(at: 12, playing: false, chapter: "Two"))
        writer.update(snapshot(item: "li_2", at: 13, playing: false, chapter: "Two"))
        #expect(onDisk?.itemID == "li_2")
        #expect(reloader.kinds.count == 4)
    }

    @Test func anUnchangedSnapshotOrNoItemWritesNothing() async {
        defer { try? FileManager.default.removeItem(at: directory) }
        let writer = await writer()
        writer.update(snapshot())

        clock.advance(by: 1_000)
        writer.update(snapshot())
        writer.update(nil)

        #expect(onDisk == snapshot())
        #expect(reloader.kinds.count == 1)
    }

    // MARK: Clearing

    @Test(arguments: [SessionEndReason.signOut, .removed, .expired])
    func signingOutClearsTheSnapshot(reason: SessionEndReason) async {
        defer { try? FileManager.default.removeItem(at: directory) }
        let writer = await writer()
        writer.update(snapshot())

        await writer.sessionWillEnd(reason)

        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(reloader.kinds.count == 2)
        // A late tick from the ended session doesn't bring it back.
        clock.advance(by: 1_000)
        writer.update(snapshot(at: 20, playing: false))
        #expect(onDisk == nil)
    }

    @Test func switchingAccountsKeepsTheSnapshot() async {
        defer { try? FileManager.default.removeItem(at: directory) }
        let writer = await writer()
        writer.update(snapshot())

        await writer.sessionWillEnd(.switch)
        await writer.sessionDidStart(context(serverB))

        #expect(onDisk == snapshot())
        #expect(reloader.kinds.count == 1)
    }

    @Test func snapshotsForAnotherConnectionThanTheSessionsAreIgnored() async {
        defer { try? FileManager.default.removeItem(at: directory) }
        let writer = await writer(server: serverB)

        writer.update(snapshot(server: serverA))

        #expect(onDisk == nil)
        #expect(reloader.kinds.isEmpty)
    }

    @Test func removingTheSnapshotsConnectionClearsIt() async {
        defer { try? FileManager.default.removeItem(at: directory) }
        let connections = FakeConnections()
        let writer = await writer()
        writer.update(snapshot())
        await writer.sessionWillEnd(.switch)
        await writer.sessionDidStart(context(serverB))
        writer.followRemovals { connections.saved }

        // The list loading (empty until then, at launch) and another connection's removal keep it.
        for _ in 0..<100 { await Task.yield() }
        #expect(onDisk == snapshot())
        connections.saved = [serverA, serverB]
        for _ in 0..<100 { await Task.yield() }
        connections.saved = [serverA]
        for _ in 0..<100 { await Task.yield() }
        #expect(onDisk == snapshot())

        connections.saved = []
        #expect(await eventually { reloader.kinds.count == 2 })
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test func aRestoreThatEndsSignedOutAtLaunchClearsTheSnapshot() async {
        defer { try? FileManager.default.removeItem(at: directory) }
        await writer().update(snapshot())
        let launch = FakeGate()
        let relaunched = await writer(server: nil)
        relaunched.followLaunch { launch.gate }

        launch.gate = .connect

        #expect(await eventually { reloader.kinds.count == 2 })
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test func aRestoredSessionAtLaunchKeepsTheSnapshot() async {
        defer { try? FileManager.default.removeItem(at: directory) }
        await writer().update(snapshot())
        let launch = FakeGate()
        let relaunched = await writer(server: nil)
        relaunched.followLaunch { launch.gate }

        launch.gate = .ready(SessionIdentity(connectionID: serverA, userID: "u1"), isOffline: false)
        for _ in 0..<100 { await Task.yield() }
        // Only the launch counts: a later sign-out clears it as a session's end.
        launch.gate = .connect
        for _ in 0..<100 { await Task.yield() }

        #expect(onDisk == snapshot())
        #expect(reloader.kinds.count == 1)
    }

    @Test func aRelaunchedWriterKnowsTheSnapshotOnDisk() async {
        defer { try? FileManager.default.removeItem(at: directory) }
        await writer().update(snapshot())

        let relaunched = await writer()
        relaunched.update(snapshot())

        #expect(reloader.kinds.count == 1)
    }

    // MARK: Player

    @Test func playerSnapshotIsTheLoadedItemWithItsSmallCover() throws {
        let suite = "WidgetSnapshotWriterTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let playback = FakePlaybackControl()
        let player = PlayerViewModel(playback: playback, settings: AppSettings(defaults: defaults))
        #expect(player.widgetSnapshot == nil)

        playback.start(FakePlaybackControl.bookSession(), at: 50)
        // No duration while it loads: the last full snapshot stays.
        #expect(player.widgetSnapshot == nil)

        playback.load(FakePlaybackControl.bookSession(), at: 150, playing: true)
        let shown = try #require(player.widgetSnapshot)
        #expect(shown.serverID == FakePlaybackControl.serverID)
        #expect(shown.itemID == "li_book")
        #expect(shown.title == "Dune")
        #expect(shown.author == "Frank Herbert")
        #expect(shown.chapterTitle == "Middle")
        #expect(shown.currentTime == 150)
        #expect(shown.duration == 400)
        #expect(shown.isPlaying)
        #expect(shown.cover == player.coverKey.map { CoverLocator($0.with(bucket: .small)) })
        #expect(shown.cover?.bucket == .small)
    }
}
