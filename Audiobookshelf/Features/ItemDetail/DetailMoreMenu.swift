import ABSAppModel
import ABSCore
import ABSUI
import SwiftUI

/// What a detail screen's More menu needs from its model: the loaded item, for the gone (404)
/// tracking; the item or episode its progress actions apply to; and which actions ask first.
@MainActor
protocol DetailMoreMenuModel {
    /// The item the screen loads; its loads drive ``ItemDetailGoneState``.
    var detail: ItemDetailModel { get }
    /// What the progress actions apply to; `nil` until loaded.
    var summary: ItemSummary? { get }
    /// The message to confirm `action` with, or `nil` to perform it at once.
    func confirmationMessageKey(for action: ItemDetailMenuAction) -> String?
}

extension ItemDetailModel: DetailMoreMenuModel {
    var detail: ItemDetailModel { self }
}

extension EpisodeDetailModel: DetailMoreMenuModel {}

/// The More menu ("…") shared by the book and episode screens: the toolbar menu, its progress
/// actions with their confirmation and failure alerts, and the gone-state tracking.
///
/// A 404 is remembered (``ItemDetailGoneState``) until the item loads again, and `actions` is
/// asked with it. Progress actions (mark finished or not finished, discard progress, hide from
/// Continue Listening) go through the environment's `itemActions`, which update the progress
/// cache at once and roll back on failure; a failure shows an alert. Marking finished over
/// progress and discarding ask first, in a centred alert as legacy `Dialog.confirm` did. One
/// progress action runs at a time, and one is performed only while still offered. Every other
/// entry is the screen's own, from `entry`.
struct DetailMoreMenu<Model: DetailMoreMenuModel, Entry: View>: ViewModifier {
    let model: Model
    /// The entries to offer, given whether the item is gone from the server.
    let actions: @MainActor (_ isGone: Bool) -> [ItemDetailMenuAction]
    /// The screen's own entry for an action other than a progress action.
    let entry: @MainActor (ItemDetailMenuAction) -> Entry
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

    init(
        model: Model, actions: @escaping @MainActor (_ isGone: Bool) -> [ItemDetailMenuAction],
        @ViewBuilder entry: @escaping @MainActor (ItemDetailMenuAction) -> Entry
    ) {
        self.model = model
        self.actions = actions
        self.entry = entry
    }

    private var offered: [ItemDetailMenuAction] {
        actions(goneState.isGone(ItemDetailGoneState.Snapshot(model: model.detail)))
    }

    func body(content: Content) -> some View {
        let offered = offered
        content
            .onChange(of: ItemDetailGoneState.Snapshot(model: model.detail), initial: true) { _, snapshot in
                goneState.update(snapshot)
            }
            .toolbar {
                if !offered.isEmpty {
                    ToolbarItem(placement: .primaryAction) {
                        menu(offered)
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
                switch action {
                case .markFinished, .markNotFinished, .discardProgress, .hideFromContinueListening:
                    Button(role: ItemDetailMenuPresentation.role(for: action)) {
                        request(action)
                    } label: {
                        DetailMoreMenuLabel(action: action)
                    }
                    .disabled(isPerforming)
                case .addToPlaylist, .share, .details, .history:
                    entry(action)
                }
            }
        } label: {
            Label {
                Text(verbatim: L10n.string("LabelMore"))
            } icon: {
                Image(systemName: "ellipsis.circle")
            }
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
    /// open may have finished the book or episode, removed its progress or found it gone.
    private func perform(_ action: ItemDetailMenuAction) {
        guard !isPerforming, let summary = model.summary, offered.contains(action) else { return }
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

/// A More menu entry's title and icon (``ItemDetailMenuPresentation``).
struct DetailMoreMenuLabel: View {
    let action: ItemDetailMenuAction

    var body: some View {
        Label {
            Text(verbatim: L10n.string(ItemDetailMenuPresentation.titleKey(for: action)))
        } icon: {
            Image(systemName: ItemDetailMenuPresentation.systemImage(for: action))
        }
    }
}
