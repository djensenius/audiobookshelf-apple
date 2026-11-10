import ABSCore

/// Pure time math for one playback session: global time ↔ track offsets, chapters, chapter-track
/// ranges and clamped jumps. All times are seconds from the start of the media.
///
/// Inputs are normalised once on creation:
/// - Tracks: non-finite or negative durations become `0`; a missing `startOffset` continues from the
///   previous track's end; tracks are ordered by start (stable). Tracks may overlap or leave gaps.
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
        /// Where playback of this track should stop: the next playable track's start or this track's
        /// end, whichever is smaller. Set it as the item's forward end time so global time never goes
        /// backwards when tracks overlap.
        public let playbackEnd: Double

        public var end: Double { start + duration }
        public var playbackDuration: Double { playbackEnd - start }
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
    /// End of the last track, or `0` without tracks.
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

        var result: [Track] = []
        result.reserveCapacity(sorted.count)
        for (index, track) in sorted.enumerated() {
            let end = track.start + track.duration
            let nextStart = sorted[(index + 1)...].first { $0.duration > 0 }?.start ?? end
            result.append(
                Track(
                    audioTrack: track.audioTrack, sourceIndex: track.sourceIndex, start: track.start,
                    duration: track.duration, playbackEnd: max(min(end, nextStart), track.start)))
        }
        self.tracks = result
        self.duration = result.map(\.end).max() ?? 0
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
    /// - Where tracks overlap, the later-starting track wins.
    /// - A time in a gap, or before the first track, maps to the start of the next track.
    /// - A time at or past the end maps to the end of the last playable track.
    /// - Zero-length tracks are skipped unless every track is zero-length (then the first track, offset 0).
    /// - Returns `nil` without tracks.
    public func position(at time: Double) -> TrackPosition? {
        guard !tracks.isEmpty else { return nil }
        let playable = tracks.indices.filter { tracks[$0].playbackDuration > 0 }
        guard let lastPlayable = playable.last else { return TrackPosition(trackIndex: 0, offset: 0) }
        let time = clamp(time)

        if let index = playable.last(where: { tracks[$0].start <= time && time < tracks[$0].playbackEnd }) {
            return TrackPosition(trackIndex: index, offset: time - tracks[index].start)
        }
        if let next = playable.first(where: { tracks[$0].start > time }) {
            return TrackPosition(trackIndex: next, offset: 0)
        }
        let index = playable.last { tracks[$0].start <= time } ?? lastPlayable
        return TrackPosition(trackIndex: index, offset: min(time - tracks[index].start, tracks[index].duration))
    }

    /// Global time for an offset into `tracks[trackIndex]`, with the offset clamped to the track
    /// (NaN counts as `0`). Returns `nil` for an index outside ``tracks``.
    public func time(trackIndex: Int, offset: Double) -> Double? {
        guard tracks.indices.contains(trackIndex) else { return nil }
        let track = tracks[trackIndex]
        return track.start + min(max(offset.isNaN ? 0 : offset, 0), track.duration)
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
