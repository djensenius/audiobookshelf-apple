import Foundation
import Testing

@testable import ABSData

/// The ADR 0003 progress rules on the pure value type.
@Suite struct ProgressSyncStateTests {
    private static let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private static func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

    private static func server(
        currentTime: Double = 100, isFinished: Bool = false, finishedAt: Date? = nil,
        ebookLocation: String? = "epubcfi(/6/2)", ebookProgress: Double? = 0.1, lastUpdate: Date
    ) -> ProgressBaseline {
        ProgressBaseline(
            currentTime: currentTime, progress: currentTime / 1000, duration: 1000, isFinished: isFinished,
            finishedAt: finishedAt, ebookLocation: ebookLocation, ebookProgress: ebookProgress, lastUpdate: lastUpdate)
    }

    private static func seek(_ currentTime: Double) -> ProgressEdit {
        ProgressEdit(audio: .init(currentTime: currentTime, duration: 1000, progress: currentTime / 1000))
    }

    private static func page(_ location: String, _ progress: Double) -> ProgressEdit {
        ProgressEdit(ebook: .init(location: location, progress: progress))
    }

    /// `beginSend()`, requiring a send.
    @discardableResult
    private static func send(
        _ state: inout ProgressSyncState, sourceLocation: SourceLocation = #_sourceLocation
    ) throws -> ProgressSend {
        let send = state.beginSend()
        return try #require(send, sourceLocation: sourceLocation)
    }

    /// A row seeded from server progress at `t0`.
    private static func seeded() -> ProgressSyncState {
        ProgressSyncState(seed: server(lastUpdate: t0))
    }

    // MARK: - Local edits

    @Test func editsMarkOnlyTheirGroupDirty() {
        var state = Self.seeded()
        state.apply(Self.page("epubcfi(/6/8)", 0.4), now: Self.at(10))
        #expect(state.dirty == .ebook)
        #expect(state.ebookEditedAt == Self.at(10))
        #expect(state.audioEditedAt == nil)
        #expect(state.currentTime == 100)
        let values = state.dirtyValues
        #expect(values.audio == nil)
        #expect(values.finished == nil)
        #expect(values.ebook == .init(ebookLocation: "epubcfi(/6/8)", ebookProgress: 0.4, editedAt: Self.at(10)))

        state.apply(ProgressEdit(isFinished: true), now: Self.at(20))
        #expect(state.dirty == [.ebook, .finished])
        #expect(state.finishedAt == Self.at(20))
        state.apply(ProgressEdit(isFinished: false), now: Self.at(30))
        #expect(state.finishedAt == nil)
    }

    @Test func seededRowStartsCleanWithBaseline() {
        let state = Self.seeded()
        #expect(state.dirty.isEmpty)
        #expect(state.serverBaseline == Self.server(lastUpdate: Self.t0))
        #expect(state.ebookLocation == "epubcfi(/6/2)")
        #expect(state.beginSendCopy() == nil)
    }

    // MARK: - Merge

    @Test func cleanGroupsTakeServerValues() {
        var state = Self.seeded()
        let server = Self.server(currentTime: 500, ebookLocation: "x", lastUpdate: Self.at(5))
        let changed = state.merge(server)
        #expect(changed)
        #expect(state.currentTime == 500)
        #expect(state.ebookLocation == "x")
        #expect(state.serverBaseline == server)
        #expect(state.lastUpdate == Self.at(5))
    }

    @Test func serverOlderThanBaselineIsDropped() {
        var state = Self.seeded()
        let changed = state.merge(Self.server(currentTime: 500, lastUpdate: Self.at(-1)))
        #expect(changed == false)
        #expect(state.currentTime == 100)
    }

    @Test func offlineEbookEditSurvivesAudioOnlyServerChange() {
        var state = Self.seeded()
        state.apply(Self.page("epubcfi(/6/8)", 0.4), now: Self.at(10))
        // Another device listened later; the ebook group on the server is unchanged.
        state.merge(Self.server(currentTime: 700, lastUpdate: Self.at(50)))
        #expect(state.currentTime == 700)
        #expect(state.ebookLocation == "epubcfi(/6/8)")
        #expect(state.dirty == .ebook)
    }

    @Test func serverAudioWinsOverOlderDirtyAudioDespiteNewerEbookEdit() {
        var state = Self.seeded()
        state.apply(Self.seek(200), now: Self.at(10))
        state.apply(Self.page("epubcfi(/6/8)", 0.4), now: Self.at(60))
        // The server's audio changed at 30, after our audio edit (10) but before the ebook edit;
        // `lastUpdate` (the row-wide time) must not let the ebook edit's time protect the audio.
        state.merge(Self.server(currentTime: 700, lastUpdate: Self.at(30)))
        #expect(state.currentTime == 700)
        #expect(state.dirty == .ebook)
        #expect(state.ebookLocation == "epubcfi(/6/8)")
    }

    @Test func conflictKeepsLocalEditNewerThanServer() {
        var state = Self.seeded()
        state.apply(Self.seek(200), now: Self.at(40))
        state.merge(Self.server(currentTime: 700, lastUpdate: Self.at(30)))
        #expect(state.currentTime == 200)
        #expect(state.dirty == .audio)
        #expect(state.serverBaseline?.currentTime == 700)
    }

    @Test func dirtyGroupMatchingBaselineStaysDirty() {
        var state = Self.seeded()
        state.apply(Self.seek(200), now: Self.at(10))
        // Same values as the baseline, with a later `lastUpdate` from another group's change.
        state.merge(Self.server(lastUpdate: Self.at(100)))
        #expect(state.currentTime == 200)
        #expect(state.dirty == .audio)
    }

    @Test func excludedGroupsAreNotMerged() {
        var state = Self.seeded()
        state.apply(Self.seek(200), now: Self.at(10))
        state.merge(Self.server(currentTime: 900, ebookLocation: "y", lastUpdate: Self.at(100)), excluding: .audio)
        #expect(state.currentTime == 200)
        #expect(state.dirty == .audio)
        #expect(state.ebookLocation == "y")
        #expect(state.serverBaseline?.currentTime == 100)
        #expect(state.serverBaseline?.ebookLocation == "y")
    }

    // MARK: - Send and acknowledge

    @Test func acknowledgeClearsOnlyGroupsUnchangedSinceTheSnapshot() throws {
        var state = Self.seeded()
        state.apply(Self.seek(200), now: Self.at(10))
        state.apply(Self.page("epubcfi(/6/8)", 0.4), now: Self.at(10))
        let send = try Self.send(&state)
        #expect(send.groups == [.audio, .ebook])
        // Edited while the PATCH is in flight; finished is dirty but wasn't sent.
        state.apply(Self.seek(260), now: Self.at(20))
        state.apply(ProgressEdit(isFinished: true), now: Self.at(20))

        state.acknowledge(send, serverLastUpdate: Self.at(15))
        #expect(state.dirty == [.audio, .finished])
        #expect(state.currentTime == 260)
        #expect(state.serverBaseline?.currentTime == 200)
        #expect(state.serverBaseline?.ebookLocation == "epubcfi(/6/8)")
        #expect(state.serverBaseline?.isFinished == false)
        #expect(state.serverBaseline?.lastUpdate == Self.at(15))
        #expect(state.unacknowledgedSends.isEmpty)

        // The next fetch shows the acknowledged values: the newer edit is kept, not a conflict.
        let fetched = Self.server(
            currentTime: 200, ebookLocation: "epubcfi(/6/8)", ebookProgress: 0.4, lastUpdate: Self.at(15))
        state.merge(fetched)
        #expect(state.currentTime == 260)
        #expect(state.dirty == [.audio, .finished])
    }

    @Test func acknowledgeWithoutBaselineUsesRowValuesForUnsentGroups() throws {
        var state = ProgressSyncState(lastUpdate: Self.t0)
        state.apply(Self.page("a", 0.2), now: Self.at(1))
        let send = try Self.send(&state)
        state.acknowledge(send, serverLastUpdate: nil)
        #expect(state.dirty.isEmpty)
        #expect(state.serverBaseline?.ebookLocation == "a")
        #expect(state.serverBaseline?.currentTime == 0)
        #expect(state.serverBaseline?.lastUpdate == .distantPast)
    }

    @Test func lostResponseEchoKeepsNewerSeekDirty() throws {
        var state = Self.seeded()
        state.apply(Self.seek(200), now: Self.at(10))
        let sendA = try Self.send(&state)
        // The response is lost; the user seeks again.
        state.apply(Self.seek(300), now: Self.at(20))
        // The server's echo of A, written after the newer seek.
        let echo = Self.server(currentTime: 200, lastUpdate: Self.at(25))
        state.merge(echo)
        #expect(state.currentTime == 300)
        #expect(state.dirty == .audio)
        #expect(state.serverBaseline?.currentTime == 200)
        #expect(state.unacknowledgedSends.isEmpty)
        // The retry sends the newer seek, not A.
        #expect(try Self.send(&state).audio?.currentTime == 300)
        #expect(sendA.audio?.currentTime == 200)
    }

    @Test func committedSendIsRecognisedAfterLaterRetryFails() throws {
        var state = Self.seeded()
        state.apply(Self.seek(200), now: Self.at(10))
        try Self.send(&state)  // A commits, response lost.
        state.apply(Self.seek(300), now: Self.at(20))
        try Self.send(&state)  // B fails before reaching the server.
        let fetched = Self.server(currentTime: 200, lastUpdate: Self.at(12))
        state.merge(fetched)
        #expect(state.currentTime == 300)
        #expect(state.dirty == .audio)
        // A and older entries are pruned; B is newer and stays.
        #expect(state.unacknowledgedSends.map { $0.audio?.currentTime } == [300])
    }

    @Test func echoClearsGroupWhenNotEditedSince() throws {
        var state = Self.seeded()
        state.apply(Self.seek(200), now: Self.at(10))
        try Self.send(&state)
        let echo = Self.server(currentTime: 200, lastUpdate: Self.at(12))
        state.merge(echo)
        #expect(state.dirty.isEmpty)
        #expect(state.unacknowledgedSends.isEmpty)
    }

    // MARK: - History overflow and per-group pruning

    @Test func overflowSetsTruncationOnlyForDroppedGroups() throws {
        var state = Self.seeded()
        state.apply(Self.page("first", 0.2), now: Self.at(1))
        try Self.send(&state)  // Carries only ebook; the response is lost.
        for index in 0..<ProgressSend.historyLimit {
            state.apply(Self.seek(Double(200 + index * 10)), now: Self.at(Double(10 + index)))
            try Self.send(&state)
        }
        #expect(state.unacknowledgedSends.count == ProgressSend.historyLimit)
        // The dropped first entry carried only the ebook group.
        #expect(state.truncated == .ebook)
        #expect(state.unacknowledgedSends.allSatisfy { $0.audio != nil })
    }

    @Test func truncatedGroupKeepsLocalOnUnmatchedServerValue() throws {
        var state = Self.seeded()
        state.apply(Self.page("p0", 0.2), now: Self.at(1))
        state.apply(Self.seek(150), now: Self.at(1))
        for index in 0...ProgressSend.historyLimit {
            state.apply(Self.page("p\(index)", 0.2), now: Self.at(Double(2 + index)))
            try Self.send(&state)
        }
        #expect(state.truncated == [.audio, .ebook])
        // An unmatched, newer server ebook value may be a dropped send: local wins and stays dirty.
        state.merge(Self.server(ebookLocation: "unknown", lastUpdate: Self.at(500)))
        #expect(state.ebookLocation == "p\(ProgressSend.historyLimit)")
        #expect(state.dirty.contains(.ebook))

        // A successful PATCH clears the truncation flags.
        let send = try Self.send(&state)
        state.acknowledge(send, serverLastUpdate: Self.at(600))
        #expect(state.truncated.isEmpty)
    }

    @Test func untruncatedGroupStillResolvesConflictsByTime() throws {
        var state = Self.seeded()
        state.apply(Self.page("first", 0.2), now: Self.at(1))
        try Self.send(&state)
        for index in 0..<ProgressSend.historyLimit {
            state.apply(Self.seek(Double(200 + index)), now: Self.at(Double(10 + index)))
            try Self.send(&state)
        }
        #expect(state.truncated == .ebook)
        // Audio isn't truncated: an unmatched, newer server value is a real conflict the server wins.
        let server = Self.server(currentTime: 900, ebookLocation: "first", ebookProgress: 0.2, lastUpdate: Self.at(500))
        state.merge(server)
        #expect(state.currentTime == 900)
        #expect(state.dirty.contains(.audio) == false)
    }

    /// The case from the ADR 0003 review (#37 comment): ebook edit → PATCH A (response lost) →
    /// newer ebook edit → a fetch whose audio matches A. Settling audio must not prune A's ebook
    /// evidence, so A's ebook echo is still recognised and the newer ebook edit survives.
    @Test func audioMatchDoesNotPruneEbookEvidence() throws {
        var state = Self.seeded()
        state.apply(Self.seek(200), now: Self.at(10))
        state.apply(Self.page("A", 0.3), now: Self.at(10))
        let sendA = try Self.send(&state)
        #expect(sendA.groups == [.audio, .ebook])
        state.apply(Self.page("E2", 0.5), now: Self.at(20))

        // Audio matches A; the ebook group still shows the baseline.
        let audioOnly = Self.server(currentTime: 200, lastUpdate: Self.at(15))
        state.merge(audioOnly)
        #expect(state.dirty == .ebook)
        #expect(state.unacknowledgedSends == [ProgressSend(ebook: sendA.ebook)])

        // Later the server shows A's ebook, with a row-wide `lastUpdate` after the newer edit
        // (another device changed audio). Without per-group pruning this would be a conflict the
        // server wins, rolling the ebook back to A.
        let echo = Self.server(currentTime: 800, ebookLocation: "A", ebookProgress: 0.3, lastUpdate: Self.at(90))
        state.merge(echo)
        #expect(state.ebookLocation == "E2")
        #expect(state.ebookProgress == 0.5)
        #expect(state.dirty == .ebook)
        #expect(state.currentTime == 800)
        #expect(state.unacknowledgedSends.isEmpty)
    }

    @Test func matchingOneGroupKeepsOtherGroupsEntriesIntact() throws {
        var state = Self.seeded()
        state.apply(Self.seek(200), now: Self.at(10))
        state.apply(Self.page("A", 0.3), now: Self.at(10))
        try Self.send(&state)
        state.apply(Self.seek(300), now: Self.at(20))
        state.apply(Self.page("B", 0.4), now: Self.at(20))
        let sendB = try Self.send(&state)

        // Ebook echoes A, audio is unchanged from the baseline: only A's ebook is pruned.
        state.merge(Self.server(ebookLocation: "A", ebookProgress: 0.3, lastUpdate: Self.at(30)))
        #expect(state.unacknowledgedSends.count == 2)
        #expect(state.unacknowledgedSends[0].ebook == nil)
        #expect(state.unacknowledgedSends[0].audio?.currentTime == 200)
        #expect(state.unacknowledgedSends[1] == sendB)
        #expect(state.dirty == [.audio, .ebook])
    }
}

extension ProgressSyncState {
    /// `beginSend()` without mutating, for assertions.
    fileprivate func beginSendCopy() -> ProgressSend? {
        var copy = self
        return copy.beginSend()
    }
}
