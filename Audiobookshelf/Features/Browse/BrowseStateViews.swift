import ABSAppModel
import ABSCore
import ABSUI
import SwiftUI

/// The message keys and icon one screen shows for its states.
struct BrowseMessages {
    /// The first load failed.
    let failed: String
    /// Loaded with nothing to show.
    let empty: String
    /// The server answered 404.
    var notFound = "MessageNoItemsFound"
    let systemImage: String
}

/// A screen in one ``BrowseScreenState``: the shared signed-out, loading, error, not-found and empty states, or
/// `loaded` with whether a later load failed. The error, not-found and empty states scroll for pull to refresh.
struct BrowseStateView<Loaded: View>: View {
    let state: BrowseScreenState
    let messages: BrowseMessages
    let retry: () -> Void
    @ViewBuilder let loaded: (_ failed: Bool) -> Loaded

    var body: some View {
        switch state {
        case .signedOut:
            BrowseMessageView(
                title: L10n.string("MessageBookshelfEmpty"),
                message: L10n.string("MessageAudiobookshelfServerNotConnected"), systemImage: "icloud.slash")
        case .loading:
            LoadingView()
        case .failed:
            scrollable(ErrorStateView(title: L10n.string(messages.failed), retry: retry))
        case .notFound:
            scrollable(BrowseMessageView(title: L10n.string(messages.notFound), systemImage: "questionmark.circle"))
        case .empty:
            scrollable(BrowseMessageView(title: L10n.string(messages.empty), systemImage: messages.systemImage))
        case .loaded(let failed):
            loaded(failed)
        }
    }

    /// A full-screen state centred in a vertical scroll view, so `.refreshable` reaches it.
    private func scrollable(_ content: some View) -> some View {
        ScrollView(.vertical) {
            content.containerRelativeFrame([.horizontal, .vertical])
        }
    }
}

/// A screen without its model: signed out, waiting for the account's libraries (Retry and pull
/// to refresh reload them when they failed), or empty when none is selected.
struct BrowsePlaceholder: View {
    let libraryID: String?
    let messages: BrowseMessages
    @Environment(\.libraryStore) private var store

    var body: some View {
        BrowseStateView(
            state: .placeholder(store: store, libraryID: libraryID), messages: messages,
            retry: { Task { await store?.refresh() } }
        ) { _ in
            EmptyView()
        }
        .refreshable { await store?.refresh() }
    }
}

/// A full-screen message without actions; the failed state uses ABSUI's `ErrorStateView` for its Retry.
private struct BrowseMessageView: View {
    let title: String
    var message: String?
    var systemImage = "exclamationmark.triangle"

    var body: some View {
        ContentUnavailableView {
            Label {
                Text(verbatim: title)
            } icon: {
                Image(systemName: systemImage)
                    .accessibilityHidden(true)
            }
        } description: {
            if let message {
                Text(verbatim: message)
            }
        }
    }
}

/// An inline "couldn't load" row with Retry (under the message at accessibility text sizes).
struct BrowseFailureRow: View {
    let messageKey: String
    let retry: () -> Void

    var body: some View {
        AdaptiveStack(spacing: ABSSpacing.medium) {
            Label {
                Text(verbatim: L10n.string(messageKey))
            } icon: {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(ABSColor.mutedForeground)
                    .accessibilityHidden(true)
            }
            .font(.subheadline)
            .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: retry) {
                Text(verbatim: L10n.string("ButtonRetry"))
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(.rect)
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, ABSSpacing.large)
        .accessibilityElement(children: .contain)
    }
}

/// A paged list's footer: a spinner while the next page loads, or a failure row with Retry.
struct BrowsePagingFooter: View {
    let isLoading: Bool
    let failed: Bool
    let messageKey: String
    let retry: () -> Void

    var body: some View {
        if failed {
            BrowseFailureRow(messageKey: messageKey, retry: retry)
        } else if isLoading {
            ProgressView()
                .frame(maxWidth: .infinity)
        }
    }
}

/// Item cards in a grid that open their screen and perform their context-menu actions through
/// ``ItemCardActionsHost``. `badge` puts a label (a sequence) on a card's cover; VoiceOver skips it and reads the
/// series from the card's label (``SeriesPresentation/card(for:in:)``).
struct BrowseItemGrid<Element: Identifiable>: View {
    let elements: [Element]
    let item: (Element) -> ItemSummary
    var badge: (Element) -> String? = { _ in nil }
    var onAppear: (Element) -> Void = { _ in }
    /// Cards call `onAppear` again when this changes, as cards a refresh kept don't appear again to page on.
    var appearanceID = 0
    @Environment(\.serverID) private var serverID
    private var libraries = LibraryCoverSettings()

    var body: some View {
        ItemCardActionsHost { context, perform in
            ItemGrid(elements: elements) { element in
                let summary = item(element)
                ItemCard(
                    item: summary, serverID: serverID, librarySettings: libraries.current, context: context
                ) { perform($0, summary) }
                .overlay(alignment: .topLeading) {
                    if let badge = badge(element) {
                        Text(verbatim: badge)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, ABSSpacing.xSmall)
                            .background(.black.opacity(0.7), in: .rect(cornerRadius: ABSRadius.small))
                            .padding(ABSSpacing.xSmall)
                            .accessibilityHidden(true)
                    }
                }
                .task(id: appearanceID) { onAppear(element) }
            }
        }
    }
}

/// Item cards or rows that open their screen and perform their context-menu actions through the environment
/// (``ItemCardActions``), with an alert when an action fails. `content` gets the actions to offer and the handler.
struct ItemCardActionsHost<Content: View>: View {
    @ViewBuilder let content:
        (_ context: ItemActionContext, _ perform: @escaping (ItemActionKind, ItemSummary) -> Void) -> Content
    @Environment(Router.self) private var router: Router?
    @Environment(\.itemActions) private var itemActions
    @Environment(\.playItem) private var playItem
    @Environment(\.openWindow) private var openWindow
    @Environment(\.supportsMultipleWindows) private var supportsMultipleWindows
    @Environment(\.addToPlaylist) private var addToPlaylist
    /// The key of the message for the last failed action, kept while the alert is dismissed.
    @State private var failureKey: String?
    @State private var showsFailure = false

    var body: some View {
        content(context) { perform($0, on: $1) }
            .alert(
                Text(verbatim: failureKey.map { L10n.string($0) } ?? ""), isPresented: $showsFailure,
                presenting: failureKey
            ) { _ in
                Button(L10n.string("ButtonOk")) {}
            }
    }

    private var context: ItemActionContext {
        ItemCardActions.actionContext(
            canPlay: playItem != nil, canOpenInNewWindow: supportsMultipleWindows,
            canEditPlaylists: addToPlaylist != nil)
    }

    private func perform(_ kind: ItemActionKind, on item: ItemSummary) {
        guard kind != .openDetails else {
            BrowsePresentation.open(ItemCardActions.route(for: item), in: router)
            return
        }
        guard kind != .openInNewWindow else {
            OpenInNewWindow.open(ItemCardActions.route(for: item), from: router, with: openWindow)
            return
        }
        guard kind != .addToPlaylist else {
            addToPlaylist?(item)
            return
        }
        let actions = itemActions
        let play = playItem
        Task {
            if let key = await ItemCardActions.perform(kind, on: item, actions: actions, play: play) {
                failureKey = key
                showsFailure = true
            }
        }
    }
}
