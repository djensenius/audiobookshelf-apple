import ABSAppModel
import ABSCore
import ABSUI
import SwiftUI

/// The Collections or Playlists section (legacy `pages/bookshelf/collections.vue` and `playlists.vue`): the router's
/// library's groups, a page at a time. Builds one list model per store, account and library from `makeServices()`,
/// so a library switch or another account never shows the previous list.
struct GroupListView: View {
    let kind: GroupSummary.Kind
    @Environment(\.libraryStore) private var store
    @Environment(Router.self) private var router: Router?
    @State private var host: BrowseModelHost<GroupListModel>?

    var body: some View {
        let libraryID = router?.libraryID
        let key = BrowseModelKey(store: store, libraryID: libraryID)
        Group {
            if let model = host?.model(for: key) {
                GroupListContent(kind: kind, model: model)
            } else {
                BrowsePlaceholder(libraryID: libraryID, messages: GroupPresentation.listMessages(kind))
            }
        }
        .navigationTitle(Text(verbatim: L10n.string(GroupPresentation.tab(kind).titleKey)))
        .task(id: key) {
            host = .updated(host, for: key, store: store) { key, services, _ in
                let model = GroupPresentation.makeList(kind, key: key, services: services)
                store?.observeLibraryChanges(connectionKey: key.connection, owner: model) { [weak model, kind] in
                    model?.apply($0, kind: kind)
                }
                return model
            }
            if let model = host?.model, model.items.isEmpty, !model.reachedEnd {
                await model.loadNextPage()?.value
            }
        }
    }
}

/// The group grid of one model; previews give it a fixture service.
struct GroupListContent: View {
    let kind: GroupSummary.Kind
    let model: GroupListModel
    @Environment(Router.self) private var router: Router?
    @Environment(\.serverID) private var serverID
    /// The last user refresh failed and nothing loaded since.
    @State private var refreshFailed = false
    /// Successful user refreshes; cards report appearing again after each (as in ``BrowseItemGrid``).
    @State private var refreshes = 0

    var body: some View {
        let messages = GroupPresentation.listMessages(kind)
        BrowseStateView(state: .resolve(list: model), messages: messages, retry: { retry() }) { failed in
            let placement = BrowsePresentation.failurePlacement(failed: failed, refreshFailed: refreshFailed)
            ScrollView(.vertical) {
                VStack(spacing: ABSSpacing.large) {
                    if placement == .top {
                        BrowseFailureRow(messageKey: messages.failed, retry: { Task { await refresh() } })
                    }
                    ItemGrid(elements: model.items) { group in
                        GroupCard(group: group, serverID: serverID) {
                            BrowsePresentation.open(GroupPresentation.route(kind, id: group.id), in: router)
                        }
                        .task(id: refreshes) { model.itemAppeared(id: group.id) }
                    }
                    BrowsePagingFooter(
                        isLoading: model.isLoading, failed: placement == .footer, messageKey: messages.failed,
                        retry: { retry() })
                }
                .padding(.vertical, ABSSpacing.large)
            }
        }
        .refreshable { await refresh() }
        .refreshCommand(.root(GroupPresentation.tab(kind)), isDisabled: model.isLoading) { Task { await refresh() } }
        .onChange(of: model.error == nil) { _, cleared in
            if cleared { refreshFailed = false }
        }
    }

    private func refresh() async {
        refreshFailed = await BrowsePresentation.refresh(model)
        if !refreshFailed { refreshes += 1 }
    }

    private func retry() {
        BrowsePresentation.retry(model)
    }
}

/// A collection or playlist as a fan of its first covers with its name and item count (legacy
/// `LazyCollectionCard.vue` and `LazyPlaylistCard.vue`). A tap calls `onOpen`.
struct GroupCard: View {
    let group: GroupSummary
    let serverID: UUID?
    let onOpen: () -> Void
    @Environment(\.locale) private var locale

    var body: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: ABSSpacing.xSmall) {
                GroupCover(name: group.name, covers: group.covers, serverID: serverID)
                Text(verbatim: group.name)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2, reservesSpace: true)
                    .foregroundStyle(ABSColor.foreground)
                Text(verbatim: GroupPresentation.itemCount(group.itemCount, locale: locale))
                    .font(.caption)
                    .foregroundStyle(ABSColor.mutedForeground)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .itemHover()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: GroupPresentation.cardAccessibilityLabel(group, locale: locale)))
        .accessibilityHint(Text(verbatim: L10n.string("SharedOpenDetailsHint")))
        .accessibilityAddTraits(.isButton)
    }
}

/// A group's cover: its members' covers fanned out, or its name without any (legacy `GroupCover.vue`).
struct GroupCover: View {
    let name: String
    let covers: [CoverRef]
    let serverID: UUID?

    var body: some View {
        GroupCoverView(name: name, keys: serverID.map { id in covers.map { $0.key(serverID: id) } } ?? [])
            .aspectRatio(1.25, contentMode: .fit)
    }
}

#if DEBUG
    #Preview("Collections") {
        @Previewable @State var model = GroupsPreviewData.list(.collection)
        NavigationStack {
            GroupListContent(kind: .collection, model: model)
                .navigationTitle(Text(verbatim: L10n.string(AppTab.collections.titleKey)))
        }
        .task { await model.loadNextPage()?.value }
        .environment(\.serverID, UUID())
        .absBackground()
    }

    #Preview("Playlists, failed, dark") {
        @Previewable @State var model = GroupsPreviewData.list(.playlist, fails: true)
        NavigationStack {
            GroupListContent(kind: .playlist, model: model)
                .navigationTitle(Text(verbatim: L10n.string(AppTab.playlists.titleKey)))
        }
        .task { await model.loadNextPage()?.value }
        .absBackground()
        .preferredColorScheme(.dark)
    }
#endif

#Preview("Signed out") {
    NavigationStack { GroupListView(kind: .collection) }
        .absBackground()
}
