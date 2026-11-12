import ABSAPI
import ABSCore
import Foundation
import Observation

/// The playlist detail screen's edits: reordering, removing members and deleting the playlist,
/// on a loaded ``PlaylistDetailModel``. The legacy mobile app only removed one member at a time
/// from its more menu (`components/modals/ItemMoreMenuModal.vue`); reordering and deleting follow
/// the web client.
///
/// - Reorders and removals are optimistic: the model shows the result at once, then the server's
///   playlist when the request succeeds. When it fails, the model goes back to the playlist as it
///   was and ``failure`` is set. A 404 means the playlist (or the member) is already gone, so the
///   model reloads instead, which shows the playlist as not found or the server's members; if that
///   reload fails, it goes back and ``failure`` is set too.
/// - Going back never undoes a newer state: when the server pushed the playlist (or a load
///   answered) after the edit showed, the model keeps that instead.
/// - One write runs at a time: edits while one is in flight are ignored (``canEdit``).
/// - A reorder sends every member once, in the new order (`PATCH /api/playlists/:id`); the server
///   rejects any other count with 400. One member is removed with
///   `DELETE /api/playlists/:id/item/:itemId[/:episodeId]`, several with `batch/remove`.
/// - Removing the last member deletes the playlist on the server, like ``deletePlaylist()``:
///   both set ``isDeleted`` for the view to leave the screen.
///
/// It belongs to one model and account, like the model it edits.
@MainActor
@Observable
public final class PlaylistDetailEditor {
    /// A failed edit, for the view's alert.
    public enum Failure: Sendable, Hashable {
        case reorder, remove, delete
    }

    public let model: PlaylistDetailModel
    /// A write is in flight.
    public private(set) var isSaving = false
    /// The last edit failed; ``clearFailure()`` hides it.
    public private(set) var failure: Failure?
    /// The user deleted the playlist, directly or by removing its last member.
    public private(set) var isDeleted = false

    @ObservationIgnored private let service: any PlaylistEditingService

    public init(model: PlaylistDetailModel, service: any PlaylistEditingService) {
        self.model = model
        self.service = service
    }

    /// The playlist has loaded, isn't deleted and no write is in flight.
    public var canEdit: Bool { model.detail != nil && !isSaving && !isDeleted }

    /// No write is in flight, so the sheet may close: one closed mid-write would leave the write
    /// running without its failure alert, and a reopened editor could start an overlapping one.
    public var canDismiss: Bool { !isSaving }

    public func clearFailure() {
        failure = nil
    }

    /// Moves the members at `source` to before the member at `destination`, as SwiftUI's
    /// `onMove` reports it, and saves the new order. Out-of-range offsets and moves that keep
    /// the order are ignored.
    public func move(fromOffsets source: IndexSet, toOffset destination: Int) async {
        guard canEdit, let before = model.detail, !source.isEmpty,
            source.allSatisfy(before.members.indices.contains), (0...before.members.count).contains(destination)
        else { return }
        let members = Self.moved(before.members, fromOffsets: source, toOffset: destination)
        guard members.map(\.id) != before.members.map(\.id) else { return }
        await write(.reorder, before: before, showing: members) { service in
            try await service.reorderPlaylist(id: before.id, items: members.map(\.reference))
        }
    }

    /// Moves the member `memberID` `offset` places (negative is up), for VoiceOver's move actions.
    public func move(memberID: String, by offset: Int) async {
        guard let members = model.detail?.members, let index = members.firstIndex(where: { $0.id == memberID })
        else { return }
        let target = index + offset
        guard offset != 0, members.indices.contains(target) else { return }
        await move(fromOffsets: [index], toOffset: offset > 0 ? target + 1 : target)
    }

    /// Removes the members at `offsets`, as SwiftUI's `onDelete` reports them.
    public func remove(atOffsets offsets: IndexSet) async {
        guard let members = model.detail?.members else { return }
        await remove(memberIDs: Set(offsets.filter(members.indices.contains).map { members[$0].id }))
    }

    /// Removes the members with these IDs (``GroupMember/id``); unknown IDs are ignored.
    public func remove(memberIDs: Set<String>) async {
        guard canEdit, let before = model.detail else { return }
        let removed = before.members.filter { memberIDs.contains($0.id) }
        guard let first = removed.first else { return }
        await write(.remove, before: before, showing: before.members.filter { !memberIDs.contains($0.id) }) {
            service in
            if removed.count == 1 {
                try await service.removeFromPlaylist(id: before.id, item: first.reference)
            } else {
                try await service.removeFromPlaylist(id: before.id, items: removed.map(\.reference))
            }
        }
    }

    /// Deletes the playlist. A 404 means it is gone already, which is what the user asked for.
    public func deletePlaylist() async {
        guard canEdit, let before = model.detail else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            try await service.deletePlaylist(id: before.id)
            showDeleted()
        } catch  where error as? APIError == .notFound {
            showDeleted()
        } catch {
            if !(error is CancellationError) { failure = .delete }
        }
    }

    // MARK: Private

    /// Shows `members` at once, then the server's answer to `request`, or `before` when it fails.
    private func write(
        _ kind: Failure, before: GroupDetail, showing members: [GroupMember],
        request: (any PlaylistEditingService) async throws -> Playlist
    ) async {
        isSaving = true
        defer { isSaving = false }
        model.showEdited(before.replacingMembers(members))
        let edit = model.revision
        do {
            let playlist = try await request(service)
            if playlist.items.isEmpty {
                showDeleted()
            } else {
                model.showEdited(GroupDetail(playlist: playlist))
            }
        } catch  where error as? APIError == .notFound {
            let reloadError = await model.loadReportingFailure()
            goBack(to: before, from: edit)
            if let reloadError, !(reloadError is CancellationError), reloadError as? APIError != .notFound {
                failure = kind
            }
        } catch {
            goBack(to: before, from: edit)
            if !(error is CancellationError) { failure = kind }
        }
    }

    /// Shows `before` again unless the model has shown anything since the edit's revision `edit`:
    /// a pushed update or a load's answer is newer than both.
    private func goBack(to before: GroupDetail, from edit: Int) {
        if model.revision == edit { model.showEdited(before) }
    }

    private func showDeleted() {
        model.showDeleted()
        isDeleted = true
    }

    /// `elements` with those at `source` moved to before the element at `destination`.
    static func moved<Element>(_ elements: [Element], fromOffsets source: IndexSet, toOffset destination: Int)
        -> [Element]
    {
        let moving = source.map { elements[$0] }
        var rest = elements
        for index in source.reversed() { rest.remove(at: index) }
        rest.insert(contentsOf: moving, at: destination - source.count(in: 0..<destination))
        return rest
    }
}

extension GroupMember {
    /// The playlist member the server knows this row as.
    var reference: PlaylistItemReference {
        PlaylistItemReference(libraryItemID: target.itemID, episodeID: target.episodeID)
    }
}

extension GroupDetail {
    /// The group with `members` in place of its own, for an optimistic edit.
    fileprivate func replacingMembers(_ members: [GroupMember]) -> GroupDetail {
        GroupDetail(
            id: id, libraryID: libraryID, name: name, description: description, members: members, covers: covers)
    }
}
