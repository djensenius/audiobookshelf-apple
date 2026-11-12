import ABSAPI
import ABSAppModel
import ABSCore
import ABSUI
import SwiftUI

extension View {
    /// Adds the book screen's More menu ("…") to the toolbar, with its confirmations, failure
    /// alert, details sheet and, with `playlists`, the add-to-playlist sheet.
    func itemDetailMoreMenu(
        model: ItemDetailModel, serverURL: URL?, playlists: (any PlaylistEditingService)? = nil
    ) -> some View {
        modifier(ItemDetailMoreMenu(model: model, serverURL: serverURL, playlists: playlists))
    }
}

/// The book screen's More menu (legacy `ItemMoreMenuModal.vue`): the entries
/// ``ItemDetailMenuPresentation/actions(for:isGone:canEditPlaylists:canShare:canRoute:)`` offers,
/// through ``DetailMoreMenu``, which also runs the progress actions with their confirmations and
/// failure alert and remembers a 404. Share links to the web client, so it needs the server's
/// address; History pushes its route on the scene's ``Router`` (ADR 0004), so it is hidden
/// without one (previews); Add to playlist opens ``AddToPlaylistSheet`` for the book, so it needs the account's
/// playlist writes (`playlists`).
///
/// The ebook entries (``ItemDetailEbookEntries``) follow, gated by ``EbookActionsModel`` on the
/// signed-in account's authorization and the loaded item; they're hidden offline and without an
/// account (previews). The model is made per item model, so a reused view never acts on the
/// previous book, and keeps its state when a reconnect replaces the client. A send is announced
/// as it starts; its result shows in an alert, as a failure does (with the server's explanation
/// when it's worth showing); a status change, which is checked against the item as it is when
/// tapped, reloads the item and is announced.
private struct ItemDetailMoreMenu: ViewModifier {
    let model: ItemDetailModel
    let serverURL: URL?
    let playlists: (any PlaylistEditingService)?
    @Environment(Router.self) private var router: Router?
    @Environment(AccountManager.self) private var accounts: AccountManager?
    @State private var showsDetails = false
    /// For the item model; given the account's new client when it changes.
    @State private var ebookActions: EbookActionsModel?
    /// The last ebook action's alert, kept while it's dismissed.
    @State private var ebookFeedback: EbookActionsPresentation.Feedback?
    @State private var showsEbookFeedback = false
    /// Ended when the menu disappears or shows another item model or account, so a late result
    /// isn't shown there.
    @State private var feedbackLifetime = EbookFeedbackLifetime()
    @State private var addToPlaylist: AddToPlaylistModel?

    /// What the ebook actions are made for.
    private struct EbookActionsKey: Hashable {
        let client: ObjectIdentifier?
        let model: ObjectIdentifier
    }

    func body(content: Content) -> some View {
        let canShare = serverURL != nil
        let canRoute = router != nil
        // Read once, so the menu depends on it explicitly and its closures capture this one. Hidden
        // without a client, while the model is kept for the next one.
        let ebookActions = ebookActions.flatMap { $0.itemID == model.itemID && accounts?.client != nil ? $0 : nil }
        let canEditPlaylists = playlists != nil
        content
            .modifier(
                DetailMoreMenu(model: model) { [model] isGone in
                    ItemDetailMenuPresentation.actions(
                        for: model, isGone: isGone, canEditPlaylists: canEditPlaylists, canShare: canShare,
                        canRoute: canRoute)
                } entry: { action in
                    entry(action)
                } extra: { isGone in
                    if let ebookActions {
                        ebookEntries(ebookActions, isGone: isGone)
                    }
                }
            )
            .sheet(isPresented: $showsDetails) {
                ItemDetailInfoSheet(model: model)
            }
            .task(
                id: EbookActionsKey(client: accounts?.client.map(ObjectIdentifier.init), model: ObjectIdentifier(model))
            ) {
                guard let client = accounts?.client else { return }
                // Same item model, new client (a reconnect): keep the busy and needs-reload state,
                // so the reconnect never re-offers a stale change or overlaps an action in flight.
                // An account switch recreates the whole screen (ADR 0004).
                if let ebookActions = self.ebookActions, ebookActions.itemID == model.itemID {
                    ebookActions.replaceService(client)
                } else {
                    self.ebookActions = EbookActionsModel(itemID: model.itemID, service: client)
                }
            }
            .onChange(of: ObjectIdentifier(model)) { feedbackLifetime.end() }
            .onChange(of: accounts?.activeConnection?.id) { feedbackLifetime.end() }
            .onDisappear { feedbackLifetime.end() }
            .onChange(of: model.loadedRevision) {
                // Only a load that installed an item makes the files current after a failed
                // reload; a cancelled or superseded one leaves them as they were.
                ebookActions?.itemDidLoad()
            }
            .alert(
                Text(verbatim: ebookFeedback?.alertTitle ?? ""), isPresented: $showsEbookFeedback,
                presenting: ebookFeedback
            ) { _ in
                Button(L10n.string("ButtonOk")) {}
            } message: { feedback in
                if let message = feedback.alertMessage {
                    Text(verbatim: message)
                }
            }
            .addToPlaylistSheet($addToPlaylist)
    }

    private func ebookEntries(_ ebookActions: EbookActionsModel, isGone: Bool) -> some View {
        let authorization = accounts?.authorization
        return ItemDetailEbookEntries(
            devices: ebookActions.offeredDevices(authorization: authorization, item: model.item, isGone: isGone),
            statusChanges: ebookActions.offeredStatusChanges(
                authorization: authorization, item: model.item, isGone: isGone),
            isBusy: ebookActions.isBusy,
            send: { deviceName in
                // What would be offered now: the account or item may have changed since the menu
                // opened.
                let offered = ebookActions.offeredDevices(
                    authorization: accounts?.authorization, item: model.item,
                    isGone: isGone || (model.error as? APIError) == .notFound)
                guard ebookActions.canSend(to: deviceName, offered: offered) else { return }
                AccessibilityNotification.Announcement(
                    EbookActionsPresentation.sendingAnnouncement(deviceName: deviceName)
                ).post()
                let lifetime = feedbackLifetime
                let ticket = lifetime.ticket(accountID: accounts?.activeConnection?.id)
                Task {
                    show(await ebookActions.send(to: deviceName, offered: offered), lifetime: lifetime, ticket: ticket)
                }
            },
            apply: { change in
                let lifetime = feedbackLifetime
                let ticket = lifetime.ticket(accountID: accounts?.activeConnection?.id)
                Task {
                    // What would be offered now: the item may have changed since the menu opened.
                    let offered = ebookActions.offeredStatusChanges(
                        authorization: accounts?.authorization, item: model.item,
                        isGone: isGone || (model.error as? APIError) == .notFound)
                    let outcome = await ebookActions.apply(change, offered: offered) {
                        // Not `error == nil`: a cancelled or superseded reload leaves it nil and
                        // the old files in place.
                        await model.reload() ? model.item : nil
                    }
                    show(outcome, lifetime: lifetime, ticket: ticket)
                }
            })
    }

    /// Shows an alert, which VoiceOver reads, or else announces the outcome; nothing if the menu
    /// that started the action is gone or shows another item model or account.
    private func show(
        _ outcome: EbookActionsModel.Outcome, lifetime: EbookFeedbackLifetime, ticket: EbookFeedbackLifetime.Ticket
    ) {
        guard lifetime.accepts(ticket, accountID: accounts?.activeConnection?.id),
            let feedback = EbookActionsPresentation.feedback(for: outcome)
        else { return }
        if feedback.alertTitle != nil {
            ebookFeedback = feedback
            showsEbookFeedback = true
        } else {
            AccessibilityNotification.Announcement(feedback.announcement).post()
        }
    }

    /// The book's own entries; ``DetailMoreMenu`` shows the progress actions.
    @ViewBuilder private func entry(_ action: ItemDetailMenuAction) -> some View {
        switch action {
        case .share:
            if let serverURL {
                ShareLink(item: ItemDetailModel.webURL(serverURL: serverURL, itemID: model.itemID)) {
                    DetailMoreMenuLabel(action: action)
                }
            }
        case .details:
            Button {
                showsDetails = true
            } label: {
                DetailMoreMenuLabel(action: action)
            }
        case .history:
            // A button rather than a `NavigationLink` in the menu, which doesn't push everywhere.
            Button {
                BrowsePresentation.open(.history(itemID: model.itemID), in: router)
            } label: {
                DetailMoreMenuLabel(action: action)
            }
        case .addToPlaylist:
            Button {
                guard let playlists, let libraryID = model.item?.libraryId else { return }
                addToPlaylist = AddToPlaylistModel(
                    entries: [PlaylistEntryKey(itemID: model.itemID)], libraryID: libraryID, service: playlists)
            } label: {
                DetailMoreMenuLabel(action: action)
            }
        case .markFinished, .markNotFinished, .discardProgress, .hideFromContinueListening:
            // Shown by ``DetailMoreMenu``.
            EmptyView()
        }
    }
}
