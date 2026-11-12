import ABSAPI
import ABSCore
import Foundation
import Synchronization
import Testing

@testable import ABSAppModel

/// A playlist write the editor sent: the playlist ID and the members, as `item` or `item/episode`.
private enum EditCall: Sendable, Hashable {
    case reorder(String, [String])
    case removeOne(String, String)
    case removeMany(String, [String])
    case delete(String)
}

extension PlaylistItemReference {
    fileprivate var label: String { episodeID.map { "\(libraryItemID)/\($0)" } ?? libraryItemID }
}

/// The calls a fake received, in order.
private final class PlaylistEditLog: Sendable {
    private let calls = Mutex<[EditCall]>([])
    func append(_ call: EditCall) { calls.withLock { $0.append(call) } }
    var all: [EditCall] { calls.withLock { $0 } }
}

/// A ``PlaylistEditingService`` that logs each write and answers it with `answer`; `nil` is the
/// plain `OK` of a delete.
private struct FakeEditing: PlaylistEditingService {
    let log = PlaylistEditLog()
    var answer: @Sendable (EditCall) async throws -> Playlist? = { _ in throw TestError.unexpected }

    private func send(_ call: EditCall) async throws -> Playlist {
        log.append(call)
        guard let playlist = try await answer(call) else { throw TestError.unexpected }
        return playlist
    }

    func allPlaylists(libraryID: String) async throws -> [Playlist] { throw TestError.unexpected }
    func createPlaylist(name: String, libraryID: String, items: [PlaylistItemReference]) async throws -> Playlist {
        throw TestError.unexpected
    }
    func addToPlaylist(id: String, items: [PlaylistItemReference]) async throws -> Playlist {
        throw TestError.unexpected
    }
    func removeFromPlaylist(id: String, items: [PlaylistItemReference]) async throws -> Playlist {
        try await send(.removeMany(id, items.map(\.label)))
    }
    func removeFromPlaylist(id: String, item: PlaylistItemReference) async throws -> Playlist {
        try await send(.removeOne(id, item.label))
    }
    func reorderPlaylist(id: String, items: [PlaylistItemReference]) async throws -> Playlist {
        try await send(.reorder(id, items.map(\.label)))
    }
    func deletePlaylist(id: String) async throws {
        log.append(.delete(id))
        _ = try await answer(.delete(id))
    }
}

private let book1 = GroupFixtures.book("b1")
private let book2 = GroupFixtures.book("b2")
private let podcast = GroupFixtures.podcast("pod")
private let episode = GroupFixtures.episode("e1")

/// `p1` with `entries`, as the server answers.
private func playlist(_ entries: [PlaylistItem]) -> Playlist {
    GroupFixtures.playlist("p1", items: entries)
}

private let b1 = GroupFixtures.bookEntry(book1)
private let b2 = GroupFixtures.bookEntry(book2)
private let e1 = GroupFixtures.episodeEntry(podcast, episode)
private let b3 = GroupFixtures.bookEntry(GroupFixtures.book("b3"))

/// An editor on `p1` loaded with `b1`, `pod/e1`, `b2`; later loads answer with `reload`.
@MainActor
private func loadedEditor(
    _ editing: FakeEditing, reload: @escaping @Sendable () async throws -> Playlist = { playlist([b1, e1, b2]) }
) async -> PlaylistDetailEditor {
    let loads = Mutex(0)
    let groups = FakeGroupsService(playlistHandler: { _ in
        let count = loads.withLock { count in
            count += 1
            return count
        }
        return count == 1 ? playlist([b1, e1, b2]) : try await reload()
    })
    let model = PlaylistDetailModel(id: "p1", service: groups, cache: ProgressCache(), userID: "u1")
    await model.load()
    return PlaylistDetailEditor(model: model, service: editing)
}

@MainActor
private func memberIDs(_ editor: PlaylistDetailEditor) -> [String]? {
    editor.model.detail?.members.map(\.id)
}

extension PlaylistDetailEditor {
    /// A move from a list that shows the playlist as it is now.
    fileprivate func move(fromOffsets source: IndexSet, toOffset destination: Int) async {
        await move(fromOffsets: source, toOffset: destination, in: model.detail?.members.map(\.id) ?? [])
    }

    /// A removal from a list that shows the playlist as it is now.
    fileprivate func remove(atOffsets offsets: IndexSet) async {
        await remove(atOffsets: offsets, in: model.detail?.members.map(\.id) ?? [])
    }
}

@MainActor
@Suite(.timeLimit(.minutes(1))) struct PlaylistDetailEditorTests {
    // MARK: Reorder

    @Test func aMoveShowsAtOnceSendsEveryMemberAndTakesTheServersOrder() async throws {
        let gate = CancellableGatedCalls<EditCall, Playlist?>()
        let writes = KeyedCallCounter()
        var editing = FakeEditing()
        // Only the first write waits for the test; a second one fails at once instead of waiting forever.
        editing.answer = { call in
            guard writes.record("write") == 1 else { throw TestError.unexpected }
            return try await gate.call(call)
        }
        let editor = await loadedEditor(editing)
        var calls = gate.calls.makeAsyncIterator()

        async let moved: Void = editor.move(fromOffsets: [2], toOffset: 0)
        let call = try #require(await calls.next())
        #expect(call.request == .reorder("p1", ["b2", "b1", "pod/e1"]))
        #expect(memberIDs(editor) == ["b2", "b1", "pod-e1"])
        #expect(editor.isSaving)
        #expect(!editor.canEdit)

        // A second edit while the first is in flight sends nothing.
        await editor.remove(memberIDs: ["b1"])
        await editor.move(fromOffsets: [0], toOffset: 2)
        #expect(editing.log.all.count == 1)

        call.reply.resume(returning: playlist([b2, e1, b1]))
        await moved
        #expect(memberIDs(editor) == ["b2", "pod-e1", "b1"])
        #expect(!editor.isSaving)
        #expect(editor.failure == nil)
    }

    @Test func aFailedMoveGoesBackAndReportsIt() async {
        var editing = FakeEditing()
        editing.answer = { _ in throw APIError.http(status: 400, message: "Length mismatch") }
        let editor = await loadedEditor(editing)
        await editor.move(fromOffsets: [0], toOffset: 3)
        #expect(editing.log.all == [.reorder("p1", ["pod/e1", "b2", "b1"])])
        #expect(memberIDs(editor) == ["b1", "pod-e1", "b2"])
        #expect(editor.failure == .reorder)
        editor.clearFailure()
        #expect(editor.failure == nil)
        #expect(editor.canEdit)
    }

    /// A playlist update the server pushed while a reorder was in flight is newer than the
    /// playlist the reorder would go back to, so a failed reorder keeps it.
    @Test func aFailedMoveKeepsAnUpdatePushedMeanwhile() async throws {
        let gate = CancellableGatedCalls<EditCall, Playlist?>()
        var editing = FakeEditing()
        editing.answer = { call in try await gate.call(call) }
        let editor = await loadedEditor(editing)
        var calls = gate.calls.makeAsyncIterator()

        async let moved: Void = editor.move(fromOffsets: [2], toOffset: 0)
        let call = try #require(await calls.next())
        editor.model.apply(.playlist(.updated(playlist([b1, e1, b2, b3]), libraryID: "lib"), userID: "u1"))
        call.reply.resume(throwing: APIError.http(status: 400, message: "Length mismatch"))
        await moved
        #expect(memberIDs(editor) == ["b1", "pod-e1", "b2", "b3"])
        #expect(editor.failure == .reorder)
        #expect(editor.canEdit)
    }

    /// A playlist update the server pushed while a reorder was in flight may predate or follow the
    /// reorder's commit, so a successful reorder reloads instead of showing its own response.
    @Test func aSuccessfulMoveReloadsAfterAnUpdatePushedMeanwhile() async throws {
        let gate = CancellableGatedCalls<EditCall, Playlist?>()
        var editing = FakeEditing()
        editing.answer = { call in try await gate.call(call) }
        let editor = await loadedEditor(editing) { playlist([b2, b1, e1, b3]) }
        var calls = gate.calls.makeAsyncIterator()

        async let moved: Void = editor.move(fromOffsets: [2], toOffset: 0)
        let call = try #require(await calls.next())
        editor.model.apply(.playlist(.updated(playlist([b2, b1, e1, b3]), libraryID: "lib"), userID: "u1"))
        call.reply.resume(returning: playlist([b2, b1, e1]))
        await moved
        #expect(memberIDs(editor) == ["b2", "b1", "pod-e1", "b3"])
        #expect(editor.failure == nil)
        #expect(editor.canEdit)
    }

    /// Another update is pushed while that reload runs: its answer may predate the update, so the
    /// pushed state stays.
    @Test func anUpdatePushedDuringTheReloadAfterAMoveWins() async throws {
        let gate = CancellableGatedCalls<EditCall, Playlist?>()
        let reloads = CancellableGatedCalls<Int, Playlist>()
        var editing = FakeEditing()
        editing.answer = { call in try await gate.call(call) }
        let editor = await loadedEditor(editing) { try await reloads.call(0) }
        var calls = gate.calls.makeAsyncIterator()
        var reloadCalls = reloads.calls.makeAsyncIterator()

        async let moved: Void = editor.move(fromOffsets: [2], toOffset: 0)
        let call = try #require(await calls.next())
        editor.model.apply(.playlist(.updated(playlist([b1, e1, b2]), libraryID: "lib"), userID: "u1"))
        call.reply.resume(returning: playlist([b2, b1, e1]))
        let reload = try #require(await reloadCalls.next())
        editor.model.apply(.playlist(.updated(playlist([b2, b1, e1, b3]), libraryID: "lib"), userID: "u1"))
        reload.reply.resume(returning: playlist([b2, b1, e1]))
        await moved
        #expect(memberIDs(editor) == ["b2", "b1", "pod-e1", "b3"])
        #expect(editor.failure == nil)
        #expect(editor.canEdit)
        #expect(!editor.model.isLoading)
    }

    /// The reload after a pushed update fails: the write succeeded, so the pushed state stays and
    /// nothing is reported.
    @Test func aFailedReloadAfterASuccessfulMoveKeepsThePushedUpdate() async throws {
        let gate = CancellableGatedCalls<EditCall, Playlist?>()
        var editing = FakeEditing()
        editing.answer = { call in try await gate.call(call) }
        let editor = await loadedEditor(editing) { throw TestError.offline }
        var calls = gate.calls.makeAsyncIterator()

        async let moved: Void = editor.move(fromOffsets: [2], toOffset: 0)
        let call = try #require(await calls.next())
        editor.model.apply(.playlist(.updated(playlist([b1, e1, b2, b3]), libraryID: "lib"), userID: "u1"))
        call.reply.resume(returning: playlist([b2, b1, e1]))
        await moved
        #expect(memberIDs(editor) == ["b1", "pod-e1", "b2", "b3"])
        #expect(editor.failure == nil)
    }

    /// An empty answer confirms the playlist is deleted, whatever was pushed meanwhile.
    @Test func anEmptyAnswerDeletesEvenAfterAnUpdatePushedMeanwhile() async throws {
        let gate = CancellableGatedCalls<EditCall, Playlist?>()
        var editing = FakeEditing()
        editing.answer = { call in try await gate.call(call) }
        let editor = await loadedEditor(editing)
        var calls = gate.calls.makeAsyncIterator()

        async let removed: Void = editor.remove(memberIDs: ["b1", "pod-e1", "b2"])
        let call = try #require(await calls.next())
        editor.model.apply(.playlist(.updated(playlist([b1, e1, b2]), libraryID: "lib"), userID: "u1"))
        call.reply.resume(returning: playlist([]))
        await removed
        #expect(editor.isDeleted)
        #expect(editor.model.phase == .notFound)
    }

    @Test(arguments: [
        (IndexSet([0]), 0), (IndexSet([0]), 1), (IndexSet([2]), 3), (IndexSet([3]), 0), (IndexSet([0]), 4),
        (IndexSet(), 1),
    ])
    func movesThatKeepTheOrderOrAreOutOfRangeSendNothing(source: IndexSet, destination: Int) async {
        let editing = FakeEditing()
        let editor = await loadedEditor(editing)
        await editor.move(fromOffsets: source, toOffset: destination)
        #expect(editing.log.all.isEmpty)
        #expect(memberIDs(editor) == ["b1", "pod-e1", "b2"])
    }

    /// A drag that ends after an update reordered the playlist is dropped: its offsets name the
    /// members as the list showed them, which are now in other places.
    @Test func aMoveAfterAnUpdateReorderedThePlaylistSendsNothing() async throws {
        let editing = FakeEditing()
        let editor = await loadedEditor(editing)
        let displayed = try #require(memberIDs(editor))
        editor.model.apply(.playlist(.updated(playlist([b2, b1, e1]), libraryID: "lib"), userID: "u1"))
        await editor.move(fromOffsets: [2], toOffset: 0, in: displayed)
        #expect(editing.log.all.isEmpty)
        #expect(memberIDs(editor) == ["b2", "b1", "pod-e1"])
        #expect(editor.failure == nil)
    }

    @Test func voiceOverMovesOnePlaceAndStopsAtTheEnds() async {
        var editing = FakeEditing()
        editing.answer = { call in
            guard case .reorder(_, let order) = call else { return nil }
            let entries = ["b1": b1, "b2": b2, "pod/e1": e1]
            return playlist(order.compactMap { entries[$0] })
        }
        let editor = await loadedEditor(editing)
        await editor.move(memberID: "pod-e1", by: 1)
        #expect(memberIDs(editor) == ["b1", "b2", "pod-e1"])
        await editor.move(memberID: "b2", by: -1)
        #expect(memberIDs(editor) == ["b2", "b1", "pod-e1"])
        await editor.move(memberID: "b2", by: -1)
        await editor.move(memberID: "pod-e1", by: 1)
        await editor.move(memberID: "unknown", by: 1)
        #expect(
            editing.log.all == [
                .reorder("p1", ["b1", "b2", "pod/e1"]), .reorder("p1", ["b2", "b1", "pod/e1"]),
            ])
    }

    @Test func movedMatchesSwiftUIsOnMove() {
        let letters = ["a", "b", "c", "d"]
        #expect(PlaylistDetailEditor.moved(letters, fromOffsets: [0], toOffset: 3) == ["b", "c", "a", "d"])
        #expect(PlaylistDetailEditor.moved(letters, fromOffsets: [3], toOffset: 0) == ["d", "a", "b", "c"])
        #expect(PlaylistDetailEditor.moved(letters, fromOffsets: [0, 2], toOffset: 4) == ["b", "d", "a", "c"])
        #expect(PlaylistDetailEditor.moved(letters, fromOffsets: [1, 3], toOffset: 1) == ["a", "b", "d", "c"])
    }

    /// An edit supersedes a load that started before it: the load's older answer is dropped.
    @Test func aLoadStartedBeforeAnEditDoesNotUndoIt() async throws {
        let gate = CancellableGatedCalls<Int, Playlist>()
        var editing = FakeEditing()
        editing.answer = { _ in playlist([b2, b1, e1]) }
        let editor = await loadedEditor(editing) { try await gate.call(2) }
        var calls = gate.calls.makeAsyncIterator()

        async let reload: Void = editor.model.load()
        let load = try #require(await calls.next())
        await editor.move(fromOffsets: [2], toOffset: 0)
        #expect(!editor.model.isLoading)
        load.reply.resume(returning: playlist([b1, e1, b2]))
        await reload
        #expect(memberIDs(editor) == ["b2", "b1", "pod-e1"])
    }

    // MARK: Remove

    @Test func removingAnEpisodeSendsItsEpisodeQualifiedDelete() async {
        var editing = FakeEditing()
        editing.answer = { _ in playlist([b1, b2]) }
        let editor = await loadedEditor(editing)
        await editor.remove(atOffsets: [1])
        #expect(editing.log.all == [.removeOne("p1", "pod/e1")])
        #expect(memberIDs(editor) == ["b1", "b2"])
        #expect(!editor.isDeleted)
    }

    @Test func removingABookSendsOnlyItsItemID() async {
        var editing = FakeEditing()
        editing.answer = { _ in playlist([e1, b2]) }
        let editor = await loadedEditor(editing)
        await editor.remove(memberIDs: ["b1"])
        #expect(editing.log.all == [.removeOne("p1", "b1")])
        #expect(memberIDs(editor) == ["pod-e1", "b2"])
    }

    @Test func removingSeveralSendsOneBatch() async {
        var editing = FakeEditing()
        editing.answer = { _ in playlist([e1]) }
        let editor = await loadedEditor(editing)
        await editor.remove(atOffsets: [0, 2, 7])
        #expect(editing.log.all == [.removeMany("p1", ["b1", "b2"])])
        #expect(memberIDs(editor) == ["pod-e1"])
    }

    @Test func removingNothingSendsNothing() async {
        let editing = FakeEditing()
        let editor = await loadedEditor(editing)
        await editor.remove(memberIDs: ["unknown"])
        await editor.remove(atOffsets: [])
        #expect(editing.log.all.isEmpty)
    }

    /// A swipe that ends after an update changed the playlist removes the member the list showed
    /// in that row, not the one there now, and nothing once that member is gone.
    @Test func aRemovalAfterAnUpdateRemovesTheMemberTheListShowed() async throws {
        var editing = FakeEditing()
        editing.answer = { _ in playlist([b2, e1]) }
        let editor = await loadedEditor(editing)
        let displayed = try #require(memberIDs(editor))
        editor.model.apply(.playlist(.updated(playlist([b2, e1, b1]), libraryID: "lib"), userID: "u1"))
        await editor.remove(atOffsets: [0], in: displayed)
        #expect(editing.log.all == [.removeOne("p1", "b1")])
        #expect(memberIDs(editor) == ["b2", "pod-e1"])

        await editor.remove(atOffsets: [0], in: displayed)
        #expect(editing.log.all == [.removeOne("p1", "b1")])
        #expect(memberIDs(editor) == ["b2", "pod-e1"])
    }

    /// The server deletes a playlist whose last member is removed, and answers with no items.
    @Test func removingTheLastMembersDeletesThePlaylist() async {
        var editing = FakeEditing()
        editing.answer = { _ in playlist([]) }
        let editor = await loadedEditor(editing)
        await editor.remove(memberIDs: ["b1", "pod-e1", "b2"])
        #expect(editor.isDeleted)
        #expect(editor.model.phase == .notFound)
        #expect(!editor.canEdit)
    }

    @Test func aFailedRemovalGoesBackAndReportsIt() async {
        var editing = FakeEditing()
        editing.answer = { _ in throw TestError.offline }
        let editor = await loadedEditor(editing)
        await editor.remove(memberIDs: ["b2"])
        #expect(memberIDs(editor) == ["b1", "pod-e1", "b2"])
        #expect(editor.failure == .remove)
        #expect(!editor.isDeleted)
    }

    /// 404: the member or the playlist is gone already, so the screen reloads to show what's left.
    @Test func aRemovalAnswered404Reloads() async {
        var editing = FakeEditing()
        editing.answer = { _ in throw APIError.notFound }
        let editor = await loadedEditor(editing) { playlist([b1, e1]) }
        await editor.remove(memberIDs: ["b2"])
        #expect(memberIDs(editor) == ["b1", "pod-e1"])
        #expect(editor.failure == nil)

        var gone = FakeEditing()
        gone.answer = { _ in throw APIError.notFound }
        let deleted = await loadedEditor(gone) { throw APIError.notFound }
        await deleted.move(fromOffsets: [0], toOffset: 2)
        #expect(deleted.model.phase == .notFound)
        #expect(deleted.failure == nil)
    }

    /// 404, then the reload fails too: nothing confirms the edit, so it goes back and says so.
    @Test func aFailedReloadAfter404GoesBackAndReportsIt() async {
        var editing = FakeEditing()
        editing.answer = { _ in throw APIError.notFound }
        let editor = await loadedEditor(editing) { throw TestError.offline }
        await editor.remove(memberIDs: ["b1", "pod-e1", "b2"])
        #expect(memberIDs(editor) == ["b1", "pod-e1", "b2"])
        #expect(editor.failure == .remove)
        #expect(!editor.isDeleted)

        editor.clearFailure()
        await editor.move(fromOffsets: [0], toOffset: 3)
        #expect(memberIDs(editor) == ["b1", "pod-e1", "b2"])
        #expect(editor.failure == .reorder)
    }

    @Test func aCancelledEditGoesBackWithoutAnAlert() async {
        var editing = FakeEditing()
        editing.answer = { _ in throw CancellationError() }
        let editor = await loadedEditor(editing)
        await editor.remove(memberIDs: ["b1"])
        #expect(memberIDs(editor) == ["b1", "pod-e1", "b2"])
        #expect(editor.failure == nil)
    }

    // MARK: Delete

    @Test func deletingThePlaylistLeavesIt() async {
        var editing = FakeEditing()
        editing.answer = { _ in nil }
        let editor = await loadedEditor(editing)
        await editor.deletePlaylist()
        #expect(editing.log.all == [.delete("p1")])
        #expect(editor.isDeleted)
        #expect(editor.model.phase == .notFound)
        await editor.deletePlaylist()
        #expect(editing.log.all.count == 1)
    }

    @Test func deletingAPlaylistThatIsGoneAlreadyLeavesIt() async {
        var editing = FakeEditing()
        editing.answer = { _ in throw APIError.notFound }
        let editor = await loadedEditor(editing)
        await editor.deletePlaylist()
        #expect(editor.isDeleted)
        #expect(editor.failure == nil)
    }

    @Test func aFailedDeleteKeepsThePlaylistAndReportsIt() async {
        var editing = FakeEditing()
        editing.answer = { _ in throw TestError.offline }
        let editor = await loadedEditor(editing)
        await editor.deletePlaylist()
        #expect(!editor.isDeleted)
        #expect(editor.failure == .delete)
        #expect(memberIDs(editor) == ["b1", "pod-e1", "b2"])
        #expect(editor.canEdit)
    }

    /// The sheet can't close while a reorder, removal or delete is in flight.
    @Test func theSheetCanCloseOnlyBetweenWrites() async throws {
        let gate = CancellableGatedCalls<EditCall, Playlist?>()
        var editing = FakeEditing()
        editing.answer = { call in try await gate.call(call) }
        let editor = await loadedEditor(editing)
        var calls = gate.calls.makeAsyncIterator()
        #expect(editor.canDismiss)

        async let moved: Void = editor.move(fromOffsets: [2], toOffset: 0)
        var call = try #require(await calls.next())
        #expect(!editor.canDismiss)
        call.reply.resume(returning: playlist([b2, b1, e1]))
        await moved
        #expect(editor.canDismiss)

        async let removed: Void = editor.remove(memberIDs: ["b1"])
        call = try #require(await calls.next())
        #expect(!editor.canDismiss)
        call.reply.resume(throwing: TestError.offline)
        await removed
        #expect(editor.canDismiss)

        async let deleted: Void = editor.deletePlaylist()
        call = try #require(await calls.next())
        #expect(!editor.canDismiss)
        call.reply.resume(returning: nil)
        await deleted
        #expect(editor.isDeleted)
        #expect(editor.canDismiss)
    }

    @Test func nothingIsSentBeforeThePlaylistLoads() async {
        let editing = FakeEditing()
        let model = PlaylistDetailModel(id: "p1", service: FakeGroupsService(), cache: ProgressCache())
        let editor = PlaylistDetailEditor(model: model, service: editing)
        await editor.move(fromOffsets: [0], toOffset: 2)
        await editor.remove(atOffsets: [0])
        await editor.deletePlaylist()
        #expect(editing.log.all.isEmpty)
        #expect(!editor.canEdit)
    }
}
