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

    // MARK: - Interleavings

    /// Random interleavings of edits, sends, outcomes and fetches against a simulated server
    /// that changes only through our PATCHes.
    @Test func randomInterleavingsKeepTheInvariants() throws {
        var random = SeededGenerator(seed: 37)
        var state = ProgressSyncState(seed: Self.server(lastUpdate: Self.t0))
        var server = Self.server(lastUpdate: Self.t0)
        var expected = state
        var inFlight: ProgressSend?
        var clock = 1.0
        for step in 0..<500 {
            clock += 1
            let now = Self.at(clock)
            switch Int.random(in: 0..<6, using: &random) {
            case 0, 1:
                let edit = Self.randomEdit(step: step, using: &random)
                state.apply(edit, now: now)
                expected.apply(edit, now: now)
            case 2:
                if inFlight == nil { inFlight = state.beginSend() }
            case 3:
                guard let send = inFlight else { break }
                inFlight = nil
                let outcome = Int.random(in: 0..<3, using: &random)
                if outcome < 2 { Self.applyPatch(send, to: &server, at: now) }
                if outcome == 0 {
                    state.acknowledge(send, serverLastUpdate: now)
                    let once = state
                    state.acknowledge(send, serverLastUpdate: now)
                    #expect(state == once, "double ack at step \(step)")
                }
            default:
                state.merge(server, excluding: inFlight?.groups ?? [])
            }
            for group in ProgressGroups.each {
                #expect(Self.values(group, of: state) == Self.values(group, of: expected), "reverted at \(step)")
                if Self.values(group, of: state) != Self.values(group, of: server) {
                    #expect(state.dirty.contains(group), "unsynced but clean at step \(step)")
                }
            }
            #expect(state.unacknowledgedSends.count <= ProgressSend.historyLimit)
        }
    }

    private static func randomEdit(step: Int, using random: inout SeededGenerator) -> ProgressEdit {
        switch Int.random(in: 0..<3, using: &random) {
        case 0: seek(Double(2 * step % 999))
        case 1: ProgressEdit(isFinished: Bool.random(using: &random))
        default: page("loc\(step)", Double(step % 100) / 100)
        }
    }

    private static func applyPatch(_ send: ProgressSend, to server: inout ProgressBaseline, at now: Date) {
        if let audio = send.audio {
            server.currentTime = audio.currentTime
            server.progress = audio.progress
            server.duration = audio.duration
        }
        if let finished = send.finished {
            server.isFinished = finished.isFinished
            server.finishedAt = finished.finishedAt
        }
        if let ebook = send.ebook {
            server.ebookLocation = ebook.ebookLocation
            server.ebookProgress = ebook.ebookProgress
        }
        server.lastUpdate = now
    }

    private static func values(_ group: ProgressGroups, of state: ProgressSyncState) -> [String] {
        switch group {
        case .audio: ["\(state.currentTime)", "\(state.progress)", "\(state.duration)"]
        case .finished: ["\(state.isFinished)", "\(String(describing: state.finishedAt))"]
        default: ["\(String(describing: state.ebookLocation))", "\(String(describing: state.ebookProgress))"]
        }
    }

    private static func values(_ group: ProgressGroups, of server: ProgressBaseline) -> [String] {
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
