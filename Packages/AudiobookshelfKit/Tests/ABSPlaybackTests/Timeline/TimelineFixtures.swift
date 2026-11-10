import ABSCore
import ABSPlayback
import Testing

/// Timelines for the table tests, built in code.
enum TimelineFixture: String, CaseIterable, Sendable, CustomTestStringConvertible {
    /// Single 10 h m4b; chapters arrive unsorted, one ends past the media and one starts after it.
    case m4b
    /// Single m4b of 36000.25 s whose last chapter ends at 36000, short of the duration.
    case m4bShortChapters
    /// 30 mp3 files, file `i` lasting `1000 + i` s, with one chapter per file.
    case mp3
    /// Three 600 s files with chapters 0–450, 450–1000 and 1000–1800 crossing the file boundaries.
    case crossingChapters
    /// 40 files of 1234.567891 s each (not representable in binary), start offsets summed.
    case floatTracks
    /// A podcast episode: one track with a `null` index and no chapters.
    case podcast
    /// Tracks 5–100 and 110–200 (leading gap and a gap between tracks).
    case gappedTracks
    /// Tracks 0–100 and 95–200.
    case overlappingTracks
    /// Zero, negative and missing-offset tracks: resolves to 0–0, 0–50, 50–50, 50–100.
    case degenerateTracks
    /// A single zero-length track.
    case zeroLength
    /// No tracks, no chapters.
    case empty
    /// One 300 s track; chapters 10–100, 150–200 and 190–300 (gap, overlap, leading gap), plus an
    /// empty and a negative chapter that are dropped.
    case chapterGaps

    var testDescription: String { rawValue }

    var timeline: PlaybackTimeline {
        switch self {
        case .m4b:
            PlaybackTimeline(
                tracks: [AudioTrack(index: 1, startOffset: 0, duration: 36_000, title: "Book.m4b")],
                chapters: [
                    Chapter(id: 2, start: 5400, end: 12_000, title: "Three"),
                    Chapter(id: 0, start: 0, end: 1800.25, title: "One"),
                    Chapter(id: 4, start: 30_000, end: 36_000.5, title: "Five"),
                    Chapter(id: 1, start: 1800.25, end: 5400, title: "Two"),
                    Chapter(id: 5, start: 40_000, end: 41_000, title: "Ghost"),
                    Chapter(id: 3, start: 12_000, end: 30_000, title: "Four"),
                ])
        case .m4bShortChapters:
            PlaybackTimeline(
                tracks: [AudioTrack(index: 1, startOffset: 0, duration: 36_000.25)],
                chapters: [Chapter(id: 0, start: 0, end: 18_000), Chapter(id: 1, start: 18_000, end: 36_000)])
        case .crossingChapters:
            PlaybackTimeline(
                tracks: (0..<3).map { AudioTrack(index: $0 + 1, startOffset: Double($0) * 600, duration: 600) },
                chapters: [
                    Chapter(id: 0, start: 0, end: 450), Chapter(id: 1, start: 450, end: 1000),
                    Chapter(id: 2, start: 1000, end: 1800),
                ])
        case .floatTracks:
            PlaybackTimeline(
                tracks: (0..<40).map {
                    AudioTrack(index: $0 + 1, startOffset: Self.floatStarts[$0], duration: Self.floatDuration)
                },
                chapters: [])
        case .mp3:
            PlaybackTimeline(
                tracks: (0..<30).map {
                    AudioTrack(index: $0 + 1, startOffset: Self.mp3Start($0), duration: 1000 + Double($0))
                },
                chapters: (0..<30).map {
                    Chapter(id: $0, start: Self.mp3Start($0), end: Self.mp3Start($0 + 1), title: "File \($0 + 1)")
                })
        case .podcast:
            PlaybackTimeline(tracks: [AudioTrack(index: nil, startOffset: 0, duration: 2700)], chapters: [])
        case .gappedTracks:
            PlaybackTimeline(
                tracks: [
                    AudioTrack(index: 1, startOffset: 5, duration: 95),
                    AudioTrack(index: 2, startOffset: 110, duration: 90),
                ],
                chapters: [])
        case .overlappingTracks:
            PlaybackTimeline(
                tracks: [
                    AudioTrack(index: 1, startOffset: 0, duration: 100),
                    AudioTrack(index: 2, startOffset: 95, duration: 105),
                ],
                chapters: [])
        case .degenerateTracks:
            PlaybackTimeline(
                tracks: [
                    AudioTrack(index: 1, startOffset: 0, duration: 0),
                    AudioTrack(index: 2, duration: 50),
                    AudioTrack(index: 3, duration: -3),
                    AudioTrack(index: 4, duration: 50),
                ],
                chapters: [])
        case .zeroLength:
            PlaybackTimeline(tracks: [AudioTrack(index: 1, startOffset: 0, duration: 0)], chapters: [])
        case .empty:
            PlaybackTimeline(tracks: [], chapters: [])
        case .chapterGaps:
            PlaybackTimeline(
                tracks: [AudioTrack(index: 1, startOffset: 0, duration: 300)],
                chapters: [
                    Chapter(id: 2, start: 190, end: 300),
                    Chapter(id: 0, start: 10, end: 100),
                    Chapter(id: 9, start: 250, end: 250),
                    Chapter(id: 8, start: 120, end: 110),
                    Chapter(id: 1, start: 150, end: 200),
                ])
        }
    }

    static let floatDuration = 1234.567891

    static let floatStarts: [Double] = (0..<40).reduce(into: [0]) { starts, _ in
        starts.append(starts[starts.count - 1] + floatDuration)
    }

    /// Start of mp3 file `index`: the sum of `1000 + k` for `k < index`.
    static func mp3Start(_ index: Int) -> Double {
        Double(1000 * index + index * (index - 1) / 2)
    }
}
