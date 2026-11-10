import ABSCore
import ABSPlayback
import Testing

@Suite struct PlaybackTimelineTests {
    // MARK: - Tracks

    struct PositionCase: Sendable, CustomTestStringConvertible {
        let fixture: TimelineFixture
        let time: Double
        let expected: PlaybackTimeline.TrackPosition?

        init(_ fixture: TimelineFixture, _ time: Double, _ track: Int?, _ offset: Double = 0) {
            self.fixture = fixture
            self.time = time
            self.expected = track.map { PlaybackTimeline.TrackPosition(trackIndex: $0, offset: offset) }
        }

        var testDescription: String { "\(fixture) @ \(time)" }
    }

    static let positionCases: [PositionCase] = [
        // m4b: one track, so every time maps into it, clamped.
        .init(.m4b, 0, 0, 0),
        .init(.m4b, 1800.25, 0, 1800.25),
        .init(.m4b, 36_000, 0, 36_000),
        .init(.m4b, 40_000, 0, 36_000),
        .init(.m4b, -5, 0, 0),
        .init(.m4b, .nan, 0, 0),
        .init(.m4b, .infinity, 0, 36_000),
        .init(.m4b, -.infinity, 0, 0),
        // 30-file mp3: track boundaries belong to the track that starts there.
        .init(.mp3, 0, 0, 0),
        .init(.mp3, 999.5, 0, 999.5),
        .init(.mp3, 1000, 1, 0),
        .init(.mp3, 2000.5, 1, 1000.5),
        .init(.mp3, 2001, 2, 0),
        .init(.mp3, 15_000, 14, 909),
        .init(.mp3, 29_406, 29, 0),
        .init(.mp3, 30_435, 29, 1029),
        .init(.mp3, 31_000, 29, 1029),
        // Chapters crossing file boundaries.
        .init(.crossingChapters, 450, 0, 450),
        .init(.crossingChapters, 599.5, 0, 599.5),
        .init(.crossingChapters, 600, 1, 0),
        .init(.crossingChapters, 1000, 1, 400),
        .init(.crossingChapters, 1200, 2, 0),
        .init(.crossingChapters, 1800, 2, 600),
        // Podcast without chapters.
        .init(.podcast, 0, 0, 0),
        .init(.podcast, 1350.5, 0, 1350.5),
        .init(.podcast, 2700, 0, 2700),
        // Gaps snap forward to the next track; the end of a track is the next track's start.
        .init(.gappedTracks, 2, 0, 0),
        .init(.gappedTracks, 99.5, 0, 94.5),
        .init(.gappedTracks, 100, 1, 0),
        .init(.gappedTracks, 105, 1, 0),
        .init(.gappedTracks, 200, 1, 90),
        // Overlaps: the later-starting track wins.
        .init(.overlappingTracks, 94, 0, 94),
        .init(.overlappingTracks, 97, 1, 2),
        .init(.overlappingTracks, 200, 1, 105),
        // A contained track is skipped: the containing track plays to its end.
        .init(.nestedTracks, 120, 0, 120),
        .init(.nestedTracks, 150, 0, 150),
        .init(.nestedTracks, 300, 0, 300),
        .init(.nestedTracks, 400, 0, 300),
        .init(.trailingZeroLength, 600, 0, 100),
        // Zero-length tracks are skipped; missing offsets continue from the previous track.
        .init(.degenerateTracks, 0, 1, 0),
        .init(.degenerateTracks, 50, 3, 0),
        .init(.degenerateTracks, 100, 3, 50),
        .init(.zeroLength, 10, 0, 0),
        .init(.empty, 10, nil),
    ]

    @Test(arguments: positionCases)
    func position(_ testCase: PositionCase) {
        #expect(testCase.fixture.timeline.position(at: testCase.time) == testCase.expected)
    }

    @Test(arguments: [
        (TimelineFixture.m4b, 0.0), (.m4b, 1800.25), (.m4b, 36_000), (.mp3, 0), (.mp3, 1000), (.mp3, 15_000),
        (.mp3, 30_435), (.podcast, 1234.5), (.overlappingTracks, 97),
    ])
    func positionRoundTrips(_ fixture: TimelineFixture, _ time: Double) throws {
        let timeline = fixture.timeline
        let position = try #require(timeline.position(at: time))
        #expect(timeline.time(at: position) == time)
    }

    static let floatSamples: [Double] = {
        let timeline = TimelineFixture.floatTracks.timeline
        return (0...1000).map { timeline.duration * Double($0) / 1000 } + TimelineFixture.floatStarts
    }()

    @Test(arguments: floatSamples)
    func floatRoundTrips(_ time: Double) throws {
        let timeline = TimelineFixture.floatTracks.timeline
        let position = try #require(timeline.position(at: time))
        let track = timeline.tracks[position.trackIndex]
        #expect(position.offset >= 0 && position.offset <= track.duration)
        #expect(track.start <= time && (time < track.end || position.trackIndex == timeline.tracks.count - 1))
        let roundTrip = try #require(timeline.time(at: position))
        #expect(abs(roundTrip - time) <= 1e-6)
    }

    @Test func timeForTrackOffsetIsClamped() {
        let timeline = TimelineFixture.mp3.timeline
        #expect(timeline.time(trackIndex: 1, offset: 500) == 1500)
        #expect(timeline.time(trackIndex: 1, offset: -10) == 1000)
        #expect(timeline.time(trackIndex: 1, offset: 5000) == 2001)
        #expect(timeline.time(trackIndex: 1, offset: .infinity) == 2001)
        #expect(timeline.time(trackIndex: 1, offset: -.infinity) == 1000)
        #expect(timeline.time(trackIndex: 1, offset: .nan) == 1000)
        #expect(timeline.time(trackIndex: 30, offset: 0) == nil)
        #expect(timeline.time(trackIndex: -1, offset: 0) == nil)
        #expect(TimelineFixture.empty.timeline.time(trackIndex: 0, offset: 0) == nil)
    }

    @Test func normalisesTracks() {
        let mp3 = TimelineFixture.mp3.timeline
        #expect(mp3.tracks.count == 30)
        #expect(mp3.duration == 30_435)
        #expect(mp3.tracks.last?.audioTrack.index == 30)

        let degenerate = TimelineFixture.degenerateTracks.timeline
        #expect(degenerate.tracks.map(\.start) == [0, 0, 50, 50])
        #expect(degenerate.tracks.map(\.duration) == [0, 50, 0, 50])
        #expect(degenerate.duration == 100)

        let unsorted = PlaybackTimeline(
            tracks: [
                AudioTrack(index: 2, startOffset: 100, duration: 50),
                AudioTrack(index: 1, startOffset: 0, duration: 100),
            ],
            chapters: [])
        #expect(unsorted.tracks.map(\.audioTrack.index) == [1, 2])
        #expect(unsorted.tracks.map(\.sourceIndex) == [1, 0])
        #expect(unsorted.position(at: 120) == .init(trackIndex: 1, offset: 20))

        #expect(TimelineFixture.empty.timeline.duration == 0)
        #expect(TimelineFixture.zeroLength.timeline.duration == 0)
    }

    @Test(arguments: [
        (TimelineFixture.overlappingTracks, [95.0, 200]),
        (.gappedTracks, [100, 200]),
        (.degenerateTracks, [0, 50, 50, 100]),
        (.mp3, (1...30).map { TimelineFixture.mp3Start($0) }),
        (.nestedTracks, [300, 100]),
        (.trailingZeroLength, [100, 500]),
    ])
    func playbackEndStopsAtNextTrack(_ fixture: TimelineFixture, _ expected: [Double]) {
        #expect(fixture.timeline.tracks.map(\.playbackEnd) == expected)
    }

    /// `duration` is the reachable end, so clamping, chapters and the last-chapter range agree with it.
    @Test(arguments: [
        (TimelineFixture.nestedTracks, 300.0), (.trailingZeroLength, 100), (.overlappingTracks, 200),
        (.gappedTracks, 200), (.degenerateTracks, 100), (.zeroLength, 0), (.empty, 0),
    ])
    func durationIsReachableEnd(_ fixture: TimelineFixture, _ expected: Double) throws {
        let timeline = fixture.timeline
        #expect(timeline.duration == expected)
        #expect(timeline.clamp(.infinity) == expected)
        if let position = timeline.position(at: .infinity) {
            #expect(timeline.time(at: position) == expected)
        }
        #expect(timeline.chapters.allSatisfy { $0.end <= expected })
        if !timeline.chapters.isEmpty {
            #expect(timeline.endOfChapter(at: expected) == expected)
            #expect(timeline.progressRange(at: expected, chapterTrack: true).end == expected)
        }
    }

    /// A skipped track can start past the reachable end; converting back must stay in `0...duration`.
    @Test func zeroLengthTrackWithNonzeroStartRoundTrips() throws {
        let single = PlaybackTimeline(tracks: [AudioTrack(index: 1, startOffset: 5, duration: 0)], chapters: [])
        #expect(single.duration == 0)
        let position = try #require(single.position(at: 0))
        #expect(position == .init(trackIndex: 0, offset: 0))
        #expect(single.time(at: position) == 0)
        #expect(single.time(trackIndex: 0, offset: 10) == 0)

        let trailing = TimelineFixture.trailingZeroLength.timeline
        #expect(trailing.time(trackIndex: 1, offset: 0) == 100)
        let end = try #require(trailing.position(at: .infinity))
        #expect(trailing.time(at: end) == 100)
    }

    @Test func nestedAndTrailingTracksNormaliseChapters() {
        #expect(TimelineFixture.nestedTracks.timeline.chapters.map(\.end) == [120, 300])
        #expect(TimelineFixture.nestedTracks.timeline.tracks.map(\.isPlayable) == [true, false])
        #expect(TimelineFixture.trailingZeroLength.timeline.chapters.map(\.end) == [100])
    }

    @Test func forwardPlaybackEndTimeIsTrackLocal() {
        let timeline = PlaybackTimeline(
            tracks: [
                AudioTrack(index: 1, startOffset: 0, duration: 1000),
                AudioTrack(index: 2, startOffset: 1000, duration: 100),
                AudioTrack(index: 3, startOffset: 1050, duration: 150),
            ],
            chapters: [])
        let track = timeline.tracks[1]
        #expect(track.playbackEnd == 1050)
        #expect(track.forwardPlaybackEndTime == 50)
        #expect(track.playbackDuration == 50)
        #expect(timeline.tracks.map(\.forwardPlaybackEndTime) == [1000, 50, 150])
        #expect(timeline.time(trackIndex: 1, offset: 80) == 1050)
        #expect(timeline.position(at: 1050) == .init(trackIndex: 2, offset: 0))
    }

    @Test func clampsInfinity() {
        let timeline = TimelineFixture.m4b.timeline
        #expect(timeline.clamp(.infinity) == 36_000)
        #expect(timeline.clamp(-.infinity) == 0)
        #expect(timeline.clamp(.nan) == 0)
        #expect(timeline.currentChapterIndex(at: .infinity) == 4)
        #expect(timeline.currentChapterIndex(at: -.infinity) == 0)
        let range = timeline.progressRange(at: 2000, chapterTrack: true)
        #expect(range.elapsed(at: .infinity) == range.duration)
        #expect(range.time(forElapsed: .infinity) == 5400)
        #expect(range.elapsed(at: .nan) == 0)
    }

    @Test func buildsFromSession() {
        let session = PlaybackSession(
            id: "ses-1", libraryItemId: "li-1", mediaType: .book,
            chapters: [Chapter(id: 0, start: 0, end: 60)], duration: 60,
            audioTracks: [AudioTrack(index: 1, startOffset: 0, duration: 60)])
        let timeline = PlaybackTimeline(session: session)
        #expect(timeline.duration == 60)
        #expect(timeline.chapters.count == 1)
    }

    // MARK: - Chapters

    struct ChapterCase: Sendable, CustomTestStringConvertible {
        let fixture: TimelineFixture
        let time: Double
        let current: Int?
        let next: Double?
        let previous: Double
        let end: Double?

        var testDescription: String { "\(fixture) @ \(time)" }
    }

    static let chapterCases: [ChapterCase] = [
        // m4b, unsorted chapters; chapter 4 is clamped to 36000 and chapter 5 (past the end) dropped.
        .init(fixture: .m4b, time: 0, current: 0, next: 1800.25, previous: 0, end: 1800.25),
        .init(fixture: .m4b, time: 2, current: 0, next: 1800.25, previous: 0, end: 1800.25),
        .init(fixture: .m4b, time: 1800.23, current: 0, next: 1800.25, previous: 0, end: 1800.25),
        .init(fixture: .m4b, time: 1800.245, current: 1, next: 5400, previous: 0, end: 5400),
        .init(fixture: .m4b, time: 1800.25, current: 1, next: 5400, previous: 0, end: 5400),
        .init(fixture: .m4b, time: 1803.25, current: 1, next: 5400, previous: 0, end: 5400),
        .init(fixture: .m4b, time: 1803.26, current: 1, next: 5400, previous: 1800.25, end: 5400),
        .init(fixture: .m4b, time: 35_999, current: 4, next: nil, previous: 30_000, end: 36_000),
        .init(fixture: .m4b, time: 36_000, current: 4, next: nil, previous: 30_000, end: 36_000),
        .init(fixture: .m4b, time: 50_000, current: 4, next: nil, previous: 30_000, end: 36_000),
        // Last chapter ends short of the duration: it stays current to the end of the media.
        .init(fixture: .m4bShortChapters, time: 36_000.25, current: 1, next: nil, previous: 18_000, end: 36_000.25),
        .init(fixture: .m4bShortChapters, time: 36_000.125, current: 1, next: nil, previous: 18_000, end: 36_000.25),
        // Within 0.01 s before an adjacent chapter: that chapter's start tolerance applies.
        .init(fixture: .m4bShortChapters, time: 17_999.995, current: 1, next: nil, previous: 0, end: 36_000.25),
        .init(fixture: .m4bShortChapters, time: 17_999.98, current: 0, next: 18_000, previous: 0, end: 18_000),
        // Chapters crossing file boundaries.
        .init(fixture: .crossingChapters, time: 450, current: 1, next: 1000, previous: 0, end: 1000),
        .init(fixture: .crossingChapters, time: 600, current: 1, next: 1000, previous: 450, end: 1000),
        .init(fixture: .crossingChapters, time: 1000, current: 2, next: nil, previous: 450, end: 1800),
        .init(fixture: .crossingChapters, time: 1200, current: 2, next: nil, previous: 1000, end: 1800),
        .init(fixture: .crossingChapters, time: 1800, current: 2, next: nil, previous: 1000, end: 1800),
        // 30-file mp3, one chapter per file.
        .init(fixture: .mp3, time: 999.995, current: 1, next: 2001, previous: 0, end: 2001),
        .init(fixture: .mp3, time: 1000, current: 1, next: 2001, previous: 0, end: 2001),
        .init(fixture: .mp3, time: 15_000, current: 14, next: 15_105, previous: 14_091, end: 15_105),
        .init(fixture: .mp3, time: 30_435, current: 29, next: nil, previous: 29_406, end: 30_435),
        // Podcast without chapters: previous restarts the episode.
        .init(fixture: .podcast, time: 0, current: nil, next: nil, previous: 0, end: nil),
        .init(fixture: .podcast, time: 100, current: nil, next: nil, previous: 0, end: nil),
        .init(fixture: .empty, time: 100, current: nil, next: nil, previous: 0, end: nil),
        // Gaps and overlaps: chapters 10–100, 150–190 (trimmed), 190–300.
        .init(fixture: .chapterGaps, time: 5, current: nil, next: 10, previous: 0, end: nil),
        .init(fixture: .chapterGaps, time: 10, current: 0, next: 150, previous: 10, end: 100),
        // Within 0.01 s before a chapter end: exact before a gap.
        .init(fixture: .chapterGaps, time: 99.995, current: 0, next: 150, previous: 10, end: 100),
        .init(fixture: .chapterGaps, time: 100, current: nil, next: 150, previous: 10, end: nil),
        .init(fixture: .chapterGaps, time: 189.995, current: 2, next: nil, previous: 150, end: 300),
        .init(fixture: .chapterGaps, time: 120, current: nil, next: 150, previous: 10, end: nil),
        .init(fixture: .chapterGaps, time: 189, current: 1, next: 190, previous: 150, end: 190),
        .init(fixture: .chapterGaps, time: 190, current: 2, next: nil, previous: 150, end: 300),
        .init(fixture: .chapterGaps, time: 300, current: 2, next: nil, previous: 190, end: 300),
    ]

    @Test(arguments: chapterCases)
    func chapters(_ testCase: ChapterCase) {
        let timeline = testCase.fixture.timeline
        #expect(timeline.currentChapterIndex(at: testCase.time) == testCase.current)
        #expect(timeline.nextChapterStart(from: testCase.time) == testCase.next)
        #expect(timeline.previousChapterStart(from: testCase.time) == testCase.previous)
        #expect(timeline.endOfChapter(at: testCase.time) == testCase.end)
    }

    @Test func normalisesChapters() {
        let m4b = TimelineFixture.m4b.timeline
        #expect(m4b.chapters.map(\.id) == [0, 1, 2, 3, 4])
        #expect(m4b.chapters.last?.end == 36_000)
        #expect(m4b.currentChapter(at: 6000)?.title == "Three")

        let gaps = TimelineFixture.chapterGaps.timeline
        #expect(gaps.chapters.map(\.id) == [0, 1, 2])
        #expect(gaps.chapters.map(\.end) == [100, 190, 300])
    }

    @Test func duplicateChapterStartKeepsTheLast() {
        let timeline = PlaybackTimeline(
            tracks: [AudioTrack(index: 1, startOffset: 0, duration: 200)],
            chapters: [
                Chapter(id: 0, start: 0, end: 100), Chapter(id: 1, start: 0, end: 50),
                Chapter(id: 2, start: 100, end: 200),
            ])
        #expect(timeline.chapters.map(\.id) == [1, 2])
        #expect(timeline.chapters.map(\.end) == [50, 200])
        #expect(timeline.currentChapter(at: 25)?.id == 1)
        #expect(timeline.currentChapter(at: 75) == nil)
    }

    @Test func zeroDurationTimelineHasNoChapters() {
        let chapters = [Chapter(id: 0, start: 0, end: 10)]
        #expect(PlaybackTimeline(tracks: [], chapters: chapters).chapters.isEmpty)
        let zeroLength = PlaybackTimeline(
            tracks: [AudioTrack(index: 1, startOffset: 0, duration: 0)], chapters: chapters)
        #expect(zeroLength.chapters.isEmpty)
        #expect(zeroLength.currentChapter(at: 0) == nil)
    }

    // MARK: - Chapter track

    struct RangeCase: Sendable, CustomTestStringConvertible {
        let fixture: TimelineFixture
        let time: Double
        let chapterTrack: Bool
        let start: Double
        let end: Double
        let elapsed: Double

        var testDescription: String { "\(fixture) @ \(time) chapterTrack=\(chapterTrack)" }
    }

    static let rangeCases: [RangeCase] = [
        .init(fixture: .m4b, time: 2000, chapterTrack: true, start: 1800.25, end: 5400, elapsed: 199.75),
        .init(fixture: .m4b, time: 2000, chapterTrack: false, start: 0, end: 36_000, elapsed: 2000),
        .init(fixture: .mp3, time: 1000, chapterTrack: true, start: 1000, end: 2001, elapsed: 0),
        .init(fixture: .mp3, time: 30_435, chapterTrack: true, start: 29_406, end: 30_435, elapsed: 1029),
        .init(
            fixture: .m4bShortChapters, time: 36_000.25, chapterTrack: true, start: 18_000, end: 36_000.25,
            elapsed: 18_000.25),
        .init(fixture: .crossingChapters, time: 600, chapterTrack: true, start: 450, end: 1000, elapsed: 150),
        .init(fixture: .podcast, time: 100, chapterTrack: true, start: 0, end: 2700, elapsed: 100),
        .init(fixture: .chapterGaps, time: 120, chapterTrack: true, start: 0, end: 300, elapsed: 120),
        .init(fixture: .empty, time: 120, chapterTrack: true, start: 0, end: 0, elapsed: 0),
    ]

    @Test(arguments: rangeCases)
    func progressRange(_ testCase: RangeCase) {
        let range = testCase.fixture.timeline.progressRange(at: testCase.time, chapterTrack: testCase.chapterTrack)
        #expect(range.start == testCase.start)
        #expect(range.end == testCase.end)
        #expect(range.elapsed(at: testCase.time) == testCase.elapsed)
        #expect(range.remaining(at: testCase.time) == testCase.end - testCase.start - testCase.elapsed)
    }

    @Test func timelineRangeClampsAndScales() {
        let range = TimelineFixture.m4b.timeline.progressRange(at: 6000, chapterTrack: true)
        #expect(range.duration == 6600)
        #expect(range.elapsed(at: 5000) == 0)
        #expect(range.elapsed(at: 13_000) == 6600)
        #expect(range.fraction(at: 7050) == 0.25)
        #expect(range.time(forElapsed: 30) == 5430)
        #expect(range.time(forElapsed: -30) == 5400)
        #expect(range.time(forElapsed: 9000) == 12_000)
        #expect(TimelineFixture.empty.timeline.progressRange(at: 0, chapterTrack: false).fraction(at: 0) == 0)
    }

    // MARK: - Jumps

    @Test(arguments: [
        (TimelineFixture.m4b, 100.0, 30.0, 130.0, 70.0),
        (.m4b, 35_990, 30, 36_000, 35_960),
        (.m4b, 10, 30, 40, 0),
        (.m4b, 100, -5, 100, 100),
        (.m4b, 50_000, 30, 36_000, 35_970),
        (.mp3, 999, 10, 1009, 989),
        (.podcast, 2690, 30, 2700, 2660),
        (.empty, 10, 30, 0, 0),
        (.m4b, 100, .infinity, 36_000, 0),
        (.m4b, .infinity, 30, 36_000, 35_970),
        (.m4b, -.infinity, 30, 30, 0),
        (.m4b, 100, .nan, 100, 100),
        (.m4b, 100, -.infinity, 100, 100),
    ])
    func jumps(_ fixture: TimelineFixture, _ time: Double, _ interval: Double, _ forward: Double, _ backward: Double) {
        let timeline = fixture.timeline
        #expect(timeline.jumpForward(from: time, by: interval) == forward)
        #expect(timeline.jumpBackward(from: time, by: interval) == backward)
    }
}
