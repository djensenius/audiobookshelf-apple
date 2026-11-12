import ABSAPI
import ABSAppModel
import ABSCore
import ABSUI
import SwiftUI

/// One author: photo, name, bio (collapsed when long) and their books, paged through the `authors.<id>` filter.
/// Builds one ``AuthorDetailModel`` per store, account and library from `makeServices()`.
struct AuthorDetailView: View {
    let authorID: String
    @Environment(\.libraryStore) private var store
    @Environment(Router.self) private var router: Router?
    @State private var host: BrowseModelHost<AuthorDetailModel>?

    var body: some View {
        let libraryID = router?.libraryID
        let key = BrowseModelKey(store: store, libraryID: libraryID, entityID: authorID)
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
                let model = AuthorsPresentation.makeDetail(authorID: authorID, key: key, services: services)
                store?.observeLibraryChanges(connectionKey: key.connection, owner: model) { [weak model] in
                    model?.apply($0)
                }
                return model
            }
            await host?.model.loadIfNeeded()
        }
    }
}

/// The author screen for one model; previews give it a fixture service.
struct AuthorDetailContent: View {
    let model: AuthorDetailModel
    /// The last user refresh failed and nothing loaded since.
    @State private var refreshFailed = false

    var body: some View {
        let messages = AuthorsPresentation.detailMessages
        BrowseStateView(
            state: AuthorsPresentation.state(of: model), messages: messages,
            retry: { Task { await model.loadIfNeeded() } }
        ) { _ in
            if let detail = model.detail {
                let placement = AuthorsPresentation.failurePlacement(of: model, refreshFailed: refreshFailed)
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: ABSSpacing.large) {
                        if placement == .top {
                            BrowseFailureRow(messageKey: messages.failed, retry: { Task { await refresh() } })
                        }
                        AuthorDetailHeader(detail: detail, booksTotal: model.books.total)
                        AuthorBooksSection(model: model, failed: placement == .footer)
                    }
                    .padding(.vertical, ABSSpacing.large)
                }
            }
        }
        .navigationTitle(Text(verbatim: model.detail?.name ?? L10n.string("LabelAuthor")))
        .refreshable { await refresh() }
        .refreshCommand(.pushed(.author(id: model.authorID)), isDisabled: model.isLoading || model.books.isLoading) {
            Task { await refresh() }
        }
        .onChange(of: model.error == nil && model.books.error == nil) { _, cleared in
            if cleared { refreshFailed = false }
        }
    }

    private func refresh() async {
        refreshFailed = await AuthorsPresentation.refresh(model)
    }
}

/// The photo, name, book count and bio.
private struct AuthorDetailHeader: View {
    let detail: AuthorDetail
    /// The books filter's count, once known.
    let booksTotal: Int?
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
                    if let bookCount = AuthorsPresentation.bookCount(total: booksTotal, author: detail.summary) {
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

/// The author's books: a spinner, "No items found", or the paged grid, with their paging failure when `failed`.
private struct AuthorBooksSection: View {
    let model: AuthorDetailModel
    let failed: Bool

    var body: some View {
        let failedMessage = AuthorsPresentation.booksFailedMessage
        switch BrowseScreenState.resolve(list: model.books) {
        case .loading:
            ProgressView()
                .frame(maxWidth: .infinity)
        case .failed:
            if failed {
                BrowseFailureRow(messageKey: failedMessage, retry: { BrowsePresentation.retry(model.books) })
            }
        case .loaded:
            BrowseItemGrid(
                elements: model.books.items, item: { $0 }, onAppear: { model.books.itemAppeared(id: $0.id) },
                appearanceID: model.booksRefreshes)
            BrowsePagingFooter(
                isLoading: model.books.isLoading, failed: failed, messageKey: failedMessage,
                retry: { BrowsePresentation.retry(model.books) })
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
