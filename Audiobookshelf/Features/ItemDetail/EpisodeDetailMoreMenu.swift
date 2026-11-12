import ABSAppModel
import ABSCore
import ABSUI
import SwiftUI

extension View {
    /// Adds the episode screen's More menu ("…") to the toolbar, with its confirmation and
    /// failure alerts.
    func episodeDetailMoreMenu(model: EpisodeDetailModel, serverURL: URL?) -> some View {
        modifier(EpisodeDetailMoreMenu(model: model, serverURL: serverURL))
    }
}

/// The episode screen's More menu (legacy `moreMenuItems`): Mark as finished or not finished,
/// Discard progress and Share, as ``EpisodeDetailModel/menuActions(canEditPlaylists:canShare:isGone:)``
/// offers them, with the book screen's titles, confirmations and failure messages
/// (``ItemDetailMenuPresentation``). Progress actions go through the environment's `itemActions`
/// for the episode. Share links to the podcast in the web client, so it needs the server's
/// address. Add to playlist stays hidden until the playlist editor exists.
private struct EpisodeDetailMoreMenu: ViewModifier {
    let model: EpisodeDetailModel
    let serverURL: URL?
    @Environment(\.itemActions) private var itemActions
    /// The action waiting for confirmation, kept while the alert is dismissed.
    @State private var pendingAction: ItemDetailMenuAction?
    @State private var showsConfirmation = false
    /// A progress action is in flight, so no other starts meanwhile.
    @State private var isPerforming = false
    /// The key of the message for the last failed action, kept while the alert is dismissed.
    @State private var failureKey: String?
    @State private var showsFailure = false
    @State private var goneState = ItemDetailGoneState()

    /// The playlist editor doesn't exist yet.
    private static let canEditPlaylists = false

    private var actions: [ItemDetailMenuAction] {
        model.menuActions(
            canEditPlaylists: Self.canEditPlaylists, canShare: serverURL != nil,
            isGone: goneState.isGone(ItemDetailGoneState.Snapshot(model: model.detail)))
    }

    func body(content: Content) -> some View {
        let actions = actions
        content
            .onChange(of: ItemDetailGoneState.Snapshot(model: model.detail), initial: true) { _, snapshot in
                goneState.update(snapshot)
            }
            .toolbar {
                if !actions.isEmpty {
                    ToolbarItem(placement: .primaryAction) {
                        menu(actions)
                    }
                }
            }
            .alert(
                Text(verbatim: L10n.string("HeaderConfirm")), isPresented: $showsConfirmation,
                presenting: pendingAction
            ) { action in
                Button(role: ItemDetailMenuPresentation.role(for: action)) {
                    perform(action)
                } label: {
                    Text(verbatim: L10n.string(ItemDetailMenuPresentation.titleKey(for: action)))
                }
                Button(role: .cancel) {
                } label: {
                    Text(verbatim: L10n.string("ButtonCancel"))
                }
            } message: { action in
                Text(verbatim: model.confirmationMessageKey(for: action).map { L10n.string($0) } ?? "")
            }
            .alert(
                Text(verbatim: failureKey.map { L10n.string($0) } ?? ""), isPresented: $showsFailure,
                presenting: failureKey
            ) { _ in
                Button(L10n.string("ButtonOk")) {}
            }
    }

    private func menu(_ actions: [ItemDetailMenuAction]) -> some View {
        Menu {
            ForEach(actions, id: \.self) { action in
                entry(action)
            }
        } label: {
            Label {
                Text(verbatim: L10n.string("LabelMore"))
            } icon: {
                Image(systemName: "ellipsis.circle")
            }
        }
    }

    @ViewBuilder private func entry(_ action: ItemDetailMenuAction) -> some View {
        switch action {
        case .share:
            if let serverURL {
                ShareLink(item: EpisodeDetailPresentation.shareURL(serverURL: serverURL, itemID: model.itemID)) {
                    label(action)
                }
            }
        case .markFinished, .markNotFinished, .discardProgress:
            Button(role: ItemDetailMenuPresentation.role(for: action)) {
                request(action)
            } label: {
                label(action)
            }
            .disabled(isPerforming)
        case .addToPlaylist:
            // Not offered while `canEditPlaylists` is false (#93).
            EmptyView()
        case .hideFromContinueListening, .details, .history:
            // Not offered for episodes.
            EmptyView()
        }
    }

    private func label(_ action: ItemDetailMenuAction) -> some View {
        Label {
            Text(verbatim: L10n.string(ItemDetailMenuPresentation.titleKey(for: action)))
        } icon: {
            Image(systemName: ItemDetailMenuPresentation.systemImage(for: action))
        }
    }

    /// Asks first when the action needs it, else performs it.
    private func request(_ action: ItemDetailMenuAction) {
        if model.confirmationMessageKey(for: action) != nil {
            pendingAction = action
            showsConfirmation = true
        } else {
            perform(action)
        }
    }

    /// Performs a progress action that is still offered: a refresh while the confirmation was
    /// open may have finished the episode, removed it or found the podcast gone.
    private func perform(_ action: ItemDetailMenuAction) {
        guard !isPerforming, let summary = model.summary, actions.contains(action) else { return }
        isPerforming = true
        let itemActions = itemActions
        Task {
            let key = await ItemDetailMenuPresentation.perform(action, on: summary, actions: itemActions)
            isPerforming = false
            if let key {
                failureKey = key
                showsFailure = true
            }
        }
    }
}
