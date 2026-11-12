import ABSData
import AppIntents
import Foundation
import NowPlaying
import Synchronization
import Testing

@testable import ABSPlayback

@MainActor
final class FakeNowPlayingSession: NowPlayingSessionPublishing {
    var contents: [(any MediaContentRepresentable)?] = []
    var snapshots: [MediaPlaybackSnapshot?] = []
    var commandUpdates: [[MediaCommand]] = []
    /// Primary requests in order: "application" or "system".
    var primaryRequests: [String] = []
    var applicationPrimaryRequests: Int { primaryRequests.count { $0 == "application" } }
    var systemPrimaryRequests: Int { primaryRequests.count { $0 == "system" } }

    var content: (any MediaContentRepresentable)? { contents.last ?? nil }
    var book: BookContent? { content as? BookContent }
    var podcast: PodcastContent? { content as? PodcastContent }
    var snapshot: MediaPlaybackSnapshot? { snapshots.last ?? nil }

    func setContent(_ content: (any MediaContentRepresentable)?) { contents.append(content) }
    func setPlaybackSnapshot(_ snapshot: MediaPlaybackSnapshot?) { snapshots.append(snapshot) }
    func setCommands(_ commands: [MediaCommand]) { commandUpdates.append(commands) }
    /// The next this-many application-primary requests throw.
    var applicationPrimaryFailures = 0

    /// Holds the next application-primary request until opened.
    var applicationPrimaryGate: Gate?

    func becomeApplicationPrimary() async throws {
        primaryRequests.append("application")
        if let gate = applicationPrimaryGate {
            applicationPrimaryGate = nil
            await gate.wait()
        }
        if applicationPrimaryFailures > 0 {
            applicationPrimaryFailures -= 1
            throw CancellationError()
        }
    }
    func becomeSystemPrimary() async throws { primaryRequests.append("system") }
}

@MainActor
final class FakeCommandHandler: NowPlayingCommandHandling {
    enum Call: Equatable {
        case play, pause, toggle
        case skipForward(Double), skipBackward(Double)
        case seek(Double)
        case rate(Double)
    }

    var calls: [Call] = []

    func play() async { calls.append(.play) }
    func pause() async { calls.append(.pause) }
    func togglePlayPause() async { calls.append(.toggle) }
    func skipForward(by seconds: Double) async { calls.append(.skipForward(seconds)) }
    func skipBackward(by seconds: Double) async { calls.append(.skipBackward(seconds)) }
    func seek(to time: Double) async { calls.append(.seek(time)) }
    func setRate(_ rate: Double) async { calls.append(.rate(rate)) }
}

// `TestClock` (a clock tests advance by hand) is shared with the coordinator tests.

/// Artwork loads that complete only when the test resolves them, in either order.
actor ArtworkGate {
    private var waiting: [String: CheckedContinuation<Data?, Never>] = [:]
    private var ready: [String: Data?] = [:]

    func load(_ key: String) async -> Data? {
        if let result = ready.removeValue(forKey: key) { return result }
        return await withCheckedContinuation { waiting[key] = $0 }
    }

    func resolve(_ key: String, with data: Data?) {
        if let continuation = waiting.removeValue(forKey: key) {
            continuation.resume(returning: data)
        } else {
            ready[key] = data
        }
    }
}

final class ArtworkCalls: Sendable {
    private let keys = Mutex<[String]>([])

    var all: [String] { keys.withLock { $0 } }
    func record(_ key: String) { keys.withLock { $0.append(key) } }
}

final class CallCounter: Sendable {
    private let calls = Mutex<[MediaKey]>([])

    var keys: [MediaKey] { calls.withLock { $0 } }
    func record(_ key: MediaKey) { calls.withLock { $0.append(key) } }
}

struct TestBookEntity: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation { "Book" }
    static var defaultQuery: Query { Query() }

    var id: String
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "Book") }

    struct Query: EntityQuery {
        func entities(for identifiers: [String]) async throws -> [TestBookEntity] { [] }
    }
}

@MainActor
struct NowPlayingHarness {
    let handler = FakeCommandHandler()
    let clock: TestClock
    let entityCalls: CallCounter
    let controller: NowPlayingController
    /// Sessions made by the controller, oldest first.
    let sessions: SessionLog

    /// The latest session the controller made.
    var session: FakeNowPlayingSession {
        get throws { try #require(sessions.made.last) }
    }

    @MainActor
    final class SessionLog {
        var made: [FakeNowPlayingSession] = []
    }

    init(
        settings: NowPlayingSettings = NowPlayingSettings(chapterTrack: false),
        artwork: @escaping NowPlayingArtworkProvider = { _ in nil }
    ) {
        let clock = TestClock()
        let entityCalls = CallCounter()
        let sessions = SessionLog()
        self.clock = clock
        self.entityCalls = entityCalls
        self.sessions = sessions
        controller = NowPlayingController(
            commandHandler: handler, settings: settings, artworkProvider: artwork,
            entityIdentifiers: { key in
                entityCalls.record(key)
                return [EntityIdentifier(for: TestBookEntity.self, identifier: key.libraryItemId)]
            },
            now: { clock.now },
            makeSession: {
                let next = FakeNowPlayingSession()
                sessions.made.append(next)
                return next
            })
    }
}

enum NowPlayingFixtures {
    static let server = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    static let bookKey = MediaKey(serverConnectionID: server, libraryItemId: "li_book")
    static let otherBookKey = MediaKey(serverConnectionID: server, libraryItemId: "li_other")
    static let episodeKey = MediaKey(serverConnectionID: server, libraryItemId: "li_show", episodeId: "ep_1")

    /// Chapter 3 of 10, 600–1200 s.
    static let chapter = NowPlayingState.Chapter(
        title: "Chapter Three", index: 2, count: 10, range: TimelineRange(start: 600, end: 1200))

    static func book(
        elapsed: Double = 700, rate: Double = 1.5, isPlaying: Bool = true,
        chapter: NowPlayingState.Chapter? = NowPlayingFixtures.chapter, artworkKey: String? = nil
    ) -> NowPlayingState {
        NowPlayingState(
            key: bookKey, title: "The Book", author: "An Author", narrator: "A Narrator", chapter: chapter,
            duration: 6000, elapsed: elapsed, rate: rate, isPlaying: isPlaying, artworkKey: artworkKey)
    }
}

extension MediaDuration {
    var finiteValue: Double? {
        if case .finite(let value) = self { return value }
        return nil
    }
}
