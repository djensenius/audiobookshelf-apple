import ABSCore

/// Pure time math for one playback session: global time ↔ track offsets, chapters, chapter-track
/// ranges and clamped jumps. All times are seconds from the start of the media.
///
/// Inputs are normalised once on creation:
/// - Tracks: non-finite or negative durations become `0`; a missing `startOffset` continues from the
///   previous track's end; tracks are ordered by start (stable). Tracks may overlap or leave gaps.
///   The queue plays each track once, in order, so overlaps are resolved by ``Track/playbackEnd``:
///   where a later track extends past the current one, the current one stops at the later one's
///   start; a later track that ends within what earlier tracks already cover (for example 100–150
///   inside 0–300) is skipped, so all of the containing track plays. Zero-length tracks are skipped.
/// - ``duration`` is the reachable end: the end of the last playable track, so it never includes
///   skipped tracks' ends.
/// - Chapters: ordered by start (stable); clamped to `0...duration`; trimmed so each ends no later
///   than the next one starts (so of several chapters with the same start, the last is kept); empty
///   chapters are dropped. A timeline with zero duration has no chapters.
///
/// Because of this, ``tracks`` can differ from `session.audioTracks` in order and start offsets
/// (`AudioTrack.endOffset` assumes `startOffset ?? 0`). The player queue MUST be built from
/// ``tracks``, and every global ↔ track-local conversion MUST go through the timeline.
/// ``Track/sourceIndex`` maps a track back to `session.audioTracks`.
///
/// Track ends are not rounded down as the legacy player did, so a seek can land exactly at an
/// item's real end; the player must tolerate that (for example by advancing to the next item).
///
/// Input times: NaN counts as `0`; ±infinity clamps to `0` or ``duration``.
public struct PlaybackTimeline: Sendable, Hashable {
    /// A track placed on the timeline.
    public struct Track: Sendable, Hashable {
        public let audioTrack: AudioTrack
        /// Position of ``audioTrack`` in the array the timeline was created from.
        public let sourceIndex: Int
        public let start: Double
        public let duration: Double
        /// Global time at which playback of this track stops: the next playable track's start or
        /// this track's end, whichever is smaller. Equal to ``start`` for a skipped track (zero-length,
        /// or contained in earlier tracks), which the queue should leave out.
        public let playbackEnd: Double

        public var end: Double { start + duration }

        /// Seconds of this track that play; `0` for a skipped track.
        public var playbackDuration: Double { playbackEnd - start }

        /// Track-local seconds at which the item should stop, for `AVPlayerItem.forwardPlaybackEndTime`.
        /// Unlike ``playbackEnd`` this is relative to the item, not the timeline (a track starting at
        /// 1000 that stops at 1050 has a forward end time of 50). Same value as ``playbackDuration``.
        public var forwardPlaybackEndTime: Double { playbackDuration }

        /// Whether the queue should include this track.
        public var isPlayable: Bool { playbackDuration > 0 }
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
    /// Normalised chapters. Chapter indexes returned by the timeline refer to this array, not to
    /// `session.chapters`.
    public let chapters: [Chapter]
    /// The reachable end: the ``Track/playbackEnd`` of the last playable track, or `0` without one.
    public let duration: Double

    public init(tracks: [AudioTrack], chapters: [Chapter]) {
        var placed: [(audioTrack: AudioTrack, sourceIndex: Int, start: Double, duration: Double)] = []
        placed.reserveCapacity(tracks.count)
        var previousEnd: Double = 0
        for (sourceIndex, audioTrack) in tracks.enumerated() {
            let start = max(Self.finite(audioTrack.startOffset) ?? previousEnd, 0)
            let duration = max(Self.finite(audioTrack.duration) ?? 0, 0)
            placed.append((audioTrack, sourceIndex, start, duration))
            previousEnd = start + duration
        }
        let sorted = Self.stableSorted(placed, by: \.start)

        // Sweep in start order. `reach` is the end of the last kept track; a track ending at or
        // before it is already covered and skipped, otherwise it trims the last kept track.
        var playbackEnds = sorted.map(\.start)
        var lastKept: Int?
        var reach: Double = 0
        for (index, track) in sorted.enumerated() where track.duration > 0 {
            let end = track.start + track.duration
            if let lastKept {
                guard end > reach else { continue }
                playbackEnds[lastKept] = min(playbackEnds[lastKept], track.start)
            }
            playbackEnds[index] = end
            lastKept = index
            reach = end
        }
        self.tracks = sorted.enumerated().map { index, track in
            Track(
                audioTrack: track.audioTrack, sourceIndex: track.sourceIndex, start: track.start,
                duration: track.duration, playbackEnd: playbackEnds[index])
        }
        self.duration = reach
        self.chapters = Self.normalise(chapters, duration: duration)
    }

    public init(session: PlaybackSession) {
        self.init(tracks: session.audioTracks, chapters: session.chapters)
    }

    // MARK: - Tracks

    /// `time` clamped to `0...duration`; NaN becomes `0`.
    public func clamp(_ time: Double) -> Double {
        min(max(time.isNaN ? 0 : time, 0), duration)
    }

    /// The track playing at `time`, and the offset into it. Tracks cover `start..<playbackEnd`.
    ///
    /// - A time on a boundary belongs to the track that starts there.
    /// - Where tracks overlap, the later-starting track wins; skipped tracks are never returned.
    /// - A time in a gap, or before the first track, maps to the start of the next track.
    /// - A time at or past the end maps to the end of the last playable track.
    /// - If no track is playable (all zero-length), returns the first track at offset 0.
    /// - Returns `nil` without tracks.
    public func position(at time: Double) -> TrackPosition? {
        guard !tracks.isEmpty else { return nil }
        let playable = tracks.indices.filter { tracks[$0].isPlayable }
        guard let lastPlayable = playable.last else { return TrackPosition(trackIndex: 0, offset: 0) }
        let time = clamp(time)

        if let index = playable.last(where: { tracks[$0].start <= time && time < tracks[$0].playbackEnd }) {
            return TrackPosition(trackIndex: index, offset: time - tracks[index].start)
        }
        if let next = playable.first(where: { tracks[$0].start > time }) {
            return TrackPosition(trackIndex: next, offset: 0)
        }
        let index = playable.last { tracks[$0].start <= time } ?? lastPlayable
        return TrackPosition(trackIndex: index, offset: min(time - tracks[index].start, tracks[index].playbackDuration))
    }

    /// Global time for an offset into `tracks[trackIndex]`, with the offset clamped to
    /// `0...playbackDuration` (NaN counts as `0`), so it never passes where the track stops playing.
    /// The result is also clamped to `0...duration`, since a skipped track can start past the
    /// reachable end. Returns `nil` for an index outside ``tracks``.
    public func time(trackIndex: Int, offset: Double) -> Double? {
        guard tracks.indices.contains(trackIndex) else { return nil }
        let track = tracks[trackIndex]
        return clamp(track.start + min(max(offset.isNaN ? 0 : offset, 0), track.playbackDuration))
    }

    public func time(at position: TrackPosition) -> Double? {
        time(trackIndex: position.trackIndex, offset: position.offset)
    }

    // MARK: - Jumps

    /// `time + interval`, clamped to the timeline. Negative or NaN intervals count as `0`.
    public func jumpForward(from time: Double, by interval: Double) -> Double {
        clamp(clamp(time) + Self.nonNegative(interval))
    }

    /// `time - interval`, clamped to the timeline. Negative or NaN intervals count as `0`.
    public func jumpBackward(from time: Double, by interval: Double) -> Double {
        clamp(clamp(time) - Self.nonNegative(interval))
    }

    // MARK: - Helpers

    static func finite(_ value: Double?) -> Double? {
        guard let value, value.isFinite else { return nil }
        return value
    }

    private static func nonNegative(_ value: Double) -> Double {
        value.isNaN ? 0 : max(value, 0)
    }

    private static func stableSorted<T>(_ values: [T], by key: (T) -> Double) -> [T] {
        values.enumerated().sorted { lhs, rhs in
            let left = key(lhs.element)
            let right = key(rhs.element)
            return left != right ? left < right : lhs.offset < rhs.offset
        }.map(\.element)
    }

    private static func normalise(_ chapters: [Chapter], duration: Double) -> [Chapter] {
        guard duration > 0 else { return [] }
        let bounded: [Chapter] = chapters.compactMap { chapter in
            guard let start = finite(chapter.start), let end = finite(chapter.end) else { return nil }
            let clampedStart = min(max(start, 0), duration)
            let clampedEnd = min(end, duration)
            guard clampedEnd > clampedStart else { return nil }
            return Chapter(id: chapter.id, start: clampedStart, end: clampedEnd, title: chapter.title)
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
