import ABSAPI
import ABSCore
import Foundation
import Observation

/// Why ``BookmarkStore`` couldn't do something.
public enum BookmarkStoreError: Error, Sendable, Hashable {
    /// There is no session, it has no client, or it's offline.
    case unavailable
    /// The bookmark to rename isn't in the list any more.
    case notFound
}

/// The signed-in user's bookmarks, keyed by item, with optimistic writes.
///
/// A bookmark is identified by its item and its exact `time`, as on the server. Callers pass
/// whole seconds (D10), so two bookmarks within the same second at different fractions are
/// different bookmarks.
///
/// Loading: ``refresh()`` fetches the list (`GET /api/me`) and ``replaceAll(from:)`` takes the
/// user from the login response or the socket's `user_updated`. Each load takes a seed token
/// first. A response is dropped when a response to a later load was already applied or
/// ``clear()`` ran since, and it doesn't undo a write that finished after the load started.
///
/// Writes (``create(itemID:time:title:)``, ``rename(_:to:)``, ``delete(_:)``):
/// - Change the list right away, send the request, then keep the server's copy or, if it fails,
///   put the previous entry back and rethrow.
/// - Writes on the same item run one after the other, in call order; other items don't wait.
/// - A write runs to completion even if its caller is cancelled.
/// - A load during a write keeps the optimistic entry while the server's entry is still the one
///   the write started from (the server hasn't seen the write). Otherwise the server's entry wins
///   and the write no longer changes it, neither to keep the reply nor to roll back.
///
/// Errors: ``BookmarkStoreError/unavailable`` when ``isAvailable`` is false, and
/// `CancellationError` when ``clear()`` or the end of the session drops a load or write in flight.
@MainActor
@Observable
public final class BookmarkStore: SessionParticipant {
    public typealias Service = any BookmarkWriting & BookmarkReading

    private struct Key: Hashable {
        let itemID: String
        let time: Double

        init(itemID: String, time: Double) {
            self.itemID = itemID
            self.time = time
        }

        init(_ bookmark: AudioBookmark) {
            self.init(itemID: bookmark.libraryItemId, time: bookmark.time)
        }
    }

    private struct Pending {
        let key: Key
        let before: AudioBookmark?
        let optimistic: AudioBookmark?
        /// A load brought a server entry other than `before`.
        var isSuperseded = false
    }

    private struct SeedToken {
        let generation: Int
        let request: Int
        /// ``commitSerial`` when the request started.
        let commitBoundary: Int
    }

    private struct Tail {
        let ticket: Int
        let task: Task<Result<AudioBookmark?, any Error>, Never>
    }

    private enum Write {
        case create(String)
        case rename(String)
        case delete
    }

    public private(set) var isLoading = false
    /// Whether a load was applied since the session started or the last ``clear()``.
    public private(set) var hasLoaded = false

    private var entries: [String: [Double: AudioBookmark]] = [:]
    private var service: Service?

    @ObservationIgnored private let makeService: @MainActor (APIClient) -> Service
    /// Bumped by ``clear()`` and at the end of a session, so older writes and loads are dropped.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var seedRequests = 0
    @ObservationIgnored private var appliedSeedRequest = 0
    @ObservationIgnored private var loads = 0
    @ObservationIgnored private var pending: [Int: Pending] = [:]
    @ObservationIgnored private var tails: [String: Tail] = [:]
    @ObservationIgnored private var tickets = 0
    /// Increases with every finished write.
    @ObservationIgnored private var commitSerial = 0
    /// The ``commitSerial`` of the last finished write per key, until a load started after it.
    @ObservationIgnored private var committed: [Key: Int] = [:]

    public init(makeService: @escaping @MainActor (APIClient) -> any BookmarkWriting & BookmarkReading = { $0 }) {
        self.makeService = makeService
    }

    /// The item's bookmarks, by time.
    public func bookmarks(itemID: String) -> [AudioBookmark] {
        (entries[itemID] ?? [:]).values.sorted { $0.time < $1.time }
    }

    /// Whether the session has a client and isn't offline.
    public var isAvailable: Bool { service != nil }

    // MARK: Loading

    /// Fetches every bookmark and replaces the list, unless a later load already landed.
    ///
    /// Throws ``BookmarkStoreError/unavailable`` without a usable connection, `CancellationError`
    /// when ``clear()`` or the end of the session dropped the response, or the request's error.
    public func refresh() async throws {
        guard let service else { throw BookmarkStoreError.unavailable }
        let token = beginSeed()
        loads += 1
        isLoading = true
        defer {
            loads -= 1
            isLoading = loads > 0
        }
        let bookmarks = try await service.allBookmarks()
        guard seed(bookmarks, token: token) || token.generation == generation else { throw CancellationError() }
    }

    /// Replaces the list with the user's, from the login response or `user_updated`.
    public func replaceAll(from user: User) {
        seed(user.bookmarks, token: beginSeed())
    }

    /// Empties the list; loads and writes already started are dropped.
    public func clear() {
        generation += 1
        appliedSeedRequest = 0
        pending = [:]
        tails = [:]
        committed = [:]
        hasLoaded = false
        if !entries.isEmpty { entries = [:] }
    }

    private func beginSeed() -> SeedToken {
        seedRequests += 1
        return SeedToken(generation: generation, request: seedRequests, commitBoundary: commitSerial)
    }

    @discardableResult
    private func seed(_ bookmarks: [AudioBookmark], token: SeedToken) -> Bool {
        guard token.generation == generation, token.request > appliedSeedRequest else { return false }
        appliedSeedRequest = token.request
        var next: [String: [Double: AudioBookmark]] = [:]
        for bookmark in bookmarks {
            next[bookmark.libraryItemId, default: [:]][bookmark.time] = bookmark
        }
        var pendingKeys: [Key: Pending] = [:]
        for write in pending.values { pendingKeys[write.key] = write }
        for (key, serial) in committed {
            guard serial > token.commitBoundary else {
                // Later loads start later still, so they all include this write.
                committed[key] = nil
                continue
            }
            // The response may predate this write: keep the list as the write left it.
            if let write = pendingKeys[key] {
                Self.set(write.before, at: key, in: &next)
            } else {
                Self.set(value(at: key), at: key, in: &next)
            }
        }
        for ticket in pending.keys.sorted() {
            guard var write = pending[ticket] else { continue }
            if Self.value(at: write.key, in: next) == write.before {
                Self.set(write.optimistic, at: write.key, in: &next)
            } else {
                // Known limitation: this also drops a reply newer than this load; the socket's
                // `user_updated` (#183) corrects the list.
                write.isSuperseded = true
                pending[ticket] = write
            }
        }
        hasLoaded = true
        if next != entries { entries = next }
        return true
    }

    // MARK: Writes

    /// Adds a bookmark at `time`, or renames the one already at exactly that `time` (as the server
    /// does), and returns the server's copy.
    ///
    /// Throws ``BookmarkStoreError/unavailable`` without a usable connection, `CancellationError`
    /// when ``clear()`` or the end of the session dropped the write, or the request's error.
    @discardableResult
    public func create(itemID: String, time: Double, title: String) async throws -> AudioBookmark {
        let saved = try await run(Key(itemID: itemID, time: time), .create(title))
        return saved ?? AudioBookmark(libraryItemId: itemID, title: title, time: time)
    }

    /// Renames the bookmark. Throws like ``create(itemID:time:title:)``, and
    /// ``BookmarkStoreError/notFound`` when the bookmark isn't in the list any more.
    public func rename(_ bookmark: AudioBookmark, to title: String) async throws {
        _ = try await run(Key(bookmark), .rename(title))
    }

    /// Deletes the bookmark. Throws like ``create(itemID:time:title:)``.
    public func delete(_ bookmark: AudioBookmark) async throws {
        _ = try await run(Key(bookmark), .delete)
    }

    private func run(_ key: Key, _ write: Write) async throws -> AudioBookmark? {
        let session = generation
        guard service != nil else { throw BookmarkStoreError.unavailable }
        let previous = tails[key.itemID]?.task
        tickets += 1
        let ticket = tickets
        let task = Task<Result<AudioBookmark?, any Error>, Never> { @MainActor in
            _ = await previous?.value
            do {
                return .success(try await self.perform(key, write, ticket: ticket, session: session))
            } catch {
                return .failure(error)
            }
        }
        tails[key.itemID] = Tail(ticket: ticket, task: task)
        let result = await task.value
        // Tickets are never reused, so an older session's write can't remove a newer tail.
        if tails[key.itemID]?.ticket == ticket { tails[key.itemID] = nil }
        return try result.get()
    }

    private func perform(_ key: Key, _ write: Write, ticket: Int, session: Int) async throws -> AudioBookmark? {
        guard session == generation else { throw CancellationError() }
        guard let service else { throw BookmarkStoreError.unavailable }
        let before = value(at: key)
        let optimistic: AudioBookmark?
        switch write {
        case .create(let title):
            var bookmark = before ?? AudioBookmark(libraryItemId: key.itemID, time: key.time)
            bookmark.title = title
            optimistic = bookmark
        case .rename(let title):
            guard var bookmark = before else { throw BookmarkStoreError.notFound }
            bookmark.title = title
            optimistic = bookmark
        case .delete:
            optimistic = nil
        }
        pending[ticket] = Pending(key: key, before: before, optimistic: optimistic)
        setValue(optimistic, at: key)
        defer { pending[ticket] = nil }

        let saved: AudioBookmark?
        do {
            switch write {
            case .create(let title):
                saved = try await service.createBookmark(itemID: key.itemID, time: key.time, title: title)
            case .rename(let title):
                saved = try await service.renameBookmark(itemID: key.itemID, time: key.time, title: title)
            case .delete:
                do {
                    try await service.deleteBookmark(itemID: key.itemID, time: key.time)
                } catch APIError.notFound {
                    // Already gone on the server: deleting is idempotent.
                }
                saved = nil
            }
        } catch {
            guard session == generation else { throw CancellationError() }
            if holdsOptimistic(ticket) { setValue(before, at: key) }
            recordCommit(key)
            throw error
        }
        guard session == generation else { throw CancellationError() }
        if let saved, holdsOptimistic(ticket) {
            let savedKey = Key(saved)
            if savedKey != key {
                setValue(nil, at: key)
                recordCommit(savedKey)
            }
            setValue(saved, at: savedKey)
        }
        recordCommit(key)
        return saved
    }

    /// Whether the write's entry still holds its optimistic value, unchanged by any load.
    private func holdsOptimistic(_ ticket: Int) -> Bool {
        guard let write = pending[ticket], !write.isSuperseded else { return false }
        // A backstop: only a load changes the entry meanwhile, and it marks the write superseded.
        return value(at: write.key) == write.optimistic
    }

    private func recordCommit(_ key: Key) {
        commitSerial += 1
        committed[key] = commitSerial
    }

    private func value(at key: Key) -> AudioBookmark? {
        Self.value(at: key, in: entries)
    }

    private func setValue(_ bookmark: AudioBookmark?, at key: Key) {
        guard value(at: key) != bookmark else { return }
        Self.set(bookmark, at: key, in: &entries)
    }

    private static func value(at key: Key, in entries: [String: [Double: AudioBookmark]]) -> AudioBookmark? {
        entries[key.itemID]?[key.time]
    }

    private static func set(
        _ bookmark: AudioBookmark?, at key: Key, in entries: inout [String: [Double: AudioBookmark]]
    ) {
        entries[key.itemID, default: [:]][key.time] = bookmark
        if entries[key.itemID]?.isEmpty == true { entries[key.itemID] = nil }
    }

    // MARK: SessionParticipant

    public func sessionDidStart(_ context: SessionContext) async {
        clear()
        connect(context)
    }

    public func sessionDidReconnect(_ context: SessionContext) async {
        connect(context)
    }

    public func sessionWillEnd(_ reason: SessionEndReason) async {
        clear()
        service = nil
    }

    private func connect(_ context: SessionContext) {
        if let client = context.client, !context.isOffline {
            service = makeService(client)
        } else {
            service = nil
        }
    }
}
