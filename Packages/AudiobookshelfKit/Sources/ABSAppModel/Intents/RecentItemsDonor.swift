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
///   and when a switch to it, or the launch's restore of it, ends signed out
///   (``followRejectedSwitches(of:)``, ``follow(accounts:)``). A switch keeps it: a tap opens the
///   item on its own account, asking to switch first (``DeepLink/init(spotlightIdentifier:)``).
/// - A deletion that fails stays pending in `defaults`, with the identifiers it was for, until it
///   succeeds: the donor retries it when it's made (at launch) and when a session starts, so a
///   signed-out account's items, or those past the limit, don't stay searchable.
///
/// Index writes run one at a time, in order, so a deletion can't overtake the donation before it.
@MainActor
public final class RecentItemsDonor: SessionParticipant {
    /// The most recently played items each account keeps in Spotlight.
    public static let limit = 20
    /// The `defaults` key of each account's indexed identifiers, most recent first.
    public static let defaultsKey = "spotlight.recentItems"
    /// The `defaults` key of each account's pending domain deletion, with the identifiers it was
    /// asked for: ``removeItems(of:)`` moves them here until the deletion succeeds.
    public static let pendingDomainsKey = "spotlight.pendingDomainDeletions"
    /// The `defaults` key of each account's identifiers past the limit that aren't deleted yet.
    public static let pendingEvictionsKey = "spotlight.pendingEvictions"

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
        retryPendingDeletions()
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
        // Played again: it stays, though an earlier eviction (queued before this) deletes it first.
        update(Self.pendingEvictionsKey, of: connectionID) { $0.removeAll { $0 == record.id } }
        // Tracked as pending until deleted, so a failure can't leave them past the limit, untracked.
        update(Self.pendingEvictionsKey, of: connectionID) { $0.append(contentsOf: dropped) }
        setIndexedIdentifiers(Array(identifiers.prefix(Self.limit)), of: connectionID)
        enqueue { index in
            // Evicts whether or not indexing succeeds.
            await Self.attempt { try await index.index(record) }
        }
        if !dropped.isEmpty { evict(dropped, of: connectionID) }
    }

    /// Deletes `connectionID`'s items from Spotlight, and forgets them once that succeeds. Until
    /// then the deletion stays pending, with the identifiers it was asked for.
    public func removeItems(of connectionID: UUID) {
        let identifiers = indexedIdentifiers(of: connectionID) + pending(Self.pendingEvictionsKey, of: connectionID)
        update(Self.pendingDomainsKey, of: connectionID) { $0.append(contentsOf: identifiers) }
        update(Self.pendingEvictionsKey, of: connectionID) { $0 = [] }
        setIndexedIdentifiers([], of: connectionID)
        if lastDonated?.key.serverConnectionID == connectionID { lastDonated = nil }
        deleteDomain(of: connectionID, identifiers: identifiers)
    }

    /// The connections whose domain deletion hasn't succeeded yet.
    public var pendingDomainDeletions: Set<UUID> {
        Set(pendingEntries(Self.pendingDomainsKey).keys.compactMap(UUID.init(uuidString:)))
    }

    /// The identifiers past `connectionID`'s limit that aren't deleted yet.
    public func pendingEvictions(of connectionID: UUID) -> [String] {
        pending(Self.pendingEvictionsKey, of: connectionID)
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

    /// Follows `accounts`, after whatever its callbacks already run: deletes a connection's items
    /// once it leaves ``AccountManager/connections`` (``followRemovals(of:)``), once its
    /// credentials are removed (``AccountManager/credentialsRemoved``, even if the store then keeps
    /// it listed) or expire (``connectionExpired(_:)``), and once the launch's restore of it ends
    /// signed out (``AccountManager/restoreSignedOut``).
    public func follow(accounts: AccountManager) {
        followRemovals { Set(accounts.connections.map(\.id)) }
        // Weakly: `accounts` outlives the donor's owner.
        let expired = accounts.credentialsExpired
        accounts.credentialsExpired = { [weak self] in
            expired?($0)
            self?.connectionExpired($0)
        }
        let removed = accounts.credentialsRemoved
        accounts.credentialsRemoved = { [weak self] in
            await removed?($0)
            self?.removeItems(of: $0)
        }
        let restored = accounts.restoreSignedOut
        accounts.restoreSignedOut = { [weak self] in
            restored?($0)
            self?.removeItems(of: $0)
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
        retryPendingDeletions()
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

    private func pendingEntries(_ key: String) -> [String: [String]] {
        defaults.dictionary(forKey: key) as? [String: [String]] ?? [:]
    }

    private func pending(_ key: String, of connectionID: UUID) -> [String] {
        pendingEntries(key)[connectionID.uuidString] ?? []
    }

    /// Changes `connectionID`'s pending identifiers under `key`, deduplicated. A pending domain
    /// deletion is kept even with no identifiers; an eviction is dropped once it has none.
    private func update(_ key: String, of connectionID: UUID, _ change: (inout [String]) -> Void) {
        var all = pendingEntries(key)
        var identifiers = all[connectionID.uuidString] ?? []
        change(&identifiers)
        var seen = Set<String>()
        identifiers = identifiers.filter { seen.insert($0).inserted }
        all[connectionID.uuidString] = identifiers.isEmpty && key == Self.pendingEvictionsKey ? nil : identifiers
        defaults.set(all, forKey: key)
    }

    /// Queues every pending deletion again, as at launch.
    private func retryPendingDeletions() {
        for (connection, identifiers) in pendingEntries(Self.pendingDomainsKey) {
            guard let connectionID = UUID(uuidString: connection) else { continue }
            deleteDomain(of: connectionID, identifiers: identifiers)
        }
        for (connection, identifiers) in pendingEntries(Self.pendingEvictionsKey) {
            guard let connectionID = UUID(uuidString: connection), !identifiers.isEmpty else { continue }
            evict(identifiers, of: connectionID)
        }
    }

    /// Deletes `connectionID`'s domain, then forgets the pending deletion of `identifiers`; if it
    /// fails, they stay pending.
    private func deleteDomain(of connectionID: UUID, identifiers: [String]) {
        enqueue { [weak self] index in
            let deleted = await Self.attempt { try await index.deleteDomain(of: connectionID) }
            guard let self else { return }
            if deleted {
                var all = self.pendingEntries(Self.pendingDomainsKey)
                let left = (all[connectionID.uuidString] ?? []).filter { !identifiers.contains($0) }
                // Another removal queued meanwhile, with other identifiers, keeps its own entry.
                all[connectionID.uuidString] = left.isEmpty ? nil : left
                self.defaults.set(all, forKey: Self.pendingDomainsKey)
            } else {
                // Kept pending, even if a removal queued before this one succeeded and cleared it.
                self.update(Self.pendingDomainsKey, of: connectionID) { $0.append(contentsOf: identifiers) }
            }
        }
    }

    /// Deletes `identifiers`, past `connectionID`'s limit, then forgets their pending eviction.
    private func evict(_ identifiers: [String], of connectionID: UUID) {
        enqueue { [weak self] index in
            guard await Self.attempt({ try await index.delete(identifiers: identifiers) }), let self else { return }
            self.update(Self.pendingEvictionsKey, of: connectionID) { $0.removeAll { identifiers.contains($0) } }
        }
    }

    /// Runs `write` after the writes before it.
    private func enqueue(_ write: @escaping @MainActor (any RecentItemsIndexing) async -> Void) {
        let previous = work
        let index = self.index
        work = Task { @MainActor in
            await previous?.value
            await write(index)
        }
    }

    /// Runs an index write, and returns whether it succeeded. Spotlight is best effort, so a
    /// failure is only logged; a deletion's stays pending.
    @discardableResult
    private static func attempt(_ write: @MainActor () async throws -> Void) async -> Bool {
        do {
            try await write()
            return true
        } catch {
            let reason = Log.redact(String(describing: error))
            Log.data.error("Spotlight's recent items couldn't be updated: \(reason, privacy: .public)")
            return false
        }
    }
}

extension PlayerViewModel {
    /// The item to donate to Spotlight: the current one, once it plays and its duration is known;
    /// `nil` otherwise, so a restored item that isn't played isn't donated. Not just once play is
    /// requested: a request for another item, waiting on its streaming-policy check, counts as
    /// one while the restored item is still current.
    public var spotlightRecord: PlayableEntityRecord? {
        guard let key = playback.mediaKey, hasSession, playback.isPlaying, playback.duration > 0,
            !title.isEmpty
        else { return nil }
        return PlayableEntityRecord(
            key: key, title: title, subtitle: author.isEmpty ? nil : author, duration: playback.duration)
    }
}
