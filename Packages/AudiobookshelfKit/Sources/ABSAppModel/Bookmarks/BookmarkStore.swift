import ABSAPI
import ABSCore
import Foundation
import Observation

/// The signed-in user's bookmarks, keyed by item, with optimistic writes.
///
/// Loading: ``refresh()`` fetches the list (`GET /api/me`) and ``replaceAll(from:)`` takes the
/// user from the login response or the socket's `user_updated`. Each load takes a seed token
/// first, so a response to an older request, or one from before ``clear()``, is dropped.
///
/// Writes (``create(itemID:time:title:)``, ``rename(_:to:)``, ``delete(_:)``):
/// - Change the list right away, send the request, then keep the server's copy or, if it fails,
///   put the previous entry back and rethrow. The rollback happens only while the entry still
///   holds the optimistic value: a value a load put there meanwhile is newer and stays.
/// - Writes on the same item run one after the other, in call order; other items don't wait.
/// - A write runs to completion even if its caller is cancelled. After ``clear()`` or the end of
///   the session it no longer touches the list and throws `CancellationError`.
/// - A load during a write keeps the optimistic entry while the server's entry is still the one
///   the write started from (the server hasn't seen the write); otherwise the server's wins.
///
/// Without a usable connection (no session, no client, or offline) ``isAvailable`` is false and
/// loads and writes throw `CancellationError`.
@MainActor
@Observable
public final class BookmarkStore: SessionParticipant {
    public typealias Service = any BookmarkWriting & BookmarkReading

    private struct Key: Hashable {
        let itemID: String
        let time: Double
    }

    private struct Pending {
        let key: Key
        let before: AudioBookmark?
        let optimistic: AudioBookmark?
    }

    private struct SeedToken {
        let generation: Int
        let request: Int
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

    /// Fetches every bookmark and replaces the list, unless a newer load already landed.
    public func refresh() async throws {
        guard let service else { throw CancellationError() }
        let token = beginSeed()
        loads += 1
        isLoading = true
        defer {
            loads -= 1
            isLoading = loads > 0
        }
        let bookmarks = try await service.allBookmarks()
        seed(bookmarks, token: token)
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
        if !entries.isEmpty { entries = [:] }
    }

    private func beginSeed() -> SeedToken {
        seedRequests += 1
        return SeedToken(generation: generation, request: seedRequests)
    }

    private func seed(_ bookmarks: [AudioBookmark], token: SeedToken) {
        guard token.generation == generation, token.request > appliedSeedRequest else { return }
        appliedSeedRequest = token.request
        var next: [String: [Double: AudioBookmark]] = [:]
        for bookmark in bookmarks {
            next[bookmark.libraryItemId, default: [:]][bookmark.time] = bookmark
        }
        for (_, write) in pending.sorted(by: { $0.key < $1.key })
        where next[write.key.itemID]?[write.key.time] == write.before {
            next[write.key.itemID, default: [:]][write.key.time] = write.optimistic
            if next[write.key.itemID]?.isEmpty == true { next[write.key.itemID] = nil }
        }
        if next != entries { entries = next }
    }

    // MARK: Writes

    /// Adds a bookmark at `time`, or renames the one already there (as the server does), and
    /// returns the server's copy.
    @discardableResult
    public func create(itemID: String, time: Double, title: String) async throws -> AudioBookmark {
        let saved = try await run(Key(itemID: itemID, time: time), .create(title))
        return saved ?? AudioBookmark(libraryItemId: itemID, title: title, time: time)
    }

    public func rename(_ bookmark: AudioBookmark, to title: String) async throws {
        _ = try await run(Key(itemID: bookmark.libraryItemId, time: bookmark.time), .rename(title))
    }

    public func delete(_ bookmark: AudioBookmark) async throws {
        _ = try await run(Key(itemID: bookmark.libraryItemId, time: bookmark.time), .delete)
    }

    private func run(_ key: Key, _ write: Write) async throws -> AudioBookmark? {
        let session = generation
        guard service != nil else { throw CancellationError() }
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
        if tails[key.itemID]?.ticket == ticket { tails[key.itemID] = nil }
        return try result.get()
    }

    private func perform(_ key: Key, _ write: Write, ticket: Int, session: Int) async throws -> AudioBookmark? {
        guard session == generation, let service else { throw CancellationError() }
        let before = value(at: key)
        let optimistic: AudioBookmark?
        switch write {
        case .create(let title), .rename(let title):
            var bookmark = before ?? AudioBookmark(libraryItemId: key.itemID, time: key.time)
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
                try await service.deleteBookmark(itemID: key.itemID, time: key.time)
                saved = nil
            }
        } catch {
            guard session == generation else { throw CancellationError() }
            if value(at: key) == optimistic { setValue(before, at: key) }
            throw error
        }
        guard session == generation else { throw CancellationError() }
        if let saved, saved.libraryItemId == key.itemID, saved.time == key.time, value(at: key) == optimistic {
            setValue(saved, at: key)
        }
        return saved
    }

    private func value(at key: Key) -> AudioBookmark? {
        entries[key.itemID]?[key.time]
    }

    private func setValue(_ bookmark: AudioBookmark?, at key: Key) {
        guard value(at: key) != bookmark else { return }
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
