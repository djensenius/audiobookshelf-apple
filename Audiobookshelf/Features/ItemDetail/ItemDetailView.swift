import ABSAppModel
import ABSCore
import ABSUI
import SwiftUI

/// An item (`Route.item`, legacy `pages/item/_id/index.vue`): the book detail screen, or
/// ``PodcastDetailView`` for podcasts. Episodes have their own screen, ``EpisodeDetailView``.
///
/// The model belongs to one item and account (ADR 0004): it is built from the environment's
/// `libraryStore` (its client and progress cache) and rebuilt when the item ID or the store's
/// account changes. The shell's `.id(identity)` already rebuilds this view on a server or user
/// switch; the key also covers a store that clears or reconnects underneath it. Without a store
/// (signed out, or before the shell provides one) the screen says the item is unavailable.
struct ItemDetailView: View {
    let itemID: String
    @Environment(\.libraryStore) private var store
    @State private var host: ItemDetailHost?

    private var key: ItemDetailHost.Key? {
        store?.connectionKey.map { ItemDetailHost.Key(itemID: itemID, connectionKey: $0) }
    }

    /// The store's client, which is the account's `APIClient` and so serves items too.
    private var service: (any ItemDetailService)? {
        store?.client as? any ItemDetailService
    }

    var body: some View {
        Group {
            if let host, host.key == key {
                ItemDetailScreen(model: host.model)
            } else if key == nil || service == nil {
                ErrorStateView(title: L10n.string("MessageItemDetailUnavailable"), systemImage: "book")
                    .navigationTitle(Text(verbatim: L10n.string("HeaderDetails")))
            } else {
                LoadingView()
            }
        }
        .task(id: key) {
            guard let key, let store, let service else {
                host = nil
                return
            }
            if host?.key != key {
                host = ItemDetailHost(
                    key: key, model: ItemDetailModel(itemID: itemID, service: service, cache: store.progress))
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
        let connectionKey: LibraryConnectionKey
    }

    let key: Key
    let model: ItemDetailModel
}

/// The states of one item's screen: loading, failed, not found, a podcast, or the book.
struct ItemDetailScreen: View {
    let model: ItemDetailModel

    var body: some View {
        content
            .navigationTitle(Text(verbatim: model.details?.title ?? L10n.string("HeaderDetails")))
            #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
            #endif
    }

    @ViewBuilder private var content: some View {
        if model.hasLoaded {
            if model.mediaType == .podcast {
                PodcastDetailView(itemID: model.itemID)
            } else if let details = model.details {
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

#Preview("Signed out player") {
    ItemDetailPreview(item: ItemDetailPreviewData.book, canPlay: false)
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

#Preview("No library store") {
    NavigationStack { ItemDetailView(itemID: "li_1") }
}
