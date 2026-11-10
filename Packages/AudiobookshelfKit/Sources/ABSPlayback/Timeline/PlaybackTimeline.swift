import ABSCore

/// Pure time math for one playback session: global time ↔ track offsets, chapters, chapter-track
/// ranges and clamped jumps. All times are seconds from the start of the media.
///
/// Inputs are normalised once on creation:
/// - Tracks: non-finite or negative durations become `0`; a missing `startOffset` continues from the
///   previous track's end; tracks are ordered by start (stable). Tracks may overlap or leave gaps.
/// - Chapters: ordered by start (stable); clamped to `0...duration` when the tracks have a length;
///   trimmed so each ends no later than the next one starts; empty chapters are dropped.
public struct PlaybackTimeline: Sendable, Hashable {
    /// A track placed on the timeline.
    public struct Track: Sendable, Hashable {
        public let audioTrack: AudioTrack
        public let start: Double
        public let duration: Double

        public var end: Double { start + duration }
    }

    /// A track and an offset into it, as handed to the player.
    public struct TrackPosition: Sendable, Hashable {
        /// Index into ``PlaybackTimeline/tracks`` (0-based; not the server's `AudioTrack.index`).
        public let trackIndex: Int
        /// Seconds from the start of the track.
        public let offset: Double

        public init(trackIndex: Int, offset: Double) {
            self.trackIndex = trackIndex
            self.offset = offset
        }
    }

    public let tracks: [Track]
    public let chapters: [Chapter]
    /// End of the last track, or `0` without tracks.
    public let duration: Double

    public init(tracks: [AudioTrack], chapters: [Chapter]) {
        var placed: [Track] = []
        placed.reserveCapacity(tracks.count)
        var previousEnd: Double = 0
        for audioTrack in tracks {
            let start = max(Self.finite(audioTrack.startOffset) ?? previousEnd, 0)
            let duration = max(Self.finite(audioTrack.duration) ?? 0, 0)
            placed.append(Track(audioTrack: audioTrack, start: start, duration: duration))
            previousEnd = start + duration
        }
        self.tracks = Self.stableSorted(placed, by: \.start)
        self.duration = self.tracks.map(\.end).max() ?? 0
        self.chapters = Self.normalise(chapters, duration: duration)
    }

    public init(session: PlaybackSession) {
        self.init(tracks: session.audioTracks, chapters: session.chapters)
    }

    // MARK: - Tracks

    /// `time` clamped to `0...duration`; non-finite values become `0`.
    public func clamp(_ time: Double) -> Double {
        min(max(Self.finite(time) ?? 0, 0), duration)
    }

    /// The track playing at `time`, and the offset into it.
    ///
    /// - A time on a boundary belongs to the track that starts there.
    /// - Where tracks overlap, the later-starting track wins.
    /// - A time in a gap, or before the first track, maps to the start of the next track.
    /// - A time at or past the end maps to the end of the last playable track.
    /// - Zero-length tracks are skipped unless every track is zero-length (then the first track, offset 0).
    /// - Returns `nil` without tracks.
    public func position(at time: Double) -> TrackPosition? {
        guard !tracks.isEmpty else { return nil }
        let playable = tracks.indices.filter { tracks[$0].duration > 0 }
        guard let lastPlayable = playable.last else { return TrackPosition(trackIndex: 0, offset: 0) }
        let time = clamp(time)

        if time >= tracks[lastPlayable].end {
            return TrackPosition(trackIndex: lastPlayable, offset: tracks[lastPlayable].duration)
        }
        if let index = playable.last(where: { tracks[$0].start <= time && time < tracks[$0].end }) {
            return TrackPosition(trackIndex: index, offset: time - tracks[index].start)
        }
        let next = playable.first { tracks[$0].start > time } ?? lastPlayable
        return TrackPosition(trackIndex: next, offset: 0)
    }

    /// Global time for an offset into `tracks[trackIndex]`, with the offset clamped to the track.
    /// Returns `nil` for an index outside ``tracks``.
    public func time(trackIndex: Int, offset: Double) -> Double? {
        guard tracks.indices.contains(trackIndex) else { return nil }
        let track = tracks[trackIndex]
        return track.start + min(max(Self.finite(offset) ?? 0, 0), track.duration)
    }

    public func time(at position: TrackPosition) -> Double? {
        time(trackIndex: position.trackIndex, offset: position.offset)
    }

    // MARK: - Jumps

    /// `time + interval`, clamped to the timeline. Negative intervals count as `0`.
    public func jumpForward(from time: Double, by interval: Double) -> Double {
        clamp(clamp(time) + max(Self.finite(interval) ?? 0, 0))
    }

    /// `time - interval`, clamped to the timeline. Negative intervals count as `0`.
    public func jumpBackward(from time: Double, by interval: Double) -> Double {
        clamp(clamp(time) - max(Self.finite(interval) ?? 0, 0))
    }

    // MARK: - Helpers

    static func finite(_ value: Double?) -> Double? {
        guard let value, value.isFinite else { return nil }
        return value
    }

    private static func stableSorted<T>(_ values: [T], by key: (T) -> Double) -> [T] {
        values.enumerated().sorted { lhs, rhs in
            let left = key(lhs.element)
            let right = key(rhs.element)
            return left != right ? left < right : lhs.offset < rhs.offset
        }.map(\.element)
    }

    private static func normalise(_ chapters: [Chapter], duration: Double) -> [Chapter] {
        let bounded: [Chapter] = chapters.compactMap { chapter in
            guard var start = finite(chapter.start), var end = finite(chapter.end) else { return nil }
            start = max(start, 0)
            if duration > 0 {
                start = min(start, duration)
                end = min(end, duration)
            }
            guard end > start else { return nil }
            return Chapter(id: chapter.id, start: start, end: end, title: chapter.title)
        }
        let sorted = stableSorted(bounded, by: \.start)

        var result: [Chapter] = []
        result.reserveCapacity(sorted.count)
        for (index, chapter) in sorted.enumerated() {
            let end = index + 1 < sorted.count ? min(chapter.end, sorted[index + 1].start) : chapter.end
            guard end > chapter.start else { continue }
            result.append(Chapter(id: chapter.id, start: chapter.start, end: end, title: chapter.title))
        }
        return result
    }
}
