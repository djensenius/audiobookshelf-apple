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

    /// Records the dirty groups as one unacknowledged entry. `beginSend()` sends one group at a
    /// time, but the merge rules handle entries with several groups too.
    @discardableResult
    private static func recordMixedSend(_ state: inout ProgressSyncState) -> ProgressSend {
        let send = state.dirtyValues
        state.unacknowledgedSends.append(send)
        return send
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

        state.apply(ProgressEdit(isFinished: true), now: Self.at(20.000_6))
        #expect(state.dirty == [.ebook, .finished])
        // Truncated to whole milliseconds, as the server stores it.
        #expect(state.finishedAt == ProgressSyncState.wholeMilliseconds(Self.at(20.000_6)))
        #expect(state.finishedAt != Self.at(20.000_6))
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
        // One group per PATCH, audio first (#53).
        #expect(send.groups == .audio)
        // Edited while the PATCH is in flight.
        state.apply(Self.seek(260), now: Self.at(20))

        state.acknowledge(send, serverLastUpdate: Self.at(15))
        #expect(state.dirty == [.audio, .ebook])
        #expect(state.currentTime == 260)
        #expect(state.serverBaseline?.currentTime == 200)
        #expect(state.serverBaseline?.ebookLocation == "epubcfi(/6/2)")
        #expect(state.serverBaseline?.lastUpdate == Self.at(15))
        #expect(state.unacknowledgedSends.isEmpty)
        // The ebook group is sent next; audio waits for it.
        #expect(state.nextSendGroup == .audio)

        // The next fetch shows the acknowledged values: the newer edit is kept, not a conflict.
        state.merge(Self.server(currentTime: 200, lastUpdate: Self.at(15)))
        #expect(state.currentTime == 260)
        #expect(state.dirty == [.audio, .ebook])
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

    @Test func overflowSetsTruncationForDroppedGroupsAndTheirSideEffects() throws {
        var state = Self.seeded()
        // Finished, not ebook: a dirty ebook group would alternate with the failing audio sends.
        state.apply(ProgressEdit(isFinished: true), now: Self.at(1))
        try Self.send(&state)  // Carries only finished; the response is lost.
        for index in 0..<ProgressSend.historyLimit {
            state.apply(Self.seek(Double(200 + index * 10)), now: Self.at(Double(10 + index)))
            try Self.send(&state)
        }
        #expect(state.unacknowledgedSends.count == ProgressSend.historyLimit)
        // The dropped first entry carried only finished, whose PATCH may also have changed the
        // dirty audio (#53).
        #expect(state.truncated == [.finished, .audio])
        #expect(state.unacknowledgedSends.allSatisfy { $0.audio != nil })
    }

    /// Copilot on #146: the first audio PATCH committed and un-finished the item on the server,
    /// its response was lost, and eight distinct retries pushed it out of the list. Its echo must
    /// still not overwrite the user's pending "finished".
    @Test func evictedAudioSendStillShieldsPendingFinish() throws {
        var state = ProgressSyncState(
            seed: Self.server(currentTime: 1000, isFinished: true, finishedAt: Self.t0, lastUpdate: Self.t0))
        state.apply(Self.seek(300), now: Self.at(1))
        try Self.send(&state)  // Committed at 5 (the server un-finishes); the response is lost.
        state.apply(ProgressEdit(isFinished: true), now: Self.at(2))
        for index in 1...ProgressSend.historyLimit {
            state.apply(Self.seek(Double(300 + index * 10)), now: Self.at(Double(10 + index)))
            try Self.send(&state)  // Fails before reaching the server.
        }
        #expect(state.unacknowledgedSends.allSatisfy { $0.audio?.currentTime != 300 })

        state.merge(Self.server(currentTime: 300, lastUpdate: Self.at(5)))
        #expect(state.isFinished)
        #expect(state.dirty == [.audio, .finished])
    }

    @Test func truncatedGroupKeepsLocalOnUnmatchedServerValue() throws {
        var state = Self.seeded()
        for index in 0...ProgressSend.historyLimit {
            state.apply(Self.page("p\(index)", 0.2), now: Self.at(Double(2 + index)))
            try Self.send(&state)
        }
        #expect(state.truncated == .ebook)
        // An unmatched, newer server ebook value may be a dropped send: local wins and stays dirty.
        state.merge(Self.server(ebookLocation: "unknown", lastUpdate: Self.at(500)))
        #expect(state.ebookLocation == "p\(ProgressSend.historyLimit)")
        #expect(state.dirty.contains(.ebook))

        // A successful PATCH of the group clears its truncation flag and evidence.
        let send = try Self.send(&state)
        state.acknowledge(send, serverLastUpdate: Self.at(600))
        #expect(state.truncated.isEmpty)
        #expect(state.unacknowledgedSends.isEmpty)
    }

    @Test func untruncatedGroupStillResolvesConflictsByTime() throws {
        var state = Self.seeded()
        for index in 0...ProgressSend.historyLimit {
            state.apply(Self.seek(Double(200 + index)), now: Self.at(Double(10 + index)))
            try Self.send(&state)
        }
        #expect(state.truncated == .audio)
        state.apply(Self.page("mine", 0.2), now: Self.at(30))
        // Ebook isn't truncated: an unmatched, newer server value is a real conflict the server wins.
        state.merge(Self.server(currentTime: 900, ebookLocation: "other", lastUpdate: Self.at(500)))
        #expect(state.ebookLocation == "other")
        #expect(state.dirty.contains(.ebook) == false)
        // Audio is truncated: its local value wins.
        #expect(state.currentTime == Double(200 + ProgressSend.historyLimit))
        #expect(state.dirty.contains(.audio))
    }

    /// The case from the ADR 0003 review (#37 comment): ebook edit → PATCH A (response lost) →
    /// newer ebook edit → a fetch whose audio matches A. Settling audio must not prune A's ebook
    /// evidence, so A's ebook echo is still recognised and the newer ebook edit survives.
    @Test func audioMatchDoesNotPruneEbookEvidence() throws {
        var state = Self.seeded()
        state.apply(Self.seek(200), now: Self.at(10))
        state.apply(Self.page("A", 0.3), now: Self.at(10))
        let sendA = Self.recordMixedSend(&state)
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
        Self.recordMixedSend(&state)
        state.apply(Self.seek(300), now: Self.at(20))
        state.apply(Self.page("B", 0.4), now: Self.at(20))
        let sendB = Self.recordMixedSend(&state)

        // Ebook echoes A, audio is unchanged from the baseline: only A's ebook is pruned.
        state.merge(Self.server(ebookLocation: "A", ebookProgress: 0.3, lastUpdate: Self.at(30)))
        #expect(state.unacknowledgedSends.count == 2)
        #expect(state.unacknowledgedSends[0].ebook == nil)
        #expect(state.unacknowledgedSends[0].audio?.currentTime == 200)
        #expect(state.unacknowledgedSends[1] == sendB)
        #expect(state.dirty == [.audio, .ebook])
    }

    /// The #37 scenario when A carried only the ebook group: an ebook edit, PATCH A (response
    /// lost), a newer ebook edit, then fetches. Another device's audio change doesn't touch the
    /// ebook evidence, and A's ebook echo is still recognised.
    @Test func ebookOnlySendEvidenceSurvivesUnrelatedFetches() throws {
        var state = Self.seeded()
        state.apply(Self.page("A", 0.3), now: Self.at(10))
        let sendA = try Self.send(&state)
        #expect(sendA.groups == .ebook)
        state.apply(Self.page("E2", 0.5), now: Self.at(20))

        state.merge(Self.server(currentTime: 700, lastUpdate: Self.at(30)))
        #expect(state.unacknowledgedSends == [sendA])
        state.merge(Self.server(currentTime: 800, ebookLocation: "A", ebookProgress: 0.3, lastUpdate: Self.at(90)))
        #expect(state.ebookLocation == "E2")
        #expect(state.dirty == .ebook)
        #expect(state.currentTime == 800)
        #expect(state.unacknowledgedSends.isEmpty)
    }

    // MARK: - Single-group sends

    @Test func sendsOneGroupAtATimeInOrder() throws {
        var state = Self.seeded()
        state.apply(Self.page("A", 0.3), now: Self.at(1))
        state.apply(ProgressEdit(isFinished: true), now: Self.at(1))
        state.apply(Self.seek(200), now: Self.at(1))
        var order: [ProgressGroups] = []
        while let send = state.beginSend() {
            order.append(send.groups)
            state.acknowledge(send, serverLastUpdate: Self.at(Double(2 + order.count)))
        }
        #expect(order == [.audio, .finished, .ebook])
        #expect(state.dirty.isEmpty)
        #expect(state.unacknowledgedSends.isEmpty)
    }

    @Test func acknowledgeClearsOnlyTheSentGroupsEvidence() throws {
        var state = Self.seeded()
        for index in 0...ProgressSend.historyLimit {
            state.apply(Self.page("p\(index)", 0.2), now: Self.at(Double(1 + index)))
            try Self.send(&state)
        }
        #expect(state.truncated == .ebook)
        state.apply(Self.seek(200), now: Self.at(50))
        let audio = try Self.send(&state)
        state.acknowledge(audio, serverLastUpdate: Self.at(60))
        #expect(state.truncated == .ebook)
        // The audio send pushed out one more ebook entry; its ack removed only the audio entry.
        #expect(state.unacknowledgedSends.count == ProgressSend.historyLimit - 1)
        #expect(state.unacknowledgedSends.allSatisfy { $0.groups == .ebook })
        #expect(state.dirty == .ebook)
    }

    @Test func identicalRetriesDoNotFillTheHistory() throws {
        var state = Self.seeded()
        state.apply(Self.seek(200), now: Self.at(1))
        for _ in 0..<10 {
            try Self.send(&state)  // Each attempt fails.
        }
        #expect(state.unacknowledgedSends.count == 1)
        #expect(state.truncated.isEmpty)
    }

    @Test func doubleAcknowledgeIsIdempotent() throws {
        var state = Self.seeded()
        state.apply(Self.seek(200), now: Self.at(1))
        state.apply(Self.page("A", 0.3), now: Self.at(1))
        let send = try Self.send(&state)
        state.acknowledge(send, serverLastUpdate: Self.at(5))
        let once = state
        state.acknowledge(send, serverLastUpdate: Self.at(5))
        #expect(state == once)
    }

    @Test func acknowledgeNeverMovesBaselineTimeBack() throws {
        var state = Self.seeded()
        state.merge(Self.server(lastUpdate: Self.at(50)))
        state.apply(Self.seek(200), now: Self.at(60))
        let send = try Self.send(&state)
        state.acknowledge(send, serverLastUpdate: Self.at(40))
        #expect(state.serverBaseline?.lastUpdate == Self.at(50))
    }

    @Test func acknowledgeWithoutBaselineThenFreshFetchTakesOtherGroups() throws {
        var state = ProgressSyncState(lastUpdate: Self.t0)
        state.apply(Self.page("a", 0.2), now: Self.at(1))
        let send = try Self.send(&state)
        state.acknowledge(send, serverLastUpdate: nil)
        // The server's other groups differ from the defaults the baseline was filled with.
        let fetched = Self.server(
            currentTime: 500, isFinished: true, finishedAt: Self.at(2), ebookLocation: "a", ebookProgress: 0.2,
            lastUpdate: Self.at(3))
        let changed = state.merge(fetched)
        #expect(changed)
        #expect(state.currentTime == 500)
        #expect(state.isFinished)
        #expect(state.ebookLocation == "a")
        #expect(state.dirty.isEmpty)
        #expect(state.serverBaseline == fetched)
    }

    @Test func finishedEchoMatchesAtMillisecondResolution() throws {
        var state = Self.seeded()
        let tapped = Date(timeIntervalSince1970: 1_800_000_123.456_789)
        state.apply(ProgressEdit(isFinished: true), now: tapped)
        try Self.send(&state)  // The response is lost.
        // The server echoes epoch milliseconds.
        let echo = Self.server(
            isFinished: true, finishedAt: Date(timeIntervalSince1970: 1_800_000_123_456 / 1000),
            lastUpdate: tapped.addingTimeInterval(1))
        state.merge(echo)
        #expect(state.dirty.isEmpty)
        #expect(state.unacknowledgedSends.isEmpty)
    }

    @Test func serverWinningAConflictDropsTheGroupsEvidence() throws {
        var state = Self.seeded()
        state.apply(Self.seek(200), now: Self.at(10))
        state.apply(Self.page("A", 0.3), now: Self.at(10))
        Self.recordMixedSend(&state)
        // Another device wrote later: the server wins audio; the ebook entry stays.
        state.merge(Self.server(currentTime: 900, lastUpdate: Self.at(30)))
        #expect(state.currentTime == 900)
        #expect(state.dirty == .ebook)
        #expect(state.unacknowledgedSends.map(\.groups) == [.ebook])
    }

    // MARK: - Server side effects (#53)

    /// Finished progress, seek back, PATCH A (audio) in flight, the user marks it finished, and
    /// the server un-finishes when applying A. The user's "finished" must survive.
    @Test func userFinishSurvivesServerUnfinishFromAudioPatch() throws {
        var state = ProgressSyncState(
            seed: Self.server(currentTime: 1000, isFinished: true, finishedAt: Self.t0, lastUpdate: Self.t0))
        state.apply(Self.seek(300), now: Self.at(10))
        let sendA = try Self.send(&state)
        state.apply(ProgressEdit(isFinished: true), now: Self.at(20))
        state.acknowledge(sendA, serverLastUpdate: Self.at(30))

        state.merge(Self.server(currentTime: 300, lastUpdate: Self.at(30)))
        #expect(state.isFinished)
        #expect(state.dirty == .finished)
        let finish = try Self.send(&state)
        #expect(finish.finished?.isFinished == true)
        state.acknowledge(finish, serverLastUpdate: Self.at(40))
        #expect(state.dirty.isEmpty)
        #expect(state.truncated.isEmpty)
    }

    /// The mirror: the user un-finishes and seeks near the end; the server auto-finishes when
    /// applying the audio PATCH, whose response is lost.
    @Test func userUnfinishSurvivesServerAutoFinishFromLostAudioPatch() throws {
        var state = ProgressSyncState(
            seed: Self.server(currentTime: 1000, isFinished: true, finishedAt: Self.t0, lastUpdate: Self.t0))
        state.apply(ProgressEdit(isFinished: false), now: Self.at(10))
        state.apply(Self.seek(995), now: Self.at(10))
        try Self.send(&state)  // Audio; the server auto-finishes, the response is lost.

        state.merge(Self.server(currentTime: 995, isFinished: true, finishedAt: Self.at(15), lastUpdate: Self.at(15)))
        #expect(state.isFinished == false)
        #expect(state.dirty == .finished)
        let unfinish = try Self.send(&state)
        #expect(unfinish.finished?.isFinished == false)
    }

    /// The #53 race while the audio PATCH is in flight: its socket echo, carrying the server's
    /// auto-finish, arrives before the HTTP response and is merged with audio excluded.
    @Test func userUnfinishSurvivesAutoFinishEchoWhileAudioIsInFlight() throws {
        var state = ProgressSyncState(
            seed: Self.server(currentTime: 1000, isFinished: true, finishedAt: Self.t0, lastUpdate: Self.t0))
        state.apply(ProgressEdit(isFinished: false), now: Self.at(10))
        state.apply(Self.seek(995), now: Self.at(10))
        let audio = try Self.send(&state)
        #expect(audio.groups == .audio)

        state.merge(
            Self.server(currentTime: 995, isFinished: true, finishedAt: Self.at(15), lastUpdate: Self.at(15)),
            excluding: .audio)
        #expect(state.isFinished == false)
        #expect(state.dirty == [.audio, .finished])
        state.acknowledge(audio, serverLastUpdate: Self.at(15))
        let unfinish = try Self.send(&state)
        #expect(unfinish.finished?.isFinished == false)
    }

    /// The mirror: a seek made while a finished PATCH is in flight survives the echo of the
    /// server's `currentTime` reset.
    @Test func seekSurvivesCurrentTimeResetEchoWhileFinishedIsInFlight() throws {
        var state = ProgressSyncState(
            seed: Self.server(currentTime: 1000, isFinished: true, finishedAt: Self.t0, lastUpdate: Self.t0))
        state.apply(ProgressEdit(isFinished: false), now: Self.at(10))
        let finished = try Self.send(&state)
        #expect(finished.groups == .finished)
        state.apply(Self.seek(400), now: Self.at(12))

        state.merge(Self.server(currentTime: 0, lastUpdate: Self.at(15)), excluding: .finished)
        #expect(state.currentTime == 400)
        #expect(state.dirty == [.audio, .finished])
        state.acknowledge(finished, serverLastUpdate: Self.at(15))
        let seek = try Self.send(&state)
        #expect(seek.audio?.currentTime == 400)
    }

    @Test func failingAudioDoesNotBlockEbook() throws {
        var state = Self.seeded()
        state.apply(Self.seek(200), now: Self.at(1))
        state.apply(Self.page("A", 0.3), now: Self.at(1))
        #expect(try Self.send(&state).groups == .audio)  // Fails.
        #expect(try Self.send(&state).groups == .ebook)  // Fails too.
        #expect(try Self.send(&state).groups == .audio)
        let ebook = try Self.send(&state)
        #expect(ebook.groups == .ebook)
        state.acknowledge(ebook, serverLastUpdate: Self.at(2))
        #expect(state.dirty == .audio)
        #expect(state.nextSendGroup == .audio)
        // Finished still waits for audio.
        state.apply(ProgressEdit(isFinished: true), now: Self.at(3))
        #expect(state.nextSendGroup == .audio)
    }

    /// Without server progress, an ebook PATCH would create it with zero audio (#53), so audio
    /// and finished go first even while they keep failing.
    @Test func withoutBaselineEbookWaitsForAudio() throws {
        var state = ProgressSyncState(lastUpdate: Self.t0)
        state.apply(Self.seek(200), now: Self.at(1))
        state.apply(Self.page("A", 0.3), now: Self.at(1))
        #expect(try Self.send(&state).groups == .audio)  // Fails before reaching the server.
        #expect(try Self.send(&state).groups == .audio)
        #expect(state.nextSendGroup == .audio)
    }

    /// An ebook PATCH that creates the server's progress (zero audio, unfinished) can't overwrite
    /// audio and finished edits made while it was in flight, whether its echo is merged before
    /// or after the acknowledgement.
    @Test(arguments: [false, true])
    func ebookCreatingProgressCannotZeroPendingEdits(acknowledgeFirst: Bool) throws {
        var state = ProgressSyncState(lastUpdate: Self.t0)
        state.apply(Self.page("A", 0.3), now: Self.at(1))
        let ebook = try Self.send(&state)
        state.apply(Self.seek(200), now: Self.at(2))
        state.apply(ProgressEdit(isFinished: true), now: Self.at(2))
        let created = Self.server(currentTime: 0, ebookLocation: "A", ebookProgress: 0.3, lastUpdate: Self.at(5))
        if acknowledgeFirst {
            state.acknowledge(ebook, serverLastUpdate: Self.at(5))
            state.merge(created)
        } else {
            state.merge(created, excluding: .ebook)
            state.acknowledge(ebook, serverLastUpdate: Self.at(5))
        }
        #expect(state.currentTime == 200)
        #expect(state.isFinished)
        #expect(state.dirty == [.audio, .finished])
        let audio = try Self.send(&state)
        #expect(audio.audio?.currentTime == 200)
    }

    /// Offline playback without server progress, then another device listens further: a plain
    /// fetch is a real conflict the newer server value wins, not a side effect to shield.
    @Test func plainFetchWithoutBaselineDoesNotShield() {
        var state = ProgressSyncState(lastUpdate: Self.t0)
        state.apply(Self.seek(200), now: Self.at(1))
        state.merge(Self.server(currentTime: 700, lastUpdate: Self.at(50)))
        #expect(state.currentTime == 700)
        #expect(state.dirty.isEmpty)
        #expect(state.truncated.isEmpty)
    }

    /// The echo of a lost send that created the server's progress still shields the other
    /// dirty groups from the created defaults.
    @Test func echoOfLostCreatingSendStillShields() throws {
        var state = ProgressSyncState(lastUpdate: Self.t0)
        state.apply(Self.seek(200), now: Self.at(1))
        try Self.send(&state)  // Created the progress; the response is lost.
        state.apply(Self.page("A", 0.3), now: Self.at(2))
        state.merge(Self.server(currentTime: 200, ebookLocation: nil, ebookProgress: nil, lastUpdate: Self.at(5)))
        #expect(state.ebookLocation == "A")
        #expect(state.dirty == .ebook)
        #expect(state.truncated == .ebook)
    }

    /// Copilot on #146: progress created by an audio PATCH at 995 of 1000 s isn't auto-finished,
    /// but the next PATCH, even ebook-only, auto-finishes it (`MediaProgress.applyProgressUpdate`).
    /// A seek and an explicit "not finished" made while that ebook PATCH is in flight survive,
    /// whether its echo is merged before or after the acknowledgement.
    @Test(arguments: [false, true])
    func ebookPatchAutoFinishCannotOverwritePendingEdits(acknowledgeFirst: Bool) throws {
        var state = ProgressSyncState(seed: Self.server(currentTime: 995, lastUpdate: Self.t0))
        state.apply(Self.page("A", 0.3), now: Self.at(1))
        let ebook = try Self.send(&state)
        state.apply(Self.seek(300), now: Self.at(2))
        state.apply(ProgressEdit(isFinished: false), now: Self.at(2))
        var finished = Self.server(
            currentTime: 995, isFinished: true, finishedAt: Self.at(5), ebookLocation: "A", ebookProgress: 0.3,
            lastUpdate: Self.at(5))
        finished.progress = 1
        if acknowledgeFirst {
            state.acknowledge(ebook, serverLastUpdate: Self.at(5))
            state.merge(finished)
        } else {
            state.merge(finished, excluding: .ebook)
            state.acknowledge(ebook, serverLastUpdate: Self.at(5))
        }
        #expect(state.currentTime == 300)
        #expect(state.isFinished == false)
        #expect(state.dirty == [.audio, .finished])
    }

    /// Copilot on #146: auto-finishing an audio PATCH at 995 of 1000 s stores `progress` 1, not
    /// the 0.995 sent. A seek made while it was in flight survives its echo, whether the PATCH
    /// was acknowledged or its response was lost.
    @Test(arguments: [false, true])
    func autoFinishNormalizedProgressStillMatchesOurSend(acknowledged: Bool) throws {
        var state = ProgressSyncState(seed: Self.server(currentTime: 900, lastUpdate: Self.t0))
        state.apply(Self.seek(995), now: Self.at(1))
        let audio = try Self.send(&state)
        state.apply(Self.seek(300), now: Self.at(2))
        if acknowledged { state.acknowledge(audio, serverLastUpdate: Self.at(5)) }
        var echo = Self.server(currentTime: 995, isFinished: true, finishedAt: Self.at(5), lastUpdate: Self.at(5))
        echo.progress = 1
        state.merge(echo)
        #expect(state.currentTime == 300)
        #expect(state.dirty == .audio)
        #expect(state.isFinished)
    }

    // MARK: - Interleavings

    /// Random interleavings against a simulated server. A PATCH reaches the server at a random
    /// point between `beginSend()` and its outcome, with the #53 side effects; another device
    /// writes now and then; fetches may be stale.
    /// Odd seeds run short episodes that start without server progress, which the first PATCH
    /// creates. Each run ends by stopping the other device and syncing until nothing is dirty.
    @Test(arguments: [1, 7, 37, 2026, 53, 54] as [UInt64])
    func randomInterleavingsKeepTheInvariants(seed: UInt64) throws {
        let seeded = seed.isMultiple(of: 2)
        for episode in 0..<(seeded ? 1 : 25) {
            var sim = Simulation(
                seed: seed &* 1000 &+ UInt64(episode), server: seeded ? Self.server(lastUpdate: Self.t0) : nil)
            for step in 0..<(seeded ? 500 : 20) {
                try sim.step(step, now: Self.at(Double(step + 1)))
            }
            sim.converge(from: Self.at(1000))
        }
    }
}

/// Where the server's value of a group came from.
private enum Origin: Equatable {
    /// Our send of the edit made at that time, possibly normalized by the server.
    case ours(Date)
    case sideEffect(Date)
    case other
}

/// The interleaving simulation for ``ProgressSyncStateTests``.
private struct Simulation {
    var random: SeededGenerator
    var state: ProgressSyncState
    var server: ProgressBaseline
    /// Whether the server has progress for the media yet.
    var exists: Bool
    var origins: [Int: Origin] = [:]
    var lastOtherWrite = Date.distantPast
    var inFlight: ProgressSend?
    var delivered: Date?
    /// A fetch captured earlier, valid while `epoch` (bumped by edits and settlements) is unchanged.
    var captured: (server: ProgressBaseline, origins: [Int: Origin], epoch: Int)?
    var epoch = 0

    init(seed: UInt64, server: ProgressBaseline?) {
        random = SeededGenerator(seed: seed)
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        state = server.map { ProgressSyncState(seed: $0) } ?? ProgressSyncState(lastUpdate: start)
        exists = server != nil
        self.server =
            server
            ?? ProgressBaseline(
                currentTime: 0, progress: 0, duration: 0, isFinished: false, ebookLocation: nil, lastUpdate: start)
    }

    mutating func roll(_ count: Int) -> Int { Int.random(in: 0..<count, using: &random) }

    mutating func step(_ step: Int, now: Date) throws {
        switch roll(10) {
        case 0, 1, 2:
            edit(step, now: now)
        case 3:
            if inFlight == nil { inFlight = state.beginSend() }
        case 4:
            deliver(now: now)
        case 5:
            try settle(step, now: now)
        case 6:
            otherDevice(now: now)
        case 7:
            captured = exists ? (server, origins, epoch) : nil
        case 8 where roll(4) == 0:
            // A relaunch: the in-flight send is forgotten (its entry stays) and no fetch survives.
            if roll(2) == 0 { deliver(now: now) }
            inFlight = nil
            delivered = nil
            captured = nil
            epoch += 1
        default:
            guard exists else { break }
            if roll(3) == 0, let captured, captured.epoch == epoch {
                merge(captured.server, origins: captured.origins, fresh: false, step: step)
            } else {
                merge(server, origins: origins, fresh: true, step: step)
            }
        }
        #expect(state.unacknowledgedSends.count <= ProgressSend.historyLimit, "step \(step)")
    }

    mutating func edit(_ step: Int, now: Date) {
        switch roll(3) {
        case 0:
            let time = roll(2) == 0 ? Double(985 + roll(15)) : Double(roll(985))
            state.apply(
                ProgressEdit(audio: .init(currentTime: time, duration: 1000, progress: time / 1000)), now: now)
        case 1:
            state.apply(ProgressEdit(isFinished: roll(2) == 0), now: now)
        default:
            state.apply(ProgressEdit(ebook: .init(location: "loc\(step)", progress: 0.5)), now: now)
        }
        epoch += 1
    }

    /// The PATCH reaches the server, which applies it like audiobookshelf 2.26.0 to master:
    /// `User.createUpdateMediaProgressFromPayload` creates missing progress from the payload with
    /// defaults and no auto-finish; `MediaProgress.applyProgressUpdate` updates existing progress
    /// with the #53 side effects.
    mutating func deliver(now: Date) {
        guard let send = inFlight, delivered == nil else { return }
        delivered = now
        let created = !exists
        if created {
            exists = true
            for index in 0..<3 { origins[index] = .sideEffect(now) }
        }
        let wasFinished = server.isFinished
        let oldTime = server.currentTime
        if let finished = send.finished {
            server.finishedAt =
                finished.isFinished ? finished.finishedAt ?? ProgressSyncState.wholeMilliseconds(now) : nil
            if created || finished.isFinished != wasFinished {
                // Finishing sets `progress` to 1; un-finishing resets `progress` and `currentTime`.
                if finished.isFinished { server.progress = 1 }
                if !created, !finished.isFinished {
                    server.progress = 0
                    server.currentTime = 0
                }
                if !created { origins[0] = .sideEffect(now) }
            }
            server.isFinished = finished.isFinished
            origins[1] = .ours(finished.editedAt)
        } else if let audio = send.audio,
            created || audio.progress != (server.duration > 0 ? min(1, server.currentTime / server.duration) : 0)
        {
            // An audio `progress` equal to the old `currentTime / duration` is ignored.
            server.progress = audio.progress
        }
        if let audio = send.audio {
            server.currentTime = audio.currentTime
            server.duration = audio.duration
            origins[0] = .ours(audio.editedAt)
        }
        if let ebook = send.ebook {
            server.ebookLocation = ebook.ebookLocation
            server.ebookProgress = ebook.ebookProgress
            origins[2] = .ours(ebook.editedAt)
        }
        // Existing progress is checked after every PATCH, ebook-only too: fewer than 10 s left
        // auto-finishes (`progress` 1), and a `currentTime` change away from the end un-finishes.
        let nearEnd = server.duration > 0 && server.duration - server.currentTime < 10
        if !created, !server.isFinished, nearEnd {
            server.isFinished = true
            server.finishedAt = server.finishedAt ?? ProgressSyncState.wholeMilliseconds(now)
            server.progress = 1
            // An un-finish sent near the end can't stick: the server's form of our own value.
            origins[1] = send.finished.map { .ours($0.editedAt) } ?? .sideEffect(now)
            if send.audio == nil { origins[0] = .sideEffect(now) }
        } else if !created, server.isFinished, server.currentTime != oldTime, !nearEnd {
            server.isFinished = false
            server.finishedAt = nil
            origins[1] = .sideEffect(now)
        }
        server.lastUpdate = now
    }

    /// The PATCH's outcome: delivered or not, the response arrives or is lost.
    mutating func settle(_ step: Int, now: Date) throws {
        guard let send = inFlight else { return }
        if delivered == nil, roll(2) == 0 { deliver(now: now) }
        if let delivered, roll(3) != 0 {
            state.acknowledge(send, serverLastUpdate: delivered)
            let once = state
            state.acknowledge(send, serverLastUpdate: delivered)
            #expect(state == once, "double ack at step \(step)")
        }
        inFlight = nil
        delivered = nil
        epoch += 1
    }

    mutating func otherDevice(now: Date) {
        let group = roll(3)
        switch group {
        case 0:
            // Sometimes near the end without finishing, as progress created by a PATCH can be.
            server.currentTime = Double(roll(2) == 0 ? 990 + roll(10) : roll(1000))
            server.duration = 1000
            server.progress = server.currentTime / 1000
        case 1:
            server.isFinished.toggle()
            server.finishedAt = server.isFinished ? ProgressSyncState.wholeMilliseconds(now) : nil
        default:
            server.ebookLocation = "other\(roll(1000))"
        }
        if !exists {
            exists = true
            for index in 0..<3 { origins[index] = .other }
        }
        origins[group] = .other
        server.lastUpdate = now
        lastOtherWrite = now
    }

    /// Syncs without other writers until nothing is dirty; local then equals the server, and
    /// another device's values taken by the first fetch survive (unless our sends' side effects
    /// change them).
    mutating func converge(from start: Date) {
        var now = start
        if let send = inFlight {
            deliver(now: now)
            state.acknowledge(send, serverLastUpdate: delivered ?? now)
            inFlight = nil
            delivered = nil
        }
        if exists { merge(server, origins: origins, fresh: true, step: 9998) }
        let taken = ProgressGroups.each.enumerated().filter {
            origins[$0.offset] == .other && !state.dirty.contains($0.element)
        }
        let takenValues = taken.map { Self.values($0.element, of: state) }
        var sent: ProgressGroups = []
        for _ in 0..<20 {
            now += 10
            if inFlight == nil { inFlight = state.beginSend() }
            guard let send = inFlight else { break }
            sent.formUnion(send.groups)
            deliver(now: now)
            state.acknowledge(send, serverLastUpdate: now)
            inFlight = nil
            delivered = nil
        }
        if exists { merge(server, origins: origins, fresh: true, step: 9999) }
        #expect(state.dirty.isEmpty)
        #expect(state.nextSendGroup == nil)
        if exists {
            for group in ProgressGroups.each {
                #expect(Self.values(group, of: state) == Self.values(group, of: server), "\(group.rawValue)")
            }
        }
        for (taken, value) in zip(taken, takenValues) {
            if Self.causes(taken.element).isDisjoint(with: sent) {
                #expect(Self.values(taken.element, of: state) == value, "other device's \(taken.element.rawValue) lost")
            }
        }
    }

    mutating func merge(_ fetched: ProgressBaseline, origins: [Int: Origin], fresh: Bool, step: Int) {
        let before = state
        let excluded = inFlight?.groups ?? []
        state.merge(fetched, excluding: excluded)
        for (index, group) in ProgressGroups.each.enumerated() {
            let changed = Self.values(group, of: state) != Self.values(group, of: before)
            if before.dirty.contains(group), changed {
                let editedAt = before.editedAt(group) ?? .distantPast
                let allowed: Bool
                switch origins[index] {
                // Only the very edit we sent may take its (normalized) server value.
                case .ours(let sentEditedAt): allowed = sentEditedAt == editedAt
                case .sideEffect(let at): allowed = lastOtherWrite > max(at, editedAt)
                case .other, nil: allowed = fetched.lastUpdate > editedAt
                }
                #expect(allowed, "dirty \(group.rawValue) lost to \(String(describing: origins[index])) at \(step)")
            }
            // Liveness: a newer write from another device wins unless something justifies keeping ours.
            let justified =
                excluded.contains(group) || before.truncated.contains(group)
                || before.serverBaseline.map { ProgressSyncState.matches(fetched, $0, group) } ?? false
                || before.unacknowledgedSends.contains { ProgressSyncState.matches(fetched, $0, group) }
                // #53, modelled independently of the code: a group whose PATCH can change this one
                // is in flight or echoed.
                || !Self.causes(group).isDisjoint(with: excluded)
                || ProgressGroups.each.contains { cause in
                    Self.causes(group).contains(cause)
                        && before.unacknowledgedSends.contains { ProgressSyncState.matches(fetched, $0, cause) }
                }
                || (before.serverBaseline == nil && (inFlight != nil || !before.unacknowledgedSends.isEmpty))
            if fresh, before.dirty.contains(group), origins[index] == .other,
                fetched.lastUpdate > before.editedAt(group) ?? .distantPast, !justified
            {
                #expect(
                    state.dirty.contains(group) == false, "other device's newer \(group.rawValue) ignored at \(step)")
            }
            if fresh, !excluded.contains(group), !state.dirty.contains(group) {
                #expect(
                    Self.values(group, of: state) == Self.values(group, of: fetched),
                    "unsynced \(group.rawValue) is clean at step \(step)")
            }
        }
    }

    /// The groups whose PATCH can change `group` as a #53 side effect: finishing sets `progress`
    /// to 1 and un-finishing resets audio; an audio PATCH can un-finish or auto-finish; any PATCH,
    /// ebook included, can auto-finish (setting `progress` to 1).
    static func causes(_ group: ProgressGroups) -> ProgressGroups {
        switch group {
        case .audio: [.finished, .ebook]
        case .finished: [.audio, .ebook]
        default: []
        }
    }

    static func values(_ group: ProgressGroups, of state: ProgressSyncState) -> [String] {
        switch group {
        case .audio: ["\(state.currentTime)", "\(state.progress)", "\(state.duration)"]
        case .finished: ["\(state.isFinished)", "\(String(describing: state.finishedAt))"]
        default: ["\(String(describing: state.ebookLocation))", "\(String(describing: state.ebookProgress))"]
        }
    }

    static func values(_ group: ProgressGroups, of server: ProgressBaseline) -> [String] {
        switch group {
        case .audio: ["\(server.currentTime)", "\(server.progress)", "\(server.duration)"]
        case .finished: ["\(server.isFinished)", "\(String(describing: server.finishedAt))"]
        default: ["\(String(describing: server.ebookLocation))", "\(String(describing: server.ebookProgress))"]
        }
    }
}

/// A deterministic generator (SplitMix64) for reproducible interleavings.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}

extension ProgressSyncState {
    /// `beginSend()` without mutating, for assertions.
    fileprivate func beginSendCopy() -> ProgressSend? {
        var copy = self
        return copy.beginSend()
    }
}
