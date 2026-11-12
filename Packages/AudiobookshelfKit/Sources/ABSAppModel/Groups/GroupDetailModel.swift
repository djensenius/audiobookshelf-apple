import ABSAPI
import ABSCore
import ABSRealtime
import Foundation
import Observation

/// A loaded collection or playlist: its name, description and rows in server order.
public struct GroupDetail: Sendable, Hashable, Identifiable {
    public let id: String
    public let libraryID: String
    public let name: String
    /// `nil` when blank.
    public let description: String?
    /// Books, or a playlist's books and episodes, in order. A member listed twice keeps its
    /// first row, so IDs are unique.
    public let members: [GroupMember]
    /// The group cover's images, like ``GroupSummary/covers``.
    public let covers: [CoverRef]

    public init(
        id: String, libraryID: String, name: String, description: String?, members: [GroupMember], covers: [CoverRef]
    ) {
        self.id = id
        self.libraryID = libraryID
        self.name = name
        self.description = description.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        var seen: Set<String> = []
        self.members = members.filter { seen.insert($0.id).inserted }
        self.covers = Array(covers.prefix(GroupSummary.maxCovers))
    }

    public init(collection: LibraryCollection) {
        let books = collection.books ?? []
        self.init(
            id: collection.id, libraryID: collection.libraryId, name: collection.name,
            description: collection.description, members: books.map(GroupMember.init(book:)),
            covers: GroupSummary.covers(of: books))
    }

    public init(playlist: Playlist) {
        self.init(
            id: playlist.id, libraryID: playlist.libraryId, name: playlist.name, description: playlist.description,
            members: playlist.items.map(GroupMember.init(playlistItem:)),
            covers: GroupSummary.covers(of: playlist.items.compactMap(\.libraryItem)))
    }
}

/// How a ``GroupDetailModel`` loads its group.
public protocol GroupDetailKind: Sendable {
    static func detail(id: String, service: any GroupsService) async throws -> GroupDetail
    /// `change` as a change to a group of this kind seen by the user `userID`, or `nil` if it's
    /// another kind or another user's playlist.
    static func groupChange(_ change: LibraryChange, userID: String?) -> LibraryEntityChange<GroupDetail>?
}

/// Loads `GET /api/collections/:id`.
public enum CollectionGroupKind: GroupDetailKind {
    public static func detail(id: String, service: any GroupsService) async throws -> GroupDetail {
        GroupDetail(collection: try await service.collectionDetail(id: id))
    }

    public static func groupChange(_ change: LibraryChange, userID: String?) -> LibraryEntityChange<GroupDetail>? {
        guard case .collection(let change) = change else { return nil }
        return change.map(GroupDetail.init(collection:))
    }
}

/// Loads `GET /api/playlists/:id`.
public enum PlaylistGroupKind: GroupDetailKind {
    public static func detail(id: String, service: any GroupsService) async throws -> GroupDetail {
        GroupDetail(playlist: try await service.playlistDetail(id: id))
    }

    public static func groupChange(_ change: LibraryChange, userID: String?) -> LibraryEntityChange<GroupDetail>? {
        guard case .playlist(let change, let owner) = change, owner == userID else { return nil }
        return change.map(GroupDetail.init(playlist:))
    }
}

/// The collection detail screen; a port of the legacy `pages/collection/_id.vue`.
public typealias CollectionDetailModel = GroupDetailModel<CollectionGroupKind>
/// The playlist detail screen; a port of the legacy `pages/playlist/_id.vue`. Its rows mix books
/// and podcast episodes.
public typealias PlaylistDetailModel = GroupDetailModel<PlaylistGroupKind>

/// A collection or playlist screen: the group by ID, the user's progress on its members from
/// ``ProgressCache``, and what play-all would start. Use ``CollectionDetailModel`` or
/// ``PlaylistDetailModel``.
///
/// - Loading keeps the last group while reloading and after a failed reload, like ``StatsModel``.
///   When loads overlap, only the last one started is applied. A 404 (``APIError/notFound``) is
///   different: the group was deleted or never existed, so the group is dropped and
///   ``phase`` becomes ``Phase/notFound`` for the view to pop.
/// - Progress and ``nextToPlay`` are read from the cache on every access, so a view reading
///   them invalidates when one of its members' cache entries changes.
/// - Play-all is data only: the model never starts playback.
///
/// ``apply(_:)`` follows the server's changes to the group, like the legacy playlist page: an
/// update replaces it, and a removal shows it as not found.
///
/// A model belongs to one group, client and account: it holds the signed-in account's service
/// and that account's ``ProgressCache``. Views recreate it per group ID and under the session's
/// `.id(identity)` (ADR 0004), so a server or user switch never reuses it.
@MainActor
@Observable
public final class GroupDetailModel<Kind: GroupDetailKind> {
    public enum Phase: Sendable, Hashable {
        /// Not loaded yet, and no load running.
        case idle
        /// The first load is running.
        case loading
        /// ``GroupDetailModel/detail`` is set; a reload may be running or may have failed.
        case loaded
        /// The last load failed and nothing was loaded before; see ``GroupDetailModel/error``.
        case failed
        /// The server answered 404. It stays until a load succeeds: a later failure that isn't a
        /// 404 (offline, timeout) doesn't bring the deleted group back, it only updates
        /// ``GroupDetailModel/error``.
        case notFound
    }

    public let groupID: String
    /// The signed-in user, whose playlists ``apply(_:)`` follows.
    public let userID: String?

    /// The last loaded group; kept while reloading and after a failed reload, dropped on 404.
    public private(set) var detail: GroupDetail?
    public private(set) var isLoading = false
    /// The error of the last load, cleared by the next successful one.
    public private(set) var error: (any Error)?
    /// The last load answered 404.
    public private(set) var isNotFound = false

    @ObservationIgnored private let service: any GroupsService
    @ObservationIgnored private let cache: ProgressCache
    @ObservationIgnored private var sequence = 0
    /// Bumped whenever ``detail`` or ``isNotFound`` is set: by a load, ``apply(_:)`` or an edit. An
    /// edit rolls back only while the revision it showed is current, so a newer state survives.
    @ObservationIgnored private(set) var revision = 0

    public init(id: String, service: any GroupsService, cache: ProgressCache, userID: String? = nil) {
        groupID = id
        self.userID = userID
        self.service = service
        self.cache = cache
    }

    public var phase: Phase {
        if isNotFound { return .notFound }
        if detail != nil { return .loaded }
        if isLoading { return .loading }
        return error == nil ? .idle : .failed
    }

    /// The group has been loaded and is still there.
    public var hasLoaded: Bool { detail != nil }

    /// Loaded with no members.
    public var isEmpty: Bool { detail?.members.isEmpty ?? false }

    /// Loads unless the group has already loaded. Views call it each time they appear, so a load
    /// cancelled before it finished runs again.
    public func loadIfNeeded() async {
        guard !hasLoaded else { return }
        await load()
    }

    /// Loads the group. A response to an older call that arrives after a newer one started is
    /// dropped.
    public func load() async {
        await loadReportingFailure()
    }

    /// ``load()``, returning its error when it failed (a cancellation included) and was the
    /// latest load; `nil` when it succeeded or a newer load or edit superseded it.
    @discardableResult
    func loadReportingFailure() async -> (any Error)? {
        sequence += 1
        let sequence = sequence
        isLoading = true
        let result: Result<GroupDetail, any Error>
        do {
            result = .success(try await Kind.detail(id: groupID, service: service))
        } catch {
            result = .failure(error)
        }
        guard sequence == self.sequence else { return nil }
        isLoading = false
        switch result {
        case .success(let loaded):
            revision += 1
            detail = loaded
            error = nil
            isNotFound = false
            return nil
        case .failure(let error):
            if error is CancellationError { return error }
            self.error = error
            if error as? APIError == .notFound {
                revision += 1
                isNotFound = true
                detail = nil
            }
            return error
        }
    }

    /// Applies a change the server pushed to this group, once it has loaded. Other groups, kinds,
    /// libraries and users' playlists are ignored: the store delivers every library's changes, and
    /// a group ID alone doesn't say which library's group changed.
    public func apply(_ change: LibraryChange) {
        guard let loaded = detail, let change = Kind.groupChange(change, userID: userID),
            change.libraryID == loaded.libraryID
        else { return }
        switch change {
        case .added(let group, _), .updated(let group, _):
            guard group.id == groupID else { return }
            revision += 1
            detail = group
        case .removed(let id, _):
            guard id == groupID else { return }
            revision += 1
            isNotFound = true
            detail = nil
        }
    }

    // MARK: Edits

    /// Shows `detail` for an edit: its optimistic result, the server's answer or a rollback. A
    /// load in flight is dropped, as it may have been answered before the edit.
    func showEdited(_ detail: GroupDetail) {
        sequence += 1
        revision += 1
        isLoading = false
        self.detail = detail
    }

    /// The group was deleted by an edit (deleting it, or removing its last member): it shows as
    /// not found, as after a removal the server pushed.
    func showDeleted() {
        sequence += 1
        revision += 1
        isLoading = false
        isNotFound = true
        detail = nil
    }

    // MARK: Progress and play-all

    /// The user's progress on `member`, if any.
    public func progress(of member: GroupMember) -> MediaProgress? {
        cache.progress(libraryItemID: member.target.itemID, episodeID: member.target.episodeID)
    }

    /// The members play-all can play, in order. Empty hides the Play button, as in legacy.
    public var playTargets: [GroupPlayTarget] {
        detail?.members.filter(\.isPlayable).map(\.target) ?? []
    }

    /// What play-all starts: the first playable member that isn't finished, or `nil` when every
    /// playable member is finished or none is playable (legacy then plays nothing).
    public var nextToPlay: GroupPlayTarget? {
        playTargets.first { target in
            !(cache.progress(libraryItemID: target.itemID, episodeID: target.episodeID)?.isFinished ?? false)
        }
    }
}
