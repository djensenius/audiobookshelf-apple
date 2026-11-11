import ABSAPI
import ABSAppModel
import ABSCore
import ABSUI
import SwiftUI

/// One author: photo, name, bio (collapsed when long) and their books in the author's library,
/// paged through the `authors.<id>` filter.
///
/// Builds one ``AuthorDetailModel`` per store, account and library from `makeServices()`; an
/// author of another library than the selected one gets a model for their library.
struct AuthorDetailView: View {
    let authorID: String
    @Environment(\.libraryStore) private var store
    @Environment(Router.self) private var router: Router?
    @State private var host: BrowseModelHost<AuthorDetailModel>?
    /// The key for the author's library once they loaded from another one.
    @State private var authorLibrary: BrowseModelKey?

    var body: some View {
        let libraryID = router?.libraryID
        let key = AuthorsPresentation.key(
            BrowseModelKey(store: store, libraryID: libraryID, entityID: authorID), authorLibrary: authorLibrary)
        Group {
            if let host, let model = host.model(for: key) {
                AuthorDetailContent(model: model)
                    // TODO(#181): drop this once the shell sets `itemProgressReader` from the same store.
                    .environment(\.itemProgressReader, host.progressReader)
            } else {
                BrowsePlaceholder(libraryID: libraryID, messages: AuthorsPresentation.detailMessages)
                    .navigationTitle(Text(verbatim: L10n.string("LabelAuthor")))
            }
        }
        .task(id: key) {
            host = .updated(host, for: key, store: store) { key, services, _ in
                AuthorsPresentation.makeDetail(authorID: authorID, key: key, services: services)
            }
            await host?.model.loadIfNeeded()
            if let host, let next = AuthorsPresentation.authorLibraryKey(after: host) {
                authorLibrary = next
            }
        }
    }
}

/// The author screen for one model; previews give it a fixture service.
struct AuthorDetailContent: View {
    let model: AuthorDetailModel

    var body: some View {
        let messages = AuthorsPresentation.detailMessages
        BrowseStateView(
            state: AuthorsPresentation.state(of: model), messages: messages,
            retry: { Task { await model.loadIfNeeded() } }
        ) { failed in
            if let detail = model.detail {
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: ABSSpacing.large) {
                        if failed {
                            BrowseFailureRow(messageKey: messages.failed, retry: { Task { await model.load() } })
                        }
                        AuthorDetailHeader(detail: detail, bookCount: AuthorsPresentation.bookCount(of: model))
                        AuthorBooksSection(state: AuthorsPresentation.booksState(of: model), books: model.books)
                    }
                    .padding(.vertical, ABSSpacing.large)
                }
            }
        }
        .navigationTitle(Text(verbatim: model.detail?.name ?? L10n.string("LabelAuthor")))
        .refreshable { await model.refresh() }
        .browseRefreshCommand(isDisabled: model.isLoading || model.books.isLoading) {
            Task { await model.refresh() }
        }
    }
}

/// The photo, name, book count and bio.
private struct AuthorDetailHeader: View {
    let detail: AuthorDetail
    let bookCount: String?
    @Environment(\.serverID) private var serverID
    @ScaledMetric(relativeTo: .title2) private var imageWidth: CGFloat = 120

    var body: some View {
        VStack(alignment: .leading, spacing: ABSSpacing.medium) {
            AdaptiveStack(spacing: ABSSpacing.large) {
                // The name is next to it, so VoiceOver skips the photo.
                AuthorImageView(key: serverID.flatMap { detail.summary.imageKey(serverID: $0) }, name: detail.name)
                    .frame(width: imageWidth, height: imageWidth / 0.8)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: ABSSpacing.xSmall) {
                    Text(verbatim: detail.name)
                        .font(.title2.bold())
                        .foregroundStyle(ABSColor.foreground)
                        .accessibilityAddTraits(.isHeader)
                    if let bookCount {
                        Text(verbatim: bookCount)
                            .font(.subheadline)
                            .foregroundStyle(ABSColor.mutedForeground)
                    }
                }
            }
            if let bio = detail.bio {
                ExpandableText(bio, collapsedLineLimit: 4)
            }
        }
        .padding(.horizontal, ABSSpacing.large)
    }
}

/// The author's books: a spinner, a failure with Retry, "No items found", or the paged grid.
private struct AuthorBooksSection: View {
    let state: BrowseScreenState
    let books: ItemListModel<LibraryQuery, ItemSummary>

    var body: some View {
        let failedMessage = AuthorsPresentation.booksFailedMessage
        switch state {
        case .loading:
            ProgressView()
                .frame(maxWidth: .infinity)
        case .failed:
            BrowseFailureRow(messageKey: failedMessage, retry: { BrowsePresentation.retry(books) })
        case .loaded(let failed):
            BrowseItemGrid(elements: books.items, item: { $0 }, onAppear: { books.itemAppeared(id: $0.id) })
            BrowsePagingFooter(
                isLoading: books.isLoading, failed: failed, messageKey: failedMessage,
                retry: { BrowsePresentation.retry(books) })
        case .empty, .notFound, .signedOut:
            Text(verbatim: L10n.string("MessageNoItemsFound"))
                .foregroundStyle(ABSColor.mutedForeground)
                .padding(.horizontal, ABSSpacing.large)
        }
    }
}

#if DEBUG
    #Preview("Author") {
        @Previewable @State var model = SeriesAuthorsPreviewData.authorDetail()
        NavigationStack {
            AuthorDetailContent(model: model)
        }
        .task { await model.loadIfNeeded() }
        .environment(\.serverID, UUID())
        .environment(\.itemProgressReader, SeriesAuthorsPreviewData.progressReader)
        .absBackground()
    }

    #Preview("Author, largest text, dark") {
        @Previewable @State var model = SeriesAuthorsPreviewData.authorDetail()
        NavigationStack {
            AuthorDetailContent(model: model)
        }
        .task { await model.loadIfNeeded() }
        .environment(\.itemProgressReader, SeriesAuthorsPreviewData.progressReader)
        .environment(\.dynamicTypeSize, .accessibility3)
        .absBackground()
        .preferredColorScheme(.dark)
    }

    #Preview("Author, failed") {
        @Previewable @State var model = SeriesAuthorsPreviewData.authorDetail(fails: true)
        NavigationStack {
            AuthorDetailContent(model: model)
        }
        .task { await model.loadIfNeeded() }
        .absBackground()
    }
#endif

#Preview("Author, signed out") {
    NavigationStack { AuthorDetailView(authorID: "aut_burroughs") }
        .absBackground()
}
