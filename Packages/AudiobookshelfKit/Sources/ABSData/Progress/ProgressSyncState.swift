import Foundation

/// The field groups of a progress row. Each local change marks only the groups it touched, and a
/// PATCH sends only the dirty groups (ADR 0003):
/// - `audio`: `currentTime`, `progress`, `duration`;
/// - `finished`: `isFinished`, `finishedAt`;
/// - `ebook`: `ebookLocation`, `ebookProgress`.
public struct ProgressGroups: OptionSet, Sendable, Hashable {
    public let rawValue: Int

    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let audio = ProgressGroups(rawValue: 1 << 0)
    public static let finished = ProgressGroups(rawValue: 1 << 1)
    public static let ebook = ProgressGroups(rawValue: 1 << 2)
    public static let all: ProgressGroups = [.audio, .finished, .ebook]

    /// The single groups, in a fixed order.
    static let each: [ProgressGroups] = [.audio, .finished, .ebook]
}

/// A local progress change. Only the non-`nil` groups are changed and become dirty.
public struct ProgressEdit: Sendable, Equatable {
    public var audio: Audio?
    /// Whether the media is finished; `finishedAt` becomes the edit time when `true`, else `nil`.
    public var isFinished: Bool?
    public var ebook: Ebook?

    public init(audio: Audio? = nil, isFinished: Bool? = nil, ebook: Ebook? = nil) {
        self.audio = audio
        self.isFinished = isFinished
        self.ebook = ebook
    }

    public struct Audio: Sendable, Equatable {
        public var currentTime: Double
        public var duration: Double
        public var progress: Double

        public init(currentTime: Double, duration: Double, progress: Double) {
            self.currentTime = currentTime
            self.duration = duration
            self.progress = progress
        }
    }

    public struct Ebook: Sendable, Equatable {
        public var location: String?
        public var progress: Double?

        public init(location: String?, progress: Double?) {
            self.location = location
            self.progress = progress
        }
    }
}

extension ProgressSend {
    /// The groups this send carries.
    public var groups: ProgressGroups {
        var groups: ProgressGroups = []
        if audio != nil { groups.insert(.audio) }
        if finished != nil { groups.insert(.finished) }
        if ebook != nil { groups.insert(.ebook) }
        return groups
    }

    func editedAt(_ group: ProgressGroups) -> Date? {
        switch group {
        case .audio: audio?.editedAt
        case .finished: finished?.editedAt
        default: ebook?.editedAt
        }
    }

    /// Only `group`'s values, for a single-group PATCH.
    func only(_ group: ProgressGroups) -> ProgressSend {
        var send = self
        send.remove(ProgressGroups.all.subtracting(group))
        return send
    }

    mutating func remove(_ group: ProgressGroups) {
        if group.contains(.audio) { audio = nil }
        if group.contains(.finished) { finished = nil }
        if group.contains(.ebook) { ebook = nil }
    }
}

/// The sync bookkeeping of one `LocalMediaProgress` row as a value, so the ADR 0003 rules (local
/// edits, sends, acknowledgements and merges) are pure functions tested without a store.
///
/// Each PATCH carries one group, audio first, then finished, then ebook (#53: the server
/// mishandles audio and finished in one body, and audio must go before finished). Once a server
/// baseline exists, ebook is independent: after an unanswered audio or finished send it goes
/// next, so a PATCH that keeps failing can't block it.
///
/// Conflicts compare the device clock (`<group>EditedAt`) with the server clock (`lastUpdate`), so
/// a device whose clock runs ahead of the server's wins conflicts it should lose, and one running
/// behind loses them.
///
/// The `<group>HistoryTruncated` flags (``truncated``) mean "the server's value for the group may
/// come from our own sends, so the dirty local value wins". They are set when a send entry is
/// dropped from the full list, and when the server may have changed the group as a side effect
/// of another PATCH (#53: an audio PATCH can un-finish or auto-finish, a finished one can reset
/// audio, any PATCH can auto-finish, and one without server progress creates defaults): when
/// that PATCH is acknowledged, when an echo matches it after its response was lost, when server
/// progress is merged while it is in flight, and when its entry is dropped from the full list.
/// A group's flag clears when its own send is acknowledged or it stops being dirty.
struct ProgressSyncState: Sendable, Equatable {
    var currentTime: Double = 0
    var progress: Double = 0
    var duration: Double = 0
    var isFinished = false
    var finishedAt: Date?
    var ebookLocation: String?
    var ebookProgress: Double?
    var lastUpdate: Date
    var dirty: ProgressGroups = []
    var audioEditedAt: Date?
    var finishedEditedAt: Date?
    var ebookEditedAt: Date?
    var serverBaseline: ProgressBaseline?
    /// Oldest first, at most `ProgressSend.historyLimit`.
    var unacknowledgedSends: [ProgressSend] = []
    /// Groups whose `<group>HistoryTruncated` flag is set.
    var truncated: ProgressGroups = []

    /// A row seeded from known server progress: every field and the baseline, nothing dirty.
    init(seed server: ProgressBaseline) {
        lastUpdate = server.lastUpdate
        take(.all, from: server)
        serverBaseline = server
    }

    /// A row with default values and no baseline.
    init(lastUpdate: Date) {
        self.lastUpdate = lastUpdate
    }

    // MARK: - Local edits

    /// Applies a local change: marks each changed group dirty and sets its edit time to `now`.
    mutating func apply(_ edit: ProgressEdit, now: Date) {
        if let audio = edit.audio {
            currentTime = audio.currentTime
            duration = audio.duration
            progress = audio.progress
            dirty.insert(.audio)
            audioEditedAt = now
        }
        if let finished = edit.isFinished {
            isFinished = finished
            // Whole milliseconds, as the server stores it, so its echo compares equal.
            finishedAt = finished ? Self.wholeMilliseconds(now) : nil
            dirty.insert(.finished)
            finishedEditedAt = now
        }
        if let ebook = edit.ebook {
            ebookLocation = ebook.location
            ebookProgress = ebook.progress
            dirty.insert(.ebook)
            ebookEditedAt = now
        }
        lastUpdate = max(lastUpdate, now)
    }

    /// The current values and edit times of the dirty groups; the other groups are `nil`.
    var dirtyValues: ProgressSend {
        var send = ProgressSend()
        if dirty.contains(.audio) {
            send.audio = .init(
                currentTime: currentTime, progress: progress, duration: duration,
                editedAt: audioEditedAt ?? lastUpdate)
        }
        if dirty.contains(.finished) {
            send.finished = .init(
                isFinished: isFinished, finishedAt: finishedAt, editedAt: finishedEditedAt ?? lastUpdate)
        }
        if dirty.contains(.ebook) {
            send.ebook = .init(
                ebookLocation: ebookLocation, ebookProgress: ebookProgress, editedAt: ebookEditedAt ?? lastUpdate)
        }
        return send
    }

    // MARK: - Sending

    /// The group the next PATCH carries: audio, then finished, then ebook. When the newest
    /// unacknowledged send (a failed or unanswered one) carried audio or finished and ebook is
    /// dirty, ebook goes next, so the two alternate while one keeps failing. Only once a server
    /// baseline exists: on a row the server has no progress for, an ebook PATCH creates it with
    /// zero audio and unfinished (#53), so audio and finished go first.
    var nextSendGroup: ProgressGroups? {
        let chain = [ProgressGroups.audio, .finished].first { dirty.contains($0) }
        guard dirty.contains(.ebook) else { return chain }
        guard let chain else { return .ebook }
        if serverBaseline != nil, let last = unacknowledgedSends.last, !last.groups.contains(.ebook) { return .ebook }
        return chain
    }

    /// Snapshots the next dirty group (``nextSendGroup``) for a PATCH and records it in
    /// `unacknowledgedSends` before it is sent; `nil` when nothing is dirty. An identical earlier
    /// entry (a retry of the same values and edit) is moved to the end rather than repeated. When
    /// the list is full, the oldest entry is dropped and the truncation flag of each group it
    /// carried, and of each dirty group its PATCH could have changed (#53), is set.
    mutating func beginSend() -> ProgressSend? {
        guard let group = nextSendGroup else { return nil }
        var send = dirtyValues.only(group)
        // The server stores a missing `ebookProgress` as 0 when the PATCH creates the progress
        // and as `nil` when it updates it; sending 0 makes both store 0, so the echo matches.
        if let ebook = send.ebook, ebook.ebookProgress == nil { send.ebook?.ebookProgress = 0 }
        unacknowledgedSends.removeAll { $0 == send }
        while unacknowledgedSends.count >= ProgressSend.historyLimit {
            let dropped = unacknowledgedSends.removeFirst().groups
            truncated.formUnion(dropped)
            shieldSideEffects(of: dropped)
        }
        unacknowledgedSends.append(send)
        return send
    }

    /// The PATCH carrying `send` succeeded: the server now holds the sent values, so they become
    /// the baseline, the sent groups' entries and truncation flags are cleared, and each sent
    /// group stops being dirty unless it was edited again while the request was in flight. Other
    /// groups keep their evidence. Acknowledging the same send twice changes nothing more.
    mutating func acknowledge(_ send: ProgressSend, serverLastUpdate: Date?) {
        // Without a baseline the groups that weren't sent take the row's values (the seeded or
        // merged server values, or defaults when the server had none).
        let unseeded = serverBaseline == nil
        var baseline = serverBaseline ?? currentValues(lastUpdate: .distantPast)
        if let audio = send.audio {
            baseline.currentTime = audio.currentTime
            baseline.progress = audio.progress
            baseline.duration = audio.duration
        }
        if let finished = send.finished {
            baseline.isFinished = finished.isFinished
            baseline.finishedAt = finished.finishedAt
        }
        if let ebook = send.ebook {
            baseline.ebookLocation = ebook.ebookLocation
            baseline.ebookProgress = ebook.ebookProgress
        }
        // Creating progress stores a missing `ebookProgress` as 0.
        if unseeded, baseline.ebookProgress == nil { baseline.ebookProgress = 0 }
        if let serverLastUpdate { baseline.lastUpdate = max(baseline.lastUpdate, serverLastUpdate) }
        serverBaseline = baseline
        let sent = send.groups
        dropEvidence(sent)
        // The server may have auto-finished our un-finish: while a newer finished edit is
        // pending, keep this send as evidence so the finished echo still matches it.
        if let finished = send.finished, !finished.isFinished, dirty.contains(.finished),
            editedAt(.finished) != finished.editedAt
        {
            unacknowledgedSends.append(send.only(.finished))
        }
        truncated.subtract(sent)
        for group in ProgressGroups.each where sent.contains(group) && editedAt(group) == send.editedAt(group) {
            dirty.remove(group)
        }
        shieldSideEffects(of: sent, unseeded: unseeded)
    }

    // MARK: - Merging server progress

    /// Merges server progress, group by group, except the `excluded` groups (those carried by a
    /// PATCH in flight). Returns `false` when the values are older than the baseline and were
    /// dropped. The caller has already dropped values captured before the row's last local edit or
    /// settlement.
    @discardableResult
    mutating func merge(_ server: ProgressBaseline, excluding excluded: ProgressGroups = []) -> Bool {
        if let baseline = serverBaseline, server.lastUpdate < baseline.lastUpdate { return false }
        // A PATCH in flight may already have changed the other group as a side effect (#53).
        shieldSideEffects(of: excluded)
        // An echo of our audio or finished PATCH may carry the server's side effect on the other
        // group, so shield that group before resolving it.
        for group in ProgressGroups.each where !excluded.contains(group) && dirty.contains(group) {
            if unacknowledgedSends.contains(where: { Self.matches(server, $0, group) }) {
                shieldSideEffects(of: group)
            }
        }
        for group in ProgressGroups.each where !excluded.contains(group) {
            resolve(group, server: server)
        }
        var baseline = server
        if let old = serverBaseline {
            // Groups not merged keep their old baseline values.
            for group in ProgressGroups.each where excluded.contains(group) {
                baseline.copy(group, from: old)
            }
        }
        serverBaseline = baseline
        lastUpdate = max(lastUpdate, server.lastUpdate)
        return true
    }

    private mutating func resolve(_ group: ProgressGroups, server: ProgressBaseline) {
        guard dirty.contains(group) else {
            take(group, from: server)
            return
        }
        // The server hasn't changed the group since we last saw it: keep the local edit.
        if let baseline = serverBaseline, Self.matches(server, baseline, group) { return }
        // The echo of one of our PATCHes whose response was lost. Only this group's evidence is
        // settled and pruned (from that entry and every older one); other groups keep theirs.
        if let index = unacknowledgedSends.lastIndex(where: { Self.matches(server, $0, group) }) {
            let sentEditedAt = unacknowledgedSends[index].editedAt(group)
            for older in 0...index {
                unacknowledgedSends[older].remove(group)
            }
            unacknowledgedSends.removeAll { $0.groups.isEmpty }
            if editedAt(group) == sentEditedAt {
                take(group, from: server)  // The server's normalized form of our value.
                markClean(group)
            }
            return
        }
        // The server value may be one of our dropped sends, or a side effect of our PATCH.
        if truncated.contains(group) { return }
        // A real conflict. `server.lastUpdate` is row-wide, an upper bound on when the group
        // changed, so ties and unknown edit times favour the server.
        if let edited = editedAt(group), edited > server.lastUpdate { return }
        take(group, from: server)
        markClean(group)
        // Our older sends of the group can no longer be the server's value; drop them so they
        // can't match another device's value later.
        dropEvidence(group)
    }

    /// #53: the server applies an audio PATCH by un-finishing or auto-finishing, a finished PATCH
    /// by setting `progress` to 1 or resetting `currentTime`, and checks every PATCH to existing
    /// progress, ebook-only too, for auto-finishing (fewer than 10 s left; `progress` becomes 1).
    /// A PATCH for media it has no progress for creates the progress with defaults for the other
    /// groups (zero audio, unfinished, no ebook location).
    /// When `sent` carried one of them, a pending
    /// local edit of an affected group wins over the server's value until its own send is
    /// acknowledged. `unseeded` is whether the row had no server baseline when it was sent
    /// (defaults to now).
    private mutating func shieldSideEffects(of sent: ProgressGroups, unseeded: Bool? = nil) {
        // Nothing sent, nothing the server could have changed (a plain fetch).
        guard !sent.isEmpty else { return }
        var affected: ProgressGroups = []
        if sent.contains(.audio) { affected.insert(.finished) }
        if sent.contains(.finished) { affected.insert(.audio) }
        if sent.contains(.ebook) { affected.formUnion([.audio, .finished]) }
        // Without server progress, the PATCH creates it with defaults for every unsent group.
        if unseeded ?? (serverBaseline == nil) { affected.formUnion(ProgressGroups.all.subtracting(sent)) }
        truncated.formUnion(affected.intersection(dirty))
    }

    private mutating func markClean(_ group: ProgressGroups) {
        dirty.remove(group)
        truncated.remove(group)
    }

    /// Removes `groups` from every unacknowledged entry, dropping entries left empty.
    private mutating func dropEvidence(_ groups: ProgressGroups) {
        for index in unacknowledgedSends.indices {
            unacknowledgedSends[index].remove(groups)
        }
        unacknowledgedSends.removeAll { $0.groups.isEmpty }
    }

    // MARK: - Helpers

    func editedAt(_ group: ProgressGroups) -> Date? {
        switch group {
        case .audio: audioEditedAt
        case .finished: finishedEditedAt
        default: ebookEditedAt
        }
    }

    private mutating func take(_ groups: ProgressGroups, from server: ProgressBaseline) {
        if groups.contains(.audio) {
            currentTime = server.currentTime
            progress = server.progress
            duration = server.duration
        }
        if groups.contains(.finished) {
            isFinished = server.isFinished
            finishedAt = server.finishedAt
        }
        if groups.contains(.ebook) {
            ebookLocation = server.ebookLocation
            ebookProgress = server.ebookProgress
        }
    }

    private func currentValues(lastUpdate: Date) -> ProgressBaseline {
        ProgressBaseline(
            currentTime: currentTime, progress: progress, duration: duration, isFinished: isFinished,
            finishedAt: finishedAt, ebookLocation: ebookLocation, ebookProgress: ebookProgress, lastUpdate: lastUpdate)
    }

    // Comparisons allow 1 s for `currentTime` and `duration` and 0.001 for `ebookProgress`. Audio
    // `progress` isn't compared: the server rewrites it (1 when finishing or auto-finishing, 0
    // when un-finishing) and ignores a sent value equal to its old `currentTime / duration`.
    // Dates compare exactly at the server's resolution, whole milliseconds.

    static func matches(_ server: ProgressBaseline, _ other: ProgressBaseline, _ group: ProgressGroups) -> Bool {
        switch group {
        case .audio:
            audioMatches(server, other.currentTime, other.duration)
        case .finished:
            server.isFinished == other.isFinished && datesMatch(server.finishedAt, other.finishedAt)
        default:
            ebookMatches(server, other.ebookLocation, other.ebookProgress)
        }
    }

    /// Whether `server` holds `send`'s value of `group` as the server stores it: an un-finish
    /// fewer than 10 s from the end is auto-finished (`finishedAt` no earlier than the edit). A
    /// missing `ebookProgress` is sent as 0 (``beginSend()``), so it needs no special case.
    static func matches(_ server: ProgressBaseline, _ send: ProgressSend, _ group: ProgressGroups) -> Bool {
        switch group {
        case .audio:
            guard let audio = send.audio else { return false }
            return audioMatches(server, audio.currentTime, audio.duration)
        case .finished:
            guard let finished = send.finished else { return false }
            // Auto-finished after the edit: by this PATCH, not an earlier one.
            if !finished.isFinished, server.isFinished, server.duration > 0,
                server.duration - server.currentTime < 10, let finishedAt = server.finishedAt,
                finishedAt >= wholeMilliseconds(finished.editedAt)
            {
                return true
            }
            return server.isFinished == finished.isFinished && datesMatch(server.finishedAt, finished.finishedAt)
        default:
            guard let ebook = send.ebook else { return false }
            return ebookMatches(server, ebook.ebookLocation, ebook.ebookProgress)
        }
    }

    private static func audioMatches(_ server: ProgressBaseline, _ currentTime: Double, _ duration: Double) -> Bool {
        abs(server.currentTime - currentTime) <= 1 && abs(server.duration - duration) <= 1
    }

    private static func ebookMatches(_ server: ProgressBaseline, _ location: String?, _ progress: Double?) -> Bool {
        guard server.ebookLocation == location else { return false }
        switch (server.ebookProgress, progress) {
        case (nil, nil): return true
        case (let lhs?, let rhs?): return abs(lhs - rhs) <= 0.001
        default: return false
        }
    }

    private static func datesMatch(_ lhs: Date?, _ rhs: Date?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil): true
        case (let lhs?, let rhs?): milliseconds(lhs) == milliseconds(rhs)
        default: false
        }
    }

    /// The nearest whole millisecond, absorbing floating-point error in already-whole values.
    private static func milliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1000).rounded())
    }

    /// `date` truncated to whole milliseconds, as the server stores it.
    static func wholeMilliseconds(_ date: Date) -> Date {
        Date(timeIntervalSince1970: (date.timeIntervalSince1970 * 1000).rounded(.down) / 1000)
    }
}

extension ProgressBaseline {
    mutating func copy(_ group: ProgressGroups, from other: ProgressBaseline) {
        switch group {
        case .audio:
            currentTime = other.currentTime
            progress = other.progress
            duration = other.duration
        case .finished:
            isFinished = other.isFinished
            finishedAt = other.finishedAt
        default:
            ebookLocation = other.ebookLocation
            ebookProgress = other.ebookProgress
        }
    }
}
