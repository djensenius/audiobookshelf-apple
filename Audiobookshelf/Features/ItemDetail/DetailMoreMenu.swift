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
/// entry is the screen's own, from `entry`, and `extra` adds entries after the actions (shown
/// only while there are actions).
///
/// While the shell's connection banner says the server can't be reached (#76), the progress
/// actions stay in the menu, disabled with the reason
/// (``ItemDetailMenuPresentation/entryState(for:availability:isPerforming:)``), and one confirmed
/// meanwhile isn't sent: the reason shows in the failure alert instead.
struct DetailMoreMenu<Model: DetailMoreMenuModel, Entry: View, Extra: View>: ViewModifier {
    let model: Model
    /// The entries to offer, given whether the item is gone from the server.
    let actions: @MainActor (_ isGone: Bool) -> [ItemDetailMenuAction]
    /// The screen's own entry for an action other than a progress action.
    let entry: @MainActor (ItemDetailMenuAction) -> Entry
    /// The screen's entries after the actions, given whether the item is gone from the server.
    let extra: @MainActor (_ isGone: Bool) -> Extra
    @Environment(\.itemActions) private var itemActions
    @Environment(\.connectionBanner) private var connectionBanner
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
        @ViewBuilder entry: @escaping @MainActor (ItemDetailMenuAction) -> Entry,
        @ViewBuilder extra: @escaping @MainActor (_ isGone: Bool) -> Extra
    ) {
        self.model = model
        self.actions = actions
        self.entry = entry
        self.extra = extra
    }

    private var isGone: Bool {
        goneState.isGone(ItemDetailGoneState.Snapshot(model: model.detail))
    }

    private var offered: [ItemDetailMenuAction] {
        actions(isGone)
    }

    /// Which entries the server is needed for while it can't be reached.
    private var availability: ServerActionAvailability {
        ServerActionAvailability(session: connectionBanner)
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
                    let state = ItemDetailMenuPresentation.entryState(
                        for: action, availability: availability, isPerforming: isPerforming)
                    Button(role: ItemDetailMenuPresentation.role(for: action)) {
                        request(action)
                    } label: {
                        DetailMoreMenuLabel(action: action, reasonKey: state.reasonKey)
                    }
                    .detailMoreMenuEntry(state)
                case .addToPlaylist, .share, .details, .history:
                    entry(action)
                }
            }
            extra(isGone)
        } label: {
            Label {
                Text(verbatim: L10n.string("LabelMore"))
            } icon: {
                Image(systemName: "ellipsis.circle")
            }
        }
    }

    /// Asks first when the action needs it, else performs it; explains instead while the server
    /// can't be reached.
    private func request(_ action: ItemDetailMenuAction) {
        if let reasonKey = availability.reasonKey(for: action) {
            failureKey = reasonKey
            showsFailure = true
        } else if model.confirmationMessageKey(for: action) != nil {
            pendingAction = action
            showsConfirmation = true
        } else {
            perform(action)
        }
    }

    /// Performs a progress action that is still offered: a refresh while the confirmation was
    /// open may have finished the book or episode, removed its progress or found it gone, and
    /// the server may have become unreachable, which sends nothing and explains why.
    private func perform(_ action: ItemDetailMenuAction) {
        guard !isPerforming, let summary = model.summary, offered.contains(action) else { return }
        isPerforming = true
        let itemActions = itemActions
        let availability = availability
        Task {
            let key = await ItemDetailMenuPresentation.perform(
                action, on: summary, actions: itemActions, availability: availability)
            isPerforming = false
            if let key {
                failureKey = key
                showsFailure = true
            }
        }
    }
}

extension DetailMoreMenu where Extra == EmptyView {
    init(
        model: Model, actions: @escaping @MainActor (_ isGone: Bool) -> [ItemDetailMenuAction],
        @ViewBuilder entry: @escaping @MainActor (ItemDetailMenuAction) -> Entry
    ) {
        self.init(model: model, actions: actions, entry: entry) { _ in EmptyView() }
    }
}

/// A More menu entry's title and icon (``ItemDetailMenuPresentation``), with why it's
/// unavailable, if it is, as a subtitle that VoiceOver reads with the title.
struct DetailMoreMenuLabel: View {
    let action: ItemDetailMenuAction
    var reasonKey: String?

    var body: some View {
        Label {
            Text(verbatim: L10n.string(ItemDetailMenuPresentation.titleKey(for: action)))
            if let reasonKey {
                Text(verbatim: L10n.string(reasonKey))
            }
        } icon: {
            Image(systemName: ItemDetailMenuPresentation.systemImage(for: action))
        }
    }
}

extension View {
    /// Applies a More menu entry's ``ItemDetailMenuPresentation/EntryState``: disabled, and on
    /// macOS the reason as its tooltip.
    @ViewBuilder func detailMoreMenuEntry(_ state: ItemDetailMenuPresentation.EntryState) -> some View {
        if let reasonKey = state.reasonKey {
            disabled(state.isDisabled).help(Text(verbatim: L10n.string(reasonKey)))
        } else {
            disabled(state.isDisabled)
        }
    }
}
