import ABSCore
import ABSData
import Foundation
import Observation

/// Donates recently played items to Spotlight (#87), so a search finds them and a tap opens them.
///
/// - When an item starts playing (``PlayerViewModel/spotlightRecord``), it indexes it in its
///   account's domain (``PlayableEntityRecord/spotlightDomain(_:)``), identified by its
///   ``MediaKey``: playing it again updates it instead of adding another. Only the running
///   session's account's items are donated, so an ending session can't index into the next.
/// - Each account keeps its ``limit`` most recently played items. The order is kept in
///   `defaults`, so the limit holds across launches; the oldest item past it is deleted.
/// - It deletes an account's domain when the user signs out, removes the account or the server
///   rejects the session (``SessionParticipant``), when the account is removed while another one
///   is active (``followRemovals(of:)``), when its credentials expire (``connectionExpired(_:)``)
///   and when a switch to it ends signed out (``followRejectedSwitches(of:)``). A switch keeps it:
///   a tap opens the item on its own account, asking to switch first (``DeepLink/init(spotlightIdentifier:)``).
///
/// Index writes run one at a time, in order, so a deletion can't overtake the donation before it.
@MainActor
public final class RecentItemsDonor: SessionParticipant {
    /// The most recently played items each account keeps in Spotlight.
    public static let limit = 20
    /// The `defaults` key of each account's indexed identifiers, most recent first.
    public static let defaultsKey = "spotlight.recentItems"

    public let index: any RecentItemsIndexing
    private let defaults: UserDefaults
    /// The running session's connection; `nil` when none runs.
    private var connectionID: UUID?
    /// The running session's credentials expired, so its end deletes its items even as a switch.
    private var runningSessionExpired = false
    /// The last record indexed, so the player's other changes don't donate it again.
    private var lastDonated: PlayableEntityRecord?
    /// The last index write; each new one waits for it.
    private var work: Task<Void, Never>?
    private var following: Task<Void, Never>?
    private var removals: Task<Void, Never>?
    private var rejectedSwitches: Task<Void, Never>?

    public init(index: any RecentItemsIndexing, defaults: UserDefaults) {
        self.index = index
        self.defaults = defaults
    }

    isolated deinit {
        following?.cancel()
        removals?.cancel()
        rejectedSwitches?.cancel()
    }

    /// Indexes `record` (an item that started playing) as its account's most recent, subject to
    /// the rules above. `nil` (nothing playing) changes nothing.
    public func donate(_ record: PlayableEntityRecord?) {
        guard let record, let connectionID, record.key.serverConnectionID == connectionID,
            record != lastDonated
        else { return }
        lastDonated = record
        var identifiers = indexedIdentifiers(of: connectionID).filter { $0 != record.id }
        identifiers.insert(record.id, at: 0)
        let dropped = Array(identifiers.dropFirst(Self.limit))
        setIndexedIdentifiers(Array(identifiers.prefix(Self.limit)), of: connectionID)
        enqueue { index in
            try await index.index(record)
            if !dropped.isEmpty { try await index.delete(identifiers: dropped) }
        }
    }

    /// Deletes `connectionID`'s items from Spotlight, and forgets them.
    public func removeItems(of connectionID: UUID) {
        setIndexedIdentifiers([], of: connectionID)
        if lastDonated?.key.serverConnectionID == connectionID { lastDonated = nil }
        enqueue { try await $0.deleteDomain(of: connectionID) }
    }

    /// The identifiers indexed for `connectionID`, most recently played first.
    public func indexedIdentifiers(of connectionID: UUID) -> [String] {
        let all = defaults.dictionary(forKey: Self.defaultsKey) as? [String: [String]]
        return all?[connectionID.uuidString] ?? []
    }

    /// Waits for the index writes asked for so far.
    public func settle() async {
        await work?.value
    }

    /// Calls ``donate(_:)`` with `player`'s ``PlayerViewModel/spotlightRecord`` whenever it
    /// changes, until the donor is released or this is called again.
    public func follow(_ player: PlayerViewModel) {
        following?.cancel()
        following = Task { [weak self] in
            for await record in Observations({ @MainActor in player.spotlightRecord }) {
                guard !Task.isCancelled, let self else { return }
                self.donate(record)
            }
        }
    }

    /// Deletes a connection's items once it leaves `savedConnections`, read with Observation
    /// (`AccountManager.connections`). Only a connection seen listed and then gone counts as
    /// removed, so a list that hasn't loaded yet (empty at launch) deletes nothing. Follows until
    /// the donor is released or this is called again.
    public func followRemovals(of savedConnections: @escaping @MainActor @Sendable () -> Set<UUID>) {
        removals?.cancel()
        let initial = savedConnections()
        removals = Task { [weak self] in
            var known = initial
            for await saved in Observations({ @MainActor in savedConnections() }) {
                guard !Task.isCancelled, let self else { return }
                let removed = known.subtracting(saved)
                known = saved
                for connectionID in removed { self.removeItems(of: connectionID) }
            }
        }
    }

    /// Deletes a connection's items when a switch to it ends signed out (its saved session was
    /// rejected or unreadable): that switch ended the running session with
    /// ``SessionEndReason/switch``, and no session of that connection starts to expire. `rejected`
    /// reads ``SessionLifecycle/signedOutSwitches`` and ``SessionLifecycle/signedOutSwitchConnectionID``.
    /// Follows until the donor is released or this is called again.
    public func followRejectedSwitches(
        of rejected: @escaping @MainActor @Sendable () -> (count: Int, connectionID: UUID?)
    ) {
        rejectedSwitches?.cancel()
        let initial = rejected().count
        rejectedSwitches = Task { [weak self] in
            var seen = initial
            for await (count, connectionID) in Observations({ @MainActor in rejected() }) {
                guard !Task.isCancelled, let self else { return }
                guard count != seen else { continue }
                seen = count
                if let connectionID { self.removeItems(of: connectionID) }
            }
        }
    }

    /// Deletes `connectionID`'s items when its credentials expire (`AccountManager`'s
    /// `credentialsExpired`): Spotlight mustn't offer a signed-out account's items. The running
    /// session's are deleted when it ends (``sessionWillEnd(_:)``), even as a switch.
    public func connectionExpired(_ connectionID: UUID) {
        if connectionID == self.connectionID {
            runningSessionExpired = true
            return
        }
        removeItems(of: connectionID)
    }

    // MARK: - SessionParticipant

    public func sessionDidStart(_ context: SessionContext) async {
        connectionID = context.identity.connectionID
        runningSessionExpired = false
        lastDonated = nil
    }

    public func sessionWillEnd(_ reason: SessionEndReason) async {
        let (ended, expired) = (connectionID, runningSessionExpired)
        connectionID = nil
        runningSessionExpired = false
        lastDonated = nil
        guard let ended else { return }
        switch reason {
        case .signOut, .removed, .expired: removeItems(of: ended)
        // Its credentials expired while the switch began: it's signed out now.
        case .switch: if expired { removeItems(of: ended) }
        }
    }

    // MARK: - Index writes

    private func setIndexedIdentifiers(_ identifiers: [String], of connectionID: UUID) {
        var all = defaults.dictionary(forKey: Self.defaultsKey) as? [String: [String]] ?? [:]
        all[connectionID.uuidString] = identifiers.isEmpty ? nil : identifiers
        defaults.set(all, forKey: Self.defaultsKey)
    }

    /// Runs `write` after the writes before it. Spotlight is best effort, so a failure is only
    /// logged.
    private func enqueue(_ write: @escaping @MainActor (any RecentItemsIndexing) async throws -> Void) {
        let previous = work
        let index = self.index
        work = Task { @MainActor in
            await previous?.value
            do {
                try await write(index)
            } catch {
                let reason = Log.redact(String(describing: error))
                Log.data.error("Spotlight's recent items couldn't be updated: \(reason, privacy: .public)")
            }
        }
    }
}

extension PlayerViewModel {
    /// The item to donate to Spotlight: the current one, once it's asked to play and its duration
    /// is known; `nil` otherwise, so a restored item that isn't played isn't donated.
    public var spotlightRecord: PlayableEntityRecord? {
        guard let key = playback.mediaKey, hasSession, playback.isPlaybackRequested, playback.duration > 0,
            !title.isEmpty
        else { return nil }
        return PlayableEntityRecord(
            key: key, title: title, subtitle: author.isEmpty ? nil : author, duration: playback.duration)
    }
}
