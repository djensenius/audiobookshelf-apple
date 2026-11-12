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
/// ``ItemDetailMenuPresentation/actions(for:isGone:canEditPlaylists:canShare:canRoute:)`` offers,
/// through ``DetailMoreMenu``, which also runs the progress actions with their confirmations and
/// failure alert and remembers a 404. Share links to the web client, so it needs the server's
/// address; History pushes its route on the scene's ``Router`` (ADR 0004), so it is hidden
/// without one (previews); Add to playlist stays hidden until the playlist editor exists.
///
/// The ebook entries (``ItemDetailEbookEntries``) follow, gated by ``EbookActionsModel`` on the
/// signed-in account's authorization; they're hidden offline and without an account (previews).
/// A send's result shows in an alert, a failure's with the server's text; every result is
/// announced to VoiceOver, and a status change reloads the item.
private struct ItemDetailMoreMenu: ViewModifier {
    let model: ItemDetailModel
    let serverURL: URL?
    @Environment(Router.self) private var router: Router?
    @Environment(AccountManager.self) private var accounts: AccountManager?
    @State private var showsDetails = false
    /// For the account's client; replaced if the client changes.
    @State private var ebookActions: EbookActionsModel?
    /// The last ebook action's alert, kept while it's dismissed.
    @State private var ebookFeedback: EbookActionsPresentation.Feedback?
    @State private var showsEbookFeedback = false

    /// The playlist editor doesn't exist yet.
    private static let canEditPlaylists = false

    func body(content: Content) -> some View {
        let canShare = serverURL != nil
        let canRoute = router != nil
        content
            .modifier(
                DetailMoreMenu(model: model) { [model] isGone in
                    ItemDetailMenuPresentation.actions(
                        for: model, isGone: isGone, canEditPlaylists: Self.canEditPlaylists, canShare: canShare,
                        canRoute: canRoute)
                } entry: { action in
                    entry(action)
                } extra: { isGone in
                    ebookEntries(isGone: isGone)
                }
            )
            .sheet(isPresented: $showsDetails) {
                ItemDetailInfoSheet(model: model)
            }
            .task(id: accounts?.client.map(ObjectIdentifier.init)) {
                ebookActions = accounts?.client.map { EbookActionsModel(itemID: model.itemID, service: $0) }
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
    }

    @ViewBuilder private func ebookEntries(isGone: Bool) -> some View {
        if let ebookActions {
            let authorization = accounts?.authorization
            ItemDetailEbookEntries(
                devices: EbookActionsModel.devices(
                    authorization: authorization, ebookFiles: model.ebookFiles, isGone: isGone),
                statusChanges: EbookActionsModel.statusChanges(
                    authorization: authorization, ebookFiles: model.ebookFiles, isGone: isGone),
                isBusy: ebookActions.isBusy,
                send: { deviceName in
                    Task { show(await ebookActions.send(to: deviceName)) }
                },
                apply: { change in
                    Task {
                        let outcome = await ebookActions.apply(change)
                        if case .statusChanged = outcome { await model.load() }
                        show(outcome)
                    }
                })
        }
    }

    private func show(_ outcome: EbookActionsModel.Outcome) {
        guard let feedback = EbookActionsPresentation.feedback(for: outcome) else { return }
        AccessibilityNotification.Announcement(feedback.announcement).post()
        if feedback.alertTitle != nil {
            ebookFeedback = feedback
            showsEbookFeedback = true
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
            // Not offered while `canEditPlaylists` is false.
            EmptyView()
        case .markFinished, .markNotFinished, .discardProgress, .hideFromContinueListening:
            // Shown by ``DetailMoreMenu``.
            EmptyView()
        }
    }
}
