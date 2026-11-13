import ABSAppModel
import ABSCore
import ABSUI
import SwiftUI

/// One collection or playlist (legacy `pages/collection/_id.vue` and `pages/playlist/_id.vue`): its cover, Play, its
/// description and its members in order with their progress; a playlist's members mix books and podcast episodes.
/// Builds one ``GroupDetailModel`` per store, account, library and group.
struct GroupDetailView<Kind: GroupScreenKind>: View {
    let groupID: String
    @Environment(\.libraryStore) private var store
    @Environment(Router.self) private var router: Router?
    @State private var host: BrowseModelHost<GroupDetailModel<Kind>>?

    var body: some View {
        let libraryID = router?.libraryID
        let key = BrowseModelKey(store: store, libraryID: libraryID, entityID: groupID)
        Group {
            if let host, let model = host.model(for: key) {
                GroupDetailContent(model: model, libraryID: host.key.libraryID, editing: editing(for: host))
            } else {
                BrowsePlaceholder(libraryID: libraryID, messages: GroupPresentation.detailMessages(Kind.summaryKind))
                    .navigationTitle(Text(verbatim: L10n.string(GroupPresentation.detailTitleKey(Kind.summaryKind))))
            }
        }
        .task(id: key) {
            host = .updated(host, for: key, store: store) { key, services, progress in
                let model = GroupDetailModel<Kind>(
                    id: groupID, service: services, cache: progress, userID: key.connection.userID)
                store?.observeLibraryChanges(connectionKey: key.connection, owner: model) { [weak model] in
                    model?.apply($0)
                }
                return model
            }
            await host?.model.loadIfNeeded()
        }
    }

    /// The account's playlist writes for a playlist screen; `nil` for a collection, which can't be edited here.
    private func editing(for host: BrowseModelHost<GroupDetailModel<Kind>>) -> (any PlaylistEditingService)? {
        guard Kind.summaryKind == .playlist, let services = store?.makeServices(),
            services.connectionKey == host.key.connection
        else { return nil }
        return services
    }
}

/// The group screen for one model in the library `libraryID`; previews give it a fixture service. Pull to refresh or
/// ⌘R reloads it. With `editing`, a playlist's Edit button opens ``PlaylistEditSheet``, and the screen closes once the
/// playlist is deleted from there.
struct GroupDetailContent<Kind: GroupScreenKind>: View {
    let model: GroupDetailModel<Kind>
    let libraryID: String
    var editing: (any PlaylistEditingService)?
    @Environment(\.dismiss) private var dismiss
    @State private var editor: PlaylistDetailEditor?

    var body: some View {
        let kind = Kind.summaryKind
        let messages = GroupPresentation.detailMessages(kind)
        let detail = GroupPresentation.detail(of: model, libraryID: libraryID)
        let state = GroupPresentation.state(of: model, libraryID: libraryID)
        BrowseStateView(state: state, messages: messages, retry: { reload() }) { failed in
            if let detail {
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: ABSSpacing.large) {
                        if failed {
                            BrowseFailureRow(messageKey: messages.failed, retry: { reload() })
                        }
                        GroupDetailHeader(detail: detail, model: model)
                        Text(verbatim: L10n.string(GroupPresentation.membersHeaderKey(kind)))
                            .font(.headline)
                            .accessibilityAddTraits(.isHeader)
                            .padding(.horizontal, ABSSpacing.large)
                        if detail.members.isEmpty {
                            Text(verbatim: L10n.string(messages.empty))
                                .foregroundStyle(ABSColor.mutedForeground)
                                .padding(.horizontal, ABSSpacing.large)
                        } else {
                            // A playlist entry whose item the server didn't expand is titled with its ID (`GroupMember`).
                            BrowseItemGrid(elements: detail.members, item: \.summary)
                        }
                    }
                    .padding(.vertical, ABSSpacing.large)
                }
            }
        }
        .navigationTitle(Text(verbatim: detail?.name ?? L10n.string(GroupPresentation.detailTitleKey(kind))))
        .refreshable { await model.load() }
        .refreshCommand(
            .pushed(GroupPresentation.route(Kind.summaryKind, id: model.groupID)), isDisabled: model.isLoading
        ) {
            reload()
        }
        .toolbar {
            if let editing, detail != nil, let playlist = model as? PlaylistDetailModel {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        editor = PlaylistDetailEditor(model: playlist, service: editing)
                    } label: {
                        Text(verbatim: L10n.string("ButtonEdit"))
                    }
                }
            }
        }
        .sheet(isPresented: Binding(get: { editor != nil }, set: { if !$0 { editor = nil } })) {
            if let editor {
                PlaylistEditSheet(editor: editor)
            }
        }
        .onChange(of: editor?.isDeleted ?? false) { _, isDeleted in
            guard isDeleted else { return }
            editor = nil
            dismiss()
        }
        .rssFeedEntry(RssFeedPresentation.target(Kind.summaryKind, id: model.groupID))
    }

    private func reload() {
        Task { await model.load() }
    }
}

/// The group cover, Play (shown while a member is playable) and the description.
private struct GroupDetailHeader<Kind: GroupScreenKind>: View {
    let detail: GroupDetail
    let model: GroupDetailModel<Kind>
    @Environment(\.serverID) private var serverID
    @Environment(\.playItem) private var playItem
    @Environment(\.currentPlayback) private var playback
    @State private var isStarting = false
    /// The key of the message for the last failed start, kept while the alert is dismissed.
    @State private var failureKey: String?
    @State private var showsFailure = false

    var body: some View {
        VStack(alignment: .leading, spacing: ABSSpacing.medium) {
            GroupCover(name: detail.name, covers: detail.covers, serverID: serverID)
                .frame(maxWidth: 240)
                .frame(maxWidth: .infinity)
                // The navigation title names the group.
                .accessibilityHidden(true)
            if let playAll = GroupPresentation.playAll(
                of: model, canPlay: playItem != nil && !isStarting, nowPlaying: playback?.mediaKey,
                isPlaying: playback?.isPlaying ?? false, serverID: serverID)
            {
                Button {
                    start(playAll)
                } label: {
                    Label {
                        Text(verbatim: L10n.string(playAll.titleKey))
                    } icon: {
                        Image(systemName: playAll.systemImage)
                    }
                    .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!playAll.isEnabled)
                .accessibilityLabel(Text(verbatim: GroupPresentation.playAllAccessibilityLabel(playAll)))
                .accessibilityHint(Text(verbatim: playAll.hintKey.map { L10n.string($0) } ?? ""))
            }
            if let description = detail.description {
                ExpandableText(description, collapsedLineLimit: 4)
            }
        }
        .padding(.horizontal, ABSSpacing.large)
        .alert(
            Text(verbatim: failureKey.map { L10n.string($0) } ?? ""), isPresented: $showsFailure,
            presenting: failureKey
        ) { _ in
            Button(L10n.string("ButtonOk")) {}
        }
    }

    private func start(_ playAll: GroupPlayAll) {
        let play = playItem
        let playback = playback
        isStarting = true
        Task {
            defer { isStarting = false }
            if let key = await GroupPresentation.performPlayAll(playAll, play: play, pause: { playback?.pause() }) {
                failureKey = key
                showsFailure = true
            }
        }
    }
}

#if DEBUG
    #Preview("Collection") {
        @Previewable @State var model = GroupsPreviewData.collection()
        NavigationStack {
            GroupDetailContent(model: model, libraryID: SampleLibrary.libraryID)
        }
        .task { await model.load() }
        .environment(\.serverID, UUID())
        .environment(\.itemProgressReader, GroupsPreviewData.progressReader)
        .environment(\.playItem, PlayItemAction { _, _, _ in })
        .absBackground()
    }

    #Preview("Playlist, largest text, dark") {
        @Previewable @State var model = GroupsPreviewData.playlist()
        NavigationStack {
            GroupDetailContent(model: model, libraryID: SampleLibrary.libraryID)
        }
        .task { await model.load() }
        .environment(\.itemProgressReader, GroupsPreviewData.progressReader)
        .environment(\.dynamicTypeSize, .accessibility3)
        .absBackground()
        .preferredColorScheme(.dark)
    }

    #Preview("Playlist, editable") {
        @Previewable @State var model = GroupsPreviewData.playlist()
        NavigationStack {
            GroupDetailContent(model: model, libraryID: SampleLibrary.libraryID, editing: PlaylistEditPreviewService())
        }
        .task { await model.load() }
        .environment(\.itemProgressReader, GroupsPreviewData.progressReader)
        .absBackground()
    }

    #Preview("Playlist, failed") {
        @Previewable @State var model = GroupsPreviewData.playlist(fails: true)
        NavigationStack {
            GroupDetailContent(model: model, libraryID: SampleLibrary.libraryID)
        }
        .task { await model.load() }
        .absBackground()
    }
#endif
