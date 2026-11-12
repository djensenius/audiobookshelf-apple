import ABSAPI
import ABSAppModel
import ABSCore
import ABSUI
import SwiftUI

extension View {
    /// Adds the podcast screen's episode management (legacy `EpisodesTable.vue` and the episode
    /// page): a toolbar menu with Find Episodes in Feed and Clear Download Queue, and the
    /// confirmation for removing `removing` from the server, as `access` allows them.
    func podcastEpisodeManagement(
        model: PodcastDetailModel, access: PodcastEpisodeManagementAccess, removing: Binding<PodcastEpisode?>
    ) -> some View {
        modifier(PodcastEpisodeManagementMenu(model: model, access: access, removing: removing))
    }
}

/// The podcast screen's server-side episode management, offered as
/// ``PodcastEpisodeManagementAccess`` allows on the signed-in account's user (none offline or
/// without an account, as in previews):
/// - Find Episodes in Feed opens ``PodcastEpisodesFeedSheet`` and reloads the podcast, so
///   episodes the server has downloaded since are marked; queued episodes are announced in an
///   alert, as legacy's toast did. The sheet closes on a reconnect or when access is lost.
/// - Clear Download Queue asks first (legacy `MessageConfirmDeleteEpisodeDownloadQueue`).
/// - Removing an episode, started from its row, asks whether to keep the audio file or delete it
///   too (`?hard=1`; legacy always deleted it), then reloads the podcast.
///
/// One clear or removal runs at a time (``PodcastEpisodeActionsModel``, which also rechecks
/// `access`); the menu and the removal choices are disabled meanwhile. Results and failures show
/// in an alert.
private struct PodcastEpisodeManagementMenu: ViewModifier {
    let model: PodcastDetailModel
    let access: PodcastEpisodeManagementAccess
    @Binding var removing: PodcastEpisode?
    @Environment(AccountManager.self) private var accounts: AccountManager?
    @State private var actions: PodcastEpisodeActionsModel?
    @State private var confirmsClear = false
    /// The last result's message, kept while the alert is dismissed.
    @State private var message: String?
    @State private var showsMessage = false

    func body(content: Content) -> some View {
        let client = accounts?.client
        content
            .toolbar {
                if client != nil, access.canFindEpisodes || access.canClearDownloadQueue {
                    ToolbarItem(placement: .primaryAction) { menu }
                }
            }
            .task(id: client.map(ObjectIdentifier.init)) {
                guard let client else { return }
                // Same screen, new client (a reconnect): keep the busy state.
                if let actions {
                    actions.replaceService(client)
                } else {
                    actions = PodcastEpisodeActionsModel(podcastID: model.itemID, access: access, service: client)
                }
            }
            .onChange(of: access) { actions?.access = access }
            .onChange(of: model.allEpisodes) { actions?.feed?.updateLibraryEpisodes(model.allEpisodes) }
            .sheet(isPresented: feedBinding) {
                if let feed = actions?.feed {
                    PodcastEpisodesFeedSheet(model: feed) { count in
                        show(L10n.string("MessageEpisodesQueuedForDownload", count.formatted()))
                    }
                }
            }
            .confirmationDialog(
                Text(verbatim: L10n.string("HeaderConfirm")), isPresented: clearBinding, titleVisibility: .visible
            ) {
                Button(L10n.string("ButtonPodcastClearDownloadQueue"), role: .destructive) {
                    Task { await clearQueue() }
                }
                Button(L10n.string("ButtonCancel"), role: .cancel) {}
            } message: {
                Text(verbatim: L10n.string("MessageConfirmDeleteEpisodeDownloadQueue"))
            }
            .confirmationDialog(
                Text(verbatim: L10n.string("ButtonRemoveFromServer")), isPresented: removingBinding,
                titleVisibility: .visible, presenting: removing
            ) { episode in
                Button(L10n.string("ButtonRemoveFromServer"), role: .destructive) {
                    Task { await remove(episode, deleteFile: false) }
                }
                .disabled(!(actions?.canRemoveEpisodes ?? false))
                Button(L10n.string("ButtonPodcastRemoveAndDeleteFile"), role: .destructive) {
                    Task { await remove(episode, deleteFile: true) }
                }
                .disabled(!(actions?.canRemoveEpisodes ?? false))
                Button(L10n.string("ButtonCancel"), role: .cancel) {}
            } message: { episode in
                Text(verbatim: L10n.string("MessageConfirmRemoveServerEpisode", episode.title))
            }
            .alert(Text(verbatim: message ?? ""), isPresented: $showsMessage, presenting: message) { _ in
                Button(L10n.string("ButtonOk")) {}
            }
    }

    /// The clear confirmation, closed once clearing isn't allowed (access lost meanwhile).
    private var clearBinding: Binding<Bool> {
        Binding {
            confirmsClear && access.canClearDownloadQueue
        } set: {
            confirmsClear = $0
        }
    }

    private var feedBinding: Binding<Bool> {
        Binding {
            actions?.feed != nil
        } set: { isPresented in
            if !isPresented { actions?.closeFeed() }
        }
    }

    private var removingBinding: Binding<Bool> {
        Binding {
            removing != nil && access.canRemoveEpisodes && actions != nil
        } set: { isPresented in
            if !isPresented { removing = nil }
        }
    }

    private var menu: some View {
        Menu {
            if access.canFindEpisodes {
                Button {
                    openFeed()
                } label: {
                    Label(L10n.string("ButtonPodcastFindEpisodes"), systemImage: "magnifyingglass")
                }
            }
            if access.canClearDownloadQueue {
                Button(role: .destructive) {
                    confirmsClear = true
                } label: {
                    Label(L10n.string("ButtonPodcastClearDownloadQueue"), systemImage: "xmark.circle")
                }
            }
        } label: {
            Label(L10n.string("LabelPodcastEpisodeManagement"), systemImage: "ellipsis.circle")
        }
        .disabled(actions?.isBusy ?? true)
    }

    private func openFeed() {
        guard let podcast = model.podcast,
            actions?.openFeed(podcast: podcast, libraryEpisodes: model.allEpisodes) != nil
        else { return }
        // The episodes may be from before the server downloaded queued ones; the reload marks
        // them through `onChange(of: model.allEpisodes)`.
        Task { await model.detail.load() }
    }

    private func clearQueue() async {
        guard let result = await actions?.clearDownloadQueue() else { return }
        show(L10n.string(result ? "MessagePodcastDownloadQueueCleared" : "MessagePodcastClearQueueFailed"))
    }

    private func remove(_ episode: PodcastEpisode, deleteFile: Bool) async {
        removing = nil
        guard let result = await actions?.removeEpisode(episode.id, deleteFile: deleteFile)
        else { return }
        if result {
            AccessibilityNotification.Announcement(L10n.string("MessagePodcastEpisodeRemoved")).post()
            await model.detail.load()
        } else {
            show(L10n.string("MessagePodcastRemoveEpisodeFailed"))
        }
    }

    private func show(_ text: String) {
        message = text
        showsMessage = true
    }
}
