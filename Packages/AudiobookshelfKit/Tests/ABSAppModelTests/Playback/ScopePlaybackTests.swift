import ABSCore
import ABSData
import Foundation
import Observation
import Testing

@testable import ABSAPI
@testable import ABSAppModel
@testable import ABSPlayback

/// An engine that loads at once, paused, and plays when asked.
@MainActor
@Observable
private final class InstantEngine: AudioEngineProtocol {
    var state: PlaybackState = .idle
    var currentTime: Double = 0
    var duration: Double { timeline?.duration ?? 0 }
    var currentTrackIndex: Int?
    var defaultRate: Float = 1
    var volume: Float = 1
    var isPlaybackRequested = false
    var pendingSeekTarget: Double?
    var isAudioSessionActive = false
    var timeline: PlaybackTimeline?
    var onEvent: (@MainActor (AudioEngineEvent) -> Void)?

    func load(_ source: AudioEngineSource, at time: Double) async throws(AudioEngineError) {
        timeline = source.timeline
        currentTime = source.timeline.clamp(time)
        state = isPlaybackRequested ? .playing : .paused
        isAudioSessionActive = isPlaybackRequested
    }

    func play() {
        isPlaybackRequested = true
        isAudioSessionActive = timeline != nil
        if timeline != nil { state = .playing }
    }

    func pause() {
        isPlaybackRequested = false
        if timeline != nil { state = .paused }
    }

    func stop() {
        isPlaybackRequested = false
        isAudioSessionActive = false
        timeline = nil
        state = .idle
    }

    func seek(to time: Double) async -> SeekResult {
        currentTime = timeline?.clamp(time) ?? time
        return .completed
    }

    func setRate(_ rate: Float) { defaultRate = rate }
    func setVolume(_ volume: Float) { self.volume = volume }
}

/// A server with one two-track book per item, and no progress.
private struct BookServer: PlaybackSessionService, ProgressSyncService {
    let serverConnectionID: UUID

    func startSession(itemID: String, episodeID: String?) async throws -> PlaybackSession {
        PlaybackSession(
            id: "s-\(itemID)", libraryItemId: itemID, episodeId: episodeID, mediaType: .book,
            displayTitle: "Title \(itemID)", duration: 3600, currentTime: 0,
            audioTracks: [
                AudioTrack(index: 1, startOffset: 0, duration: 1800, mimeType: "audio/mpeg"),
                AudioTrack(index: 2, startOffset: 1800, duration: 1800, mimeType: "audio/mpeg"),
            ])
    }

    func mediaProgress(itemID: String, episodeID: String?) async throws -> MediaProgress? { nil }

    func resolveStream(for session: PlaybackSession) async throws -> ResolvedStream {
        let tracks = session.audioTracks.map { track in
            PlayableTrack(
                url: URL(filePath: "/\(session.id)/\(track.index ?? 0)"), mimeType: track.mimeType,
                startOffset: track.startOffset ?? 0, duration: track.duration, authentication: .session)
        }
        return ResolvedStream(
            plan: StreamPlan(kind: .directPlay, transport: .urlAsset, tracks: tracks), urls: tracks.map(\.url))
    }

    func closeSession(id: String, report: PlaybackSyncReport?) async throws {}
    func fetchProgress(itemID: String, episodeID: String?) async throws -> MediaProgress? { nil }
    func syncSession(id: String, report: PlaybackSyncReport) async throws {}
    func updateProgress(itemID: String, episodeID: String?, _ update: MediaProgressUpdate) async throws {}
}

@MainActor
private final class Policy: StreamingPolicyChecking {
    var decision = NetworkDecision.allowed
    func streamingDecision() async -> NetworkDecision { decision }
    func currentStreamingDecision() -> NetworkDecision { decision }
}

@MainActor
private final class LastPlayed: LastPlayedStoring {
    var record: LastPlayedRecord?
    init(_ record: LastPlayedRecord?) { self.record = record }
    func load() -> LastPlayedRecord? { record }
    func save(_ record: LastPlayedRecord) { self.record = record }
    func clear() { record = nil }
}

@MainActor
private final class PrimaryRequests: NowPlayingHandle {
    var count = 0
    func invalidate() {}
    func requestSystemPrimary() async { count += 1 }
}

private struct Device: DeviceIdentifying {
    func deviceIdentifier() async -> String { "device" }
}

/// A participant building real scopes over fakes, with A's last-played item restored.
@MainActor
private struct ScopeHarness {
    let lifecycle: SessionLifecycle
    let current = CurrentPlayback()
    let policy = Policy()
    let primary = PrimaryRequests()
    let participant: PlaybackSessionParticipant

    init() throws {
        let source = FakeAccountSource(log: CallLog())
        source.restoredPhase = .active(identityA, isOffline: false)
        lifecycle = SessionLifecycle(source: source, clock: ManualClock())
        let writer = LocalProgressStore(modelContainer: try DataStack(location: .inMemory).container)
        let settings = AppSettings(defaults: try #require(UserDefaults(suiteName: UUID().uuidString)))
        settings.disableAutoRewind = true
        let policy = policy
        let primary = primary
        participant = PlaybackSessionParticipant(
            current: current, writer: writer, deviceIdentifiers: Device(),
            features: { _ in ServerFeatures(version: ServerVersion(2, 37, 2)) },
            requestSignOut: { _ in },
            makeScope: { request in
                let server = BookServer(serverConnectionID: request.connectionID)
                let coordinator = PlaybackCoordinator(
                    engine: InstantEngine(), sessions: server, progressStore: writer, settings: settings,
                    policy: policy,
                    lastPlayedStore: LastPlayed(
                        LastPlayedRecord(
                            serverConnectionID: request.connectionID, libraryItemID: "a", episodeID: nil,
                            position: 42, duration: 3600, timestamp: Date(timeIntervalSince1970: 1_800_000_000),
                            title: "Title a")))
                let syncer = ProgressSyncer(source: coordinator, service: server, store: writer)
                return PlaybackScope(coordinator: coordinator, syncer: syncer, services: nil, nowPlaying: primary)
            })
        lifecycle.register(participant, stage: .progressSource)
    }

    /// Starts A's session, with its last-played item restored and bound.
    func started() async throws {
        await lifecycle.start()
        try #require(await eventually { current.phase == .unloaded })
    }
}

/// The player's play button resumes through the scope, so a user resume (like a user play)
/// asks to become the system's primary Now Playing session.
@MainActor
@Suite struct ScopePlaybackTests {
    @Test func aUserResumeThroughCurrentPlaybackAsksToBecomePrimaryOnce() async throws {
        let harness = try ScopeHarness()
        try await harness.started()

        await harness.current.resume(rewindingBy: nil)

        #expect(harness.current.isPlaybackRequested)
        #expect(harness.primary.count == 1)
    }

    @Test func aRefusedResumeDoesNotAsk() async throws {
        let harness = try ScopeHarness()
        try await harness.started()
        harness.policy.decision = .denied(.cellular)

        await harness.current.resume(rewindingBy: nil)

        #expect(!harness.current.isPlaybackRequested)
        #expect(harness.current.error != nil)
        #expect(harness.primary.count == 0)
    }

    /// A view still holding the ended session's playback can't make it primary.
    @Test func aRetiredScopeDoesNotAsk() async throws {
        let harness = try ScopeHarness()
        try await harness.started()
        let ended = try #require(harness.current.current)

        try await harness.lifecycle.switchAccount(to: identityB.connectionID)
        await ended.resume(rewindingBy: nil)

        #expect(harness.primary.count == 0)
    }

    /// Everything but resume reads and drives the coordinator itself.
    @Test func everythingElseForwardsToTheCoordinator() async throws {
        let harness = try ScopeHarness()
        try await harness.started()
        let playback = try #require(harness.current.current as? ScopePlayback)

        await playback.resume(rewindingBy: nil)
        playback.pause()
        await playback.seek(to: 100)
        playback.setRate(1.5)

        let coordinator = playback.coordinator
        #expect(!coordinator.isPlaybackRequested)
        #expect(coordinator.currentTime == 100 && playback.currentTime == 100)
        #expect(coordinator.rate == 1.5 && playback.rate == 1.5)
        #expect(playback.mediaKey == coordinator.mediaKey && playback.session?.id == "s-a")
        #expect(harness.primary.count == 1)
    }
}
