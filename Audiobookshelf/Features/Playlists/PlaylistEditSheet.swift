import ABSAPI
import ABSAppModel
import ABSCore
import ABSUI
import SwiftUI

/// Edits a playlist from its detail screen: drag to reorder, swipe or the context menu to remove a member, and Delete
/// Playlist with a confirmation. VoiceOver gets Move Up and Move Down actions on each row. Rows and buttons are
/// disabled while a write is in flight (``PlaylistDetailEditor/canEdit``), and so is closing the sheet, with Done, a
/// swipe or Escape (``PlaylistDetailEditor/canDismiss``). The detail screen closes the sheet and leaves when
/// ``PlaylistDetailEditor/isDeleted`` turns true.
struct PlaylistEditSheet: View {
    let editor: PlaylistDetailEditor
    @Environment(\.dismiss) private var dismiss
    @State private var confirmsDelete = false

    var body: some View {
        NavigationStack {
            list
                .navigationTitle(Text(verbatim: editor.model.detail?.name ?? L10n.string("HeaderPlaylist")))
                #if os(iOS)
                    .navigationBarTitleDisplayMode(.inline)
                    // Drag handles and delete buttons without a separate Edit tap.
                    .environment(\.editMode, .constant(.active))
                #endif
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button {
                            dismiss()
                        } label: {
                            Text(verbatim: L10n.string("ButtonDone"))
                        }
                        .disabled(!editor.canDismiss)
                    }
                    if editor.isSaving {
                        ToolbarItem(placement: .status) {
                            ProgressView()
                                .accessibilityLabel(Text(verbatim: L10n.string("MessageLoading")))
                        }
                    }
                }
        }
        #if os(macOS)
            .frame(minWidth: 380, idealWidth: 460, minHeight: 420, idealHeight: 560)
        #endif
        .interactiveDismissDisabled(!editor.canDismiss)
        .alert(
            Text(verbatim: editor.failure.map { L10n.string(Self.failureKey($0)) } ?? ""),
            isPresented: Binding(get: { editor.failure != nil }, set: { if !$0 { editor.clearFailure() } })
        ) {
            Button(L10n.string("ButtonOk")) {}
        }
        .confirmationDialog(
            Text(verbatim: L10n.string("MessageConfirmRemovePlaylist", editor.model.detail?.name ?? "")),
            isPresented: $confirmsDelete, titleVisibility: .visible
        ) {
            Button(role: .destructive) {
                Task { await editor.deletePlaylist() }
            } label: {
                Text(verbatim: L10n.string("ButtonDeletePlaylist"))
            }
        }
    }

    private var list: some View {
        let members = editor.model.detail?.members ?? []
        return List {
            Section {
                ForEach(Array(members.enumerated()), id: \.element.id) { index, member in
                    PlaylistEditRow(member: member)
                        .contextMenu {
                            Button(role: .destructive) {
                                remove(member)
                            } label: {
                                Label {
                                    Text(verbatim: L10n.string("LabelRemoveFromPlaylist"))
                                } icon: {
                                    Image(systemName: "minus.circle")
                                }
                            }
                            .disabled(!editor.canEdit)
                        }
                        .accessibilityActions {
                            if editor.canEdit, index > 0 {
                                Button(L10n.string("ButtonMoveUp")) { move(member, by: -1) }
                            }
                            if editor.canEdit, index < members.count - 1 {
                                Button(L10n.string("ButtonMoveDown")) { move(member, by: 1) }
                            }
                        }
                }
                .onMove { source, destination in
                    Task { await editor.move(fromOffsets: source, toOffset: destination) }
                }
                .onDelete { offsets in
                    Task { await editor.remove(atOffsets: offsets) }
                }
                .moveDisabled(!editor.canEdit)
                .deleteDisabled(!editor.canEdit)
            } header: {
                Text(verbatim: L10n.string("HeaderPlaylistItems"))
            }
            Section {
                Button(role: .destructive) {
                    confirmsDelete = true
                } label: {
                    Label {
                        Text(verbatim: L10n.string("ButtonDeletePlaylist"))
                    } icon: {
                        Image(systemName: "trash")
                    }
                }
                .disabled(!editor.canEdit)
            }
        }
    }

    private func remove(_ member: GroupMember) {
        Task { await editor.remove(memberIDs: [member.id]) }
    }

    private func move(_ member: GroupMember, by offset: Int) {
        Task { await editor.move(memberID: member.id, by: offset) }
    }

    static func failureKey(_ failure: PlaylistDetailEditor.Failure) -> String {
        switch failure {
        case .reorder: "MessagePlaylistReorderFailed"
        case .remove: "MessagePlaylistRemoveFailed"
        case .delete: "MessagePlaylistDeleteFailed"
        }
    }
}

/// A member's title and subtitle (author, or the podcast of an episode), read as one element.
private struct PlaylistEditRow: View {
    let member: GroupMember

    var body: some View {
        VStack(alignment: .leading, spacing: ABSSpacing.xSmall) {
            Text(verbatim: member.summary.title)
                .lineLimit(2)
            if let subtitle = member.summary.subtitle {
                Text(verbatim: subtitle)
                    .font(.footnote)
                    .foregroundStyle(ABSColor.mutedForeground)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, ABSSpacing.xSmall)
        .accessibilityElement(children: .combine)
    }
}

#if DEBUG
    /// Answers writes after a short delay with the playlist the editor asked for; fails every write when `fails`.
    struct PlaylistEditPreviewService: PlaylistEditingService {
        struct Failure: Error {}

        var fails = false

        func allPlaylists(libraryID: String) async throws -> [Playlist] { SampleLibrary.playlists }
        func createPlaylist(name: String, libraryID: String, items: [PlaylistItemReference]) async throws -> Playlist {
            throw Failure()
        }
        func addToPlaylist(id: String, items: [PlaylistItemReference]) async throws -> Playlist { throw Failure() }
        func removeFromPlaylist(id: String, items: [PlaylistItemReference]) async throws -> Playlist {
            let removed = Set(items.map(Self.key))
            return try await respond(keeping: { !removed.contains(Self.key($0)) }, order: nil)
        }
        func removeFromPlaylist(id: String, item: PlaylistItemReference) async throws -> Playlist {
            try await removeFromPlaylist(id: id, items: [item])
        }
        func reorderPlaylist(id: String, items: [PlaylistItemReference]) async throws -> Playlist {
            try await respond(keeping: { _ in true }, order: items.map(Self.key))
        }
        func deletePlaylist(id: String) async throws {
            try await Task.sleep(for: .milliseconds(600))
            if fails { throw Failure() }
        }

        private static func key(_ item: PlaylistItemReference) -> String {
            "\(item.libraryItemID)/\(item.episodeID ?? "")"
        }
        private static func key(_ item: PlaylistItem) -> String { "\(item.libraryItemId)/\(item.episodeId ?? "")" }

        private func respond(keeping: (PlaylistItem) -> Bool, order: [String]?) async throws -> Playlist {
            try await Task.sleep(for: .milliseconds(600))
            if fails { throw Failure() }
            let playlist = SampleLibrary.playlists[0]
            var items = playlist.items.filter(keeping)
            if let order {
                items.sort { (order.firstIndex(of: Self.key($0)) ?? 0) < (order.firstIndex(of: Self.key($1)) ?? 0) }
            }
            return Playlist(
                id: playlist.id, libraryId: playlist.libraryId, name: playlist.name, description: playlist.description,
                items: items)
        }
    }

    @MainActor
    private func previewEditor(fails: Bool = false) -> PlaylistDetailEditor {
        PlaylistDetailEditor(model: GroupsPreviewData.playlist(), service: PlaylistEditPreviewService(fails: fails))
    }

    #Preview("Edit playlist") {
        @Previewable @State var editor = previewEditor()
        PlaylistEditSheet(editor: editor)
            .task { await editor.model.load() }
    }

    #Preview("Edits fail, largest text") {
        @Previewable @State var editor = previewEditor(fails: true)
        PlaylistEditSheet(editor: editor)
            .task { await editor.model.load() }
            .dynamicTypeSize(.accessibility3)
    }
#endif
