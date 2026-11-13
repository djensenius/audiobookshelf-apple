import ABSCore
import ABSData
import Foundation

/// Builds a local ``PlaybackSession`` (ADR 0007, decision 7) from a downloaded item's snapshot,
/// as the legacy `LocalLibraryItem.getPlaybackSession(episode:)` does. Pure: it touches no files.
///
/// - A book plays the snapshot's tracks, each matched to its downloaded audio file by track index,
///   with the book's chapters. Its duration is the end of its last track.
/// - A podcast episode plays its one track from the start of the timeline (`startOffset` 0), with
///   the episode's chapters only, and the episode title. The show's title is the author, as the
///   player shows for a streamed episode.
///
/// Each track's `contentUrl` is its file's path relative to the downloads root, never an absolute
/// or signed URL (ADR 0007), so ``LocalPlaybackSessionService`` resolves it when the stream loads.
public enum LocalPlaybackSessionBuilder {
    /// The value of `mediaPlayer` for a local session (ADR 0007, decision 7).
    public static let mediaPlayer = "AVPlayer"

    /// The session for the item's book or episode `episodeID`; `nil` when the media has no track,
    /// or a track has no downloaded audio file.
    public static func session(
        for item: LocalLibraryItemDTO, episodeID: String?, id: String, currentTime: Double, startedAt: Date,
        deviceInfo: DeviceInfo? = nil
    ) -> PlaybackSession? {
        guard let media = playableMedia(of: item, episodeID: episodeID) else { return nil }
        let startedAtMilliseconds = Int((startedAt.timeIntervalSince1970 * 1000).rounded())
        return PlaybackSession(
            id: id, userId: item.serverUserId, libraryItemId: item.libraryItemId, episodeId: episodeID,
            mediaType: item.mediaType, chapters: media.chapters, displayTitle: media.title,
            displayAuthor: media.author, duration: media.duration, playMethod: .local, mediaPlayer: mediaPlayer,
            deviceInfo: deviceInfo, startTime: currentTime, currentTime: currentTime,
            startedAt: startedAtMilliseconds, updatedAt: startedAtMilliseconds, audioTracks: media.tracks)
    }

    /// The downloaded files the session for `episodeID` plays, relative to the downloads root and in
    /// track order; `nil` when it can't be played from downloads.
    public static func relativePaths(of item: LocalLibraryItemDTO, episodeID: String?) -> [String]? {
        playableMedia(of: item, episodeID: episodeID)?.tracks.compactMap(\.contentUrl)
    }

    private struct PlayableMedia {
        var tracks: [AudioTrack]
        var chapters: [Chapter]
        var title: String
        var author: String?
        var duration: Double
    }

    private static func playableMedia(of item: LocalLibraryItemDTO, episodeID: String?) -> PlayableMedia? {
        let audioFiles = item.files.filter { $0.kind == .audio }
        if let episodeID {
            guard let episode = item.media.episodes.first(where: { $0.id == episodeID }),
                let track = episode.track,
                let file = audioFiles.first(where: { $0.episodeId == episodeID })
            else { return nil }
            let audioTrack = AudioTrack(
                index: track.index, startOffset: 0, duration: track.duration, title: track.title,
                contentUrl: file.relativePath, mimeType: file.mimeType)
            return PlayableMedia(
                tracks: [audioTrack], chapters: episode.chapters.map(chapter), title: episode.title,
                author: item.title, duration: track.duration)
        }
        guard !item.media.audioTracks.isEmpty else { return nil }
        var tracks: [AudioTrack] = []
        for track in item.media.audioTracks {
            guard let file = audioFiles.first(where: { $0.episodeId == nil && $0.trackIndex == track.index })
            else { return nil }
            tracks.append(
                AudioTrack(
                    index: track.index, startOffset: track.startOffset, duration: track.duration,
                    title: track.title, contentUrl: file.relativePath, mimeType: file.mimeType))
        }
        return PlayableMedia(
            tracks: tracks, chapters: item.media.chapters.map(chapter), title: item.title, author: item.authorName,
            duration: tracks.map(\.endOffset).max() ?? 0)
    }

    private static func chapter(_ chapter: LocalMediaSnapshot.Chapter) -> Chapter {
        Chapter(id: chapter.id, start: chapter.start, end: chapter.end, title: chapter.title)
    }
}
