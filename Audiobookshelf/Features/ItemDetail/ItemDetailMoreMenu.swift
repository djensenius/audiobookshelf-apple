import ABSAppModel
import ABSCore
import ABSUI
import SwiftUI

extension View {
    /// Adds the book screen's More menu ("…") to the toolbar, with its confirmations, failure
    /// alert and details sheet.
    func itemDetailMoreMenu(model: ItemDetailModel, serverURL: URL?) -> some View {
        modifier(ItemDetailMoreMenu(model: model, serverURL: serverURL))
    }
}

/// The book screen's More menu (legacy `ItemMoreMenuModal.vue`): the entries
/// ``ItemDetailMenuPresentation/actions(for:isGone:canEditPlaylists:canShare:canRoute:)`` offers;
/// a 404 is remembered (``ItemDetailGoneState``) until the item loads again. Progress actions go through
/// the environment's `itemActions`, which update the progress cache at once and roll back on
/// failure; a failure shows an alert. Marking finished over progress and discarding ask first, in
/// a centred alert as legacy `Dialog.confirm` did. Share links to the web client, so it needs
/// the server's address; History pushes its route on the scene's ``Router`` (ADR 0004), so it is
/// hidden without one (previews); Add to playlist stays hidden until the playlist editor exists.
private struct ItemDetailMoreMenu: ViewModifier {
    let model: ItemDetailModel
    let serverURL: URL?
    @Environment(\.itemActions) private var itemActions
    @Environment(Router.self) private var router: Router?
    /// The action waiting for confirmation, kept while the alert is dismissed.
    @State private var pendingAction: ItemDetailMenuAction?
    @State private var showsConfirmation = false
    /// A progress action is in flight, so no other starts meanwhile.
    @State private var isPerforming = false
    /// The key of the message for the last failed action, kept while the alert is dismissed.
    @State private var failureKey: String?
    @State private var showsFailure = false
    @State private var showsDetails = false
    @State private var goneState = ItemDetailGoneState()

    /// The playlist editor doesn't exist yet.
    private static let canEditPlaylists = false

    private var actions: [ItemDetailMenuAction] {
        ItemDetailMenuPresentation.actions(
            for: model, isGone: goneState.isGone(ItemDetailGoneState.Snapshot(model: model)),
            canEditPlaylists: Self.canEditPlaylists, canShare: serverURL != nil, canRoute: router != nil)
    }

    func body(content: Content) -> some View {
        let actions = actions
        content
            .onChange(of: ItemDetailGoneState.Snapshot(model: model), initial: true) { _, snapshot in
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
            .sheet(isPresented: $showsDetails) {
                ItemDetailInfoSheet(model: model)
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
                ShareLink(item: ItemDetailModel.webURL(serverURL: serverURL, itemID: model.itemID)) {
                    label(action)
                }
            }
        case .details:
            Button {
                showsDetails = true
            } label: {
                label(action)
            }
        case .history:
            // A button rather than a `NavigationLink` in the menu, which doesn't push everywhere.
            Button {
                BrowsePresentation.open(.history(itemID: model.itemID), in: router)
            } label: {
                label(action)
            }
        case .addToPlaylist:
            // Not offered while `canEditPlaylists` is false.
            EmptyView()
        case .markFinished, .markNotFinished, .discardProgress, .hideFromContinueListening:
            Button(role: ItemDetailMenuPresentation.role(for: action)) {
                request(action)
            } label: {
                label(action)
            }
            .disabled(isPerforming)
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
    /// open may have finished the book, removed its progress or found it gone.
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
