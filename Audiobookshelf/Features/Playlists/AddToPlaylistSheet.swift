import ABSAPI
import ABSAppModel
import ABSCore
import ABSUI
import SwiftUI

/// The add-to-playlist sheet (legacy `components/modals/playlists/AddCreateModal.vue`): the user's playlists in the
/// library, checked when they contain every entry, and a field to create a playlist with the entries. Tapping a row
/// adds the entries or, when checked, removes them.
struct AddToPlaylistSheet: View {
    let model: AddToPlaylistModel
    @Environment(\.dismiss) private var dismiss
    @State private var newName = ""

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(Text(verbatim: L10n.string("LabelAddToPlaylist")))
                #if os(iOS)
                    .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button {
                            dismiss()
                        } label: {
                            Text(verbatim: L10n.string("ButtonDone"))
                        }
                    }
                }
        }
        #if os(macOS)
            .frame(minWidth: 360, idealWidth: 420, minHeight: 420, idealHeight: 520)
        #endif
        .task {
            if !model.hasLoaded { await model.load() }
        }
        .alert(
            Text(verbatim: model.failure.map { L10n.string(Self.failureKey($0)) } ?? ""),
            isPresented: Binding(get: { model.failure != nil }, set: { if !$0 { model.clearFailure() } })
        ) {
            Button(L10n.string("ButtonOk")) {}
        }
    }

    @ViewBuilder
    private var content: some View {
        if model.hasLoaded {
            List {
                Section {
                    createRow
                } header: {
                    Text(verbatim: L10n.string("HeaderNewPlaylist"))
                }
                Section {
                    if model.rows.isEmpty {
                        Text(verbatim: L10n.string("MessageNoUserPlaylists"))
                            .foregroundStyle(.secondary)
                    }
                    ForEach(model.rows) { row in
                        AddToPlaylistRow(row: row) { Task { await model.toggle(playlistID: row.id) } }
                    }
                }
            }
        } else if model.loadFailed, !model.isLoading {
            ContentUnavailableView {
                Label {
                    Text(verbatim: L10n.string("MessagePlaylistsListLoadFailed"))
                } icon: {
                    Image(systemName: "exclamationmark.triangle")
                }
            } actions: {
                Button {
                    Task { await model.load() }
                } label: {
                    Text(verbatim: L10n.string("ButtonRetry"))
                }
            }
        } else {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityLabel(Text(verbatim: L10n.string("MessageLoading")))
        }
    }

    private var createRow: some View {
        HStack {
            TextField(text: $newName) {
                Text(verbatim: L10n.string("LabelName"))
            }
            .onSubmit(create)
            .submitLabel(.done)
            // Locked while creating; `create()` also clears the field only if it still holds the name it sent.
            .disabled(model.isCreating)
            if model.isCreating {
                ProgressView()
                    .accessibilityLabel(Text(verbatim: L10n.string("MessageLoading")))
            } else {
                Button(action: create) {
                    Text(verbatim: L10n.string("ButtonCreate"))
                }
                .disabled(newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    private func create() {
        let name = newName
        Task {
            if await model.create(name: name), newName == name { newName = "" }
        }
    }

    /// The alert message key of a failed action.
    static func failureKey(_ failure: AddToPlaylistModel.Failure) -> String {
        switch failure {
        case .add: "MessagePlaylistAddFailed"
        case .remove: "MessagePlaylistRemoveFailed"
        case .create: "ToastPlaylistCreateFailed"
        }
    }
}

/// One playlist: its name and item count, checked when it contains every entry; a spinner while a toggle runs.
private struct AddToPlaylistRow: View {
    let row: AddToPlaylistModel.Row
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack {
                VStack(alignment: .leading) {
                    Text(verbatim: row.name)
                    Text(verbatim: GroupPresentation.itemCount(row.itemCount))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if row.isUpdating {
                    ProgressView()
                } else if row.isChecked {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.tint)
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(row.isUpdating)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            Text(
                verbatim: GroupPresentation.cardAccessibilityLabel(
                    GroupSummary(id: row.id, kind: .playlist, name: row.name, itemCount: row.itemCount)))
        )
        .accessibilityValue(Text(verbatim: row.isUpdating ? L10n.string("MessageLoading") : ""))
        .accessibilityAddTraits(row.isChecked ? [.isButton, .isSelected] : .isButton)
        .accessibilityHint(
            Text(verbatim: L10n.string(row.isChecked ? "LabelRemoveFromPlaylist" : "LabelAddToPlaylist")))
    }
}

#if DEBUG
    /// Serves ``SampleLibrary``'s playlists plus an empty one and answers writes after a short delay; fails every
    /// request when `fails`.
    private struct AddToPlaylistPreviewService: PlaylistEditingService {
        struct Failure: Error {}

        var fails = false
        var playlists =
            SampleLibrary.playlists + [Playlist(id: "pl_empty", libraryId: SampleLibrary.libraryID, name: "Road Trip")]

        func allPlaylists(libraryID: String) async throws -> [Playlist] {
            try check()
            return playlists
        }

        func createPlaylist(name: String, libraryID: String, items: [PlaylistItemReference]) async throws -> Playlist {
            try await respond(Playlist(id: UUID().uuidString, libraryId: libraryID, name: name, items: members(items)))
        }

        func addToPlaylist(id: String, items: [PlaylistItemReference]) async throws -> Playlist {
            let playlist = try find(id)
            return try await respond(playlist, items: playlist.items + members(items))
        }

        func removeFromPlaylist(id: String, items: [PlaylistItemReference]) async throws -> Playlist {
            let playlist = try find(id)
            let removed = Set(items.map { "\($0.libraryItemID)/\($0.episodeID ?? "")" })
            return try await respond(
                playlist,
                items: playlist.items.filter { !removed.contains("\($0.libraryItemId)/\($0.episodeId ?? "")") })
        }

        func removeFromPlaylist(id: String, item: PlaylistItemReference) async throws -> Playlist {
            try await removeFromPlaylist(id: id, items: [item])
        }

        func reorderPlaylist(id: String, items: [PlaylistItemReference]) async throws -> Playlist {
            try await respond(try find(id))
        }

        func deletePlaylist(id: String) async throws { try check() }

        private func find(_ id: String) throws -> Playlist {
            guard let playlist = playlists.first(where: { $0.id == id }) else { throw Failure() }
            return playlist
        }

        private func members(_ items: [PlaylistItemReference]) -> [PlaylistItem] {
            items.map { PlaylistItem(libraryItemId: $0.libraryItemID, episodeId: $0.episodeID) }
        }

        private func respond(_ playlist: Playlist, items: [PlaylistItem]? = nil) async throws -> Playlist {
            try await Task.sleep(for: .milliseconds(600))
            try check()
            return Playlist(
                id: playlist.id, libraryId: playlist.libraryId, name: playlist.name, items: items ?? playlist.items)
        }

        private func check() throws {
            if fails { throw Failure() }
        }
    }

    @MainActor
    private func previewModel(_ entries: [PlaylistEntryKey], service: AddToPlaylistPreviewService = .init())
        -> AddToPlaylistModel
    {
        AddToPlaylistModel(entries: entries, libraryID: SampleLibrary.libraryID, service: service)
    }

    #Preview("Book") {
        AddToPlaylistSheet(model: previewModel([PlaylistEntryKey(itemID: SampleLibrary.sherlock.id)]))
    }

    #Preview("Episode") {
        AddToPlaylistSheet(model: previewModel([PlaylistEntryKey(itemID: SampleLibrary.podcast.id, episodeID: "ep_2")]))
    }

    #Preview("No playlists") {
        AddToPlaylistSheet(
            model: previewModel([PlaylistEntryKey(itemID: SampleLibrary.emma.id)], service: .init(playlists: [])))
    }

    #Preview("Failed") {
        AddToPlaylistSheet(
            model: previewModel([PlaylistEntryKey(itemID: SampleLibrary.emma.id)], service: .init(fails: true)))
    }

    #Preview("Accessibility size") {
        AddToPlaylistSheet(model: previewModel([PlaylistEntryKey(itemID: SampleLibrary.sherlock.id)]))
            .dynamicTypeSize(.accessibility3)
    }
#endif
