import ABSAppModel
import ABSCore
import ABSUI
import SwiftUI

/// An item (`Route.item`, legacy `pages/item/_id/index.vue`): the book detail screen, or
/// ``PodcastDetailView`` for podcasts. Episodes have their own screen, ``EpisodeDetailView``.
///
/// The model belongs to one item and account (ADR 0004): it is built from the environment's
/// `libraryStore` (its services and progress cache) and rebuilt when the item ID, the store or
/// the store's account changes. The shell's `.id(identity)` already rebuilds this view on a
/// server or user switch; the key also covers a store that clears underneath it, and the
/// store's services follow a reconnect of the same account. Without a store or a connected
/// account (signed out, or before the shell provides one) the screen says the item is
/// unavailable. The server's address, for the More menu's Share, is read again each time the
/// screen appears, so it follows a reconnect to a new address.
struct ItemDetailView: View {
    let itemID: String
    @Environment(\.libraryStore) private var store
    @State private var host: ItemDetailHost?
    /// The key the store had no client for.
    @State private var unavailableKey: ItemDetailHost.Key?

    private var key: ItemDetailHost.Key? {
        guard let store, let connectionKey = store.connectionKey else { return nil }
        return ItemDetailHost.Key(itemID: itemID, store: ObjectIdentifier(store), connectionKey: connectionKey)
    }

    var body: some View {
        Group {
            if let host, host.key == key {
                ItemDetailScreen(model: host.model, serverURL: host.serverURL, playlists: host.services)
            } else if key == nil || unavailableKey == key {
                ErrorStateView(title: L10n.string("MessageItemDetailUnavailable"), systemImage: "book")
                    .navigationTitle(Text(verbatim: L10n.string("HeaderDetails")))
            } else {
                LoadingView()
            }
        }
        .task(id: key) {
            guard let key, let store else {
                host = nil
                return
            }
            if host?.key != key {
                guard let services = store.makeServices(), services.connectionKey == key.connectionKey else {
                    host = nil
                    unavailableKey = key
                    return
                }
                unavailableKey = nil
                host = ItemDetailHost(
                    key: key, services: services,
                    model: ItemDetailModel(itemID: itemID, service: services, cache: store.progress))
            }
            if let services = host?.services, let url = try? await services.serverURL(), host?.key == key {
                host?.serverURL = url
            }
            // Also retries a first load cancelled when the view disappeared.
            await host?.model.loadIfNeeded()
        }
    }
}

/// The model for one item and account.
private struct ItemDetailHost {
    struct Key: Hashable {
        let itemID: String
        let store: ObjectIdentifier
        let connectionKey: LibraryConnectionKey
    }

    let key: Key
    let services: LibraryStoreServices
    let model: ItemDetailModel
    /// The server's address, for Share; `nil` until read, or when the client can't tell.
    var serverURL: URL?
}

/// The states of one item's screen: loading, failed, not found, a podcast, or the book. Only the
/// book's states get the item's navigation title and the More menu here.
struct ItemDetailScreen: View {
    let model: ItemDetailModel
    /// The server's address, for the More menu's Share; without it there is no Share.
    var serverURL: URL?
    /// The account's playlist writes, for the More menu's Add to playlist; without them there is no Add to playlist.
    var playlists: (any PlaylistEditingService)?

    var body: some View {
        if model.hasLoaded, model.mediaType == .podcast {
            // The podcast screen has its own title.
            PodcastDetailView(model: model)
        } else {
            bookContent
                .navigationTitle(Text(verbatim: model.details?.title ?? L10n.string("HeaderDetails")))
                #if os(iOS)
                    .navigationBarTitleDisplayMode(.inline)
                #endif
                .itemDetailMoreMenu(model: model, serverURL: serverURL, playlists: playlists)
        }
    }

    @ViewBuilder private var bookContent: some View {
        if model.hasLoaded {
            if let details = model.details {
                ItemDetailContent(model: model, details: details)
            } else {
                // A media type this client doesn't know.
                ErrorStateView(
                    title: L10n.string("MessageItemDetailUnsupported"), systemImage: "questionmark.square")
            }
        } else if model.error != nil, !model.isLoading {
            if ItemDetailLoadError.isNotFound(model.error) {
                ErrorStateView(title: L10n.string("MessageItemDetailNotFound"), systemImage: "book.closed") {
                    Task { await model.load() }
                }
            } else {
                ErrorStateView(title: L10n.string("MessageItemDetailLoadFailed")) {
                    Task { await model.load() }
                }
            }
        } else {
            LoadingView()
        }
    }
}

// MARK: - Previews

#Preview("In progress") {
    ItemDetailPreview(item: ItemDetailPreviewData.book, progress: ItemDetailPreviewData.inProgress)
}

#Preview("Finished") {
    ItemDetailPreview(item: ItemDetailPreviewData.book, progress: ItemDetailPreviewData.finished)
}

#Preview("Accessibility text size") {
    ItemDetailPreview(item: ItemDetailPreviewData.book, progress: ItemDetailPreviewData.inProgress)
        .environment(\.dynamicTypeSize, .accessibility3)
}

#Preview("Signed out player") {
    ItemDetailPreview(item: ItemDetailPreviewData.book, canPlay: false)
}

#Preview("Long tags, iPhone SE width", traits: .fixedLayout(width: 320, height: 1_400)) {
    ItemDetailPreview(item: ItemDetailPreviewData.longTags)
}

#Preview("No audio") {
    ItemDetailPreview(item: ItemDetailPreviewData.ebookOnly)
}

#Preview("Missing") {
    ItemDetailPreview(item: SampleLibrary.missing)
}

#Preview("Podcast") {
    ItemDetailPreview(item: SampleLibrary.podcast)
}

#Preview("Loading") {
    ItemDetailPreview(item: ItemDetailPreviewData.book, behavior: .hang)
}

#Preview("Failed") {
    ItemDetailPreview(item: ItemDetailPreviewData.book, behavior: .fail)
}

#Preview("Not found") {
    ItemDetailPreview(item: ItemDetailPreviewData.book, behavior: .notFound)
}

#Preview("More menu with Share") {
    @Previewable @State var model = ItemDetailModel(
        itemID: ItemDetailPreviewData.book.id,
        service: PreviewItemDetailService(item: ItemDetailPreviewData.book, behavior: .succeed),
        cache: {
            let cache = ProgressCache()
            cache.apply(ItemDetailPreviewData.inProgress)
            return cache
        }())
    NavigationStack {
        ItemDetailScreen(model: model, serverURL: URL(string: "https://abs.example.com/audiobookshelf"))
            .task { await model.loadIfNeeded() }
    }
}

#Preview("No library store") {
    NavigationStack { ItemDetailView(itemID: "li_1") }
}
