import AppIntents
import Foundation
import NowPlaying
import Observation
import _NowPlaying_AppIntents

/// The parts of a NowPlaying `MediaSession` the controller uses, so tests can pass a fake.
///
/// Each setter replaces one property of the published `MediaSessionRepresentable`; the framework
/// observes those properties and syncs the system surfaces.
@MainActor
protocol NowPlayingSessionPublishing: AnyObject {
    func setContent(_ content: (any MediaContentRepresentable)?)
    func setPlaybackSnapshot(_ snapshot: MediaPlaybackSnapshot?)
    func setCommands(_ commands: [MediaCommand])
    func becomeApplicationPrimary() async throws
    /// iOS only; does nothing on macOS, which has no system-primary API.
    func becomeSystemPrimary() async throws
}

/// The `MediaSessionRepresentable` the framework observes.
@MainActor
@Observable
final class NowPlayingSessionModel: MediaSessionRepresentable {
    let id: String
    var content: (any MediaContentRepresentable)?
    var playbackSnapshot: MediaPlaybackSnapshot?
    var commands: [MediaCommand] = []

    init(id: String) {
        self.id = id
    }
}

/// Publishes through a real `MediaSession`. Releasing it ends the session (ADR 0006: set the session
/// reference to `nil` when playback ends).
@MainActor
final class MediaSessionPublisher: NowPlayingSessionPublishing {
    static let sessionID = "org.davidjensenius.Audiobookshelf.player"

    private let model: NowPlayingSessionModel
    private let session: MediaSession<NowPlayingSessionModel>

    init(id: String = MediaSessionPublisher.sessionID) {
        model = NowPlayingSessionModel(id: id)
        session = MediaSession(model)
    }

    func setContent(_ content: (any MediaContentRepresentable)?) { model.content = content }
    func setPlaybackSnapshot(_ snapshot: MediaPlaybackSnapshot?) { model.playbackSnapshot = snapshot }
    func setCommands(_ commands: [MediaCommand]) { model.commands = commands }

    func becomeApplicationPrimary() async throws {
        try await session.requestToBecomeApplicationPrimary()
    }

    func becomeSystemPrimary() async throws {
        #if os(iOS)
            try await session.requestToBecomeSystemPrimary()
        #endif
    }
}

// MARK: - Mapping

/// The published metadata as a comparable value, so unchanged metadata isn't republished.
struct NowPlayingContentDescriptor: Equatable {
    struct ChapterPosition: Equatable {
        /// 1-based.
        var current: Int
        var total: Int
    }

    /// `MediaKey.rawValue`.
    var id: String
    var isPodcastEpisode: Bool
    var title: String
    var author: String
    var narrator: String?
    var releaseDate: Date?
    var chapter: ChapterPosition?
    /// `nil` when unknown.
    var duration: Double?
    /// Set only once the artwork for this key has loaded.
    var artwork: LoadedArtwork?

    struct LoadedArtwork: Equatable {
        var key: String
        var data: Data
    }
}

/// The offered commands as a comparable value, so unchanged commands aren't republished.
struct NowPlayingCommandSet: Equatable {
    var skipForwardInterval: Double
    var skipBackwardInterval: Double
    var supportedRates: [Double]
    var canSeek: Bool
}

/// A remote command, as routed to ``NowPlayingCommandHandling``.
enum NowPlayingCommand: Equatable {
    case play
    case pause
    case togglePlayPause
    case skipForward(Double)
    case skipBackward(Double)
    case nextTrack
    case previousTrack
    /// Position in the published (possibly chapter-relative) timeline.
    case seek(Double)
    case changeRate(Double)
}

extension NowPlayingContentDescriptor {
    /// `BookContent` for books, `PodcastContent` for podcast episodes (ADR 0006).
    func makeContent(entityIdentifiers: [EntityIdentifier]) -> any MediaContentRepresentable {
        let mediaDuration = duration.map { MediaDuration.finite($0) }
        let artwork = artwork.map { loaded in
            let data = loaded.data
            return Artwork(id: loaded.key) { _ in try ArtworkRepresentation(data: data) }
        }
        if isPodcastEpisode {
            var content = PodcastContent(
                id: id, episodeTitle: title, showName: author, releaseDate: releaseDate, type: .audio,
                duration: mediaDuration, artwork: artwork)
            content.appEntityIdentifiers = entityIdentifiers
            return content
        }
        var content = BookContent(
            id: id, title: title, authorName: author, narratorName: narrator, duration: mediaDuration,
            artwork: artwork)
        content.chapter = chapter.map { ($0.current, $0.total) }
        content.appEntityIdentifiers = entityIdentifiers
        return content
    }
}

extension NowPlayingCommandSet {
    /// Builds the framework commands. Seek is left out entirely when not allowed: a disabled command
    /// still "appears in the interface" (ADR 0006).
    @MainActor
    func makeCommands(perform: @escaping @MainActor (NowPlayingCommand) async throws -> Void) -> [MediaCommand] {
        var commands: [MediaCommand] = [
            .play { try await perform(.play) },
            .pause { try await perform(.pause) },
            .togglePlayPause { try await perform(.togglePlayPause) },
            .skipForward(preferredIntervals: [skipForwardInterval]) { try await perform(.skipForward($0)) },
            .skipBackward(preferredIntervals: [skipBackwardInterval]) { try await perform(.skipBackward($0)) },
            .next { try await perform(.nextTrack) },
            .previous { try await perform(.previousTrack) },
            .changePlaybackRate(supported: supportedRates.map(Float.init)) {
                try await perform(.changeRate(Double($0)))
            },
        ]
        if canSeek {
            commands.append(.seekToPosition { try await perform(.seek($0)) })
        }
        return commands
    }
}
