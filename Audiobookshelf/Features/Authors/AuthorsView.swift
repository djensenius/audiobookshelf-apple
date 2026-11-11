import ABSAppModel
import ABSCore
import ABSUI
import SwiftUI

/// The Authors section of a book library (legacy `pages/bookshelf/authors.vue`): the router's
/// library's authors with their photos and book counts, in server order.
///
/// Builds one ``AuthorsModel`` per store, account and library from `makeServices()`.
struct AuthorsView: View {
    @Environment(\.libraryStore) private var store
    @Environment(Router.self) private var router: Router?
    @State private var host: BrowseModelHost<AuthorsModel>?

    var body: some View {
        let libraryID = router?.libraryID
        let key = BrowseModelKey(store: store, libraryID: libraryID)
        Group {
            if let model = host?.model(for: key) {
                AuthorsContent(model: model)
            } else {
                BrowsePlaceholder(libraryID: libraryID, messages: AuthorsPresentation.listMessages)
            }
        }
        .navigationTitle(Text(verbatim: L10n.string(AppTab.authors.titleKey)))
        .task(id: key) {
            host = .updated(host, for: key, store: store) { key, services, _ in
                AuthorsModel(libraryID: key.libraryID, service: services)
            }
            await host?.model.loadIfNeeded()
        }
    }
}

/// The authors grid of one model; previews give it a fixture service.
struct AuthorsContent: View {
    let model: AuthorsModel
    @Environment(Router.self) private var router: Router?
    @Environment(\.serverID) private var serverID

    var body: some View {
        let messages = AuthorsPresentation.listMessages
        BrowseStateView(state: AuthorsPresentation.state(of: model), messages: messages, retry: { reload() }) {
            failed in
            ScrollView(.vertical) {
                VStack(spacing: ABSSpacing.large) {
                    if failed {
                        BrowseFailureRow(messageKey: messages.failed, retry: { reload() })
                    }
                    ItemGrid(elements: model.authors) { author in
                        AuthorCard(author: author, serverID: serverID) {
                            BrowsePresentation.open(.author(id: author.id), in: router)
                        }
                    }
                }
                .padding(.vertical, ABSSpacing.large)
            }
        }
        .refreshable { await model.load() }
        .refreshCommand(.root(.authors), isDisabled: model.isLoading) { reload() }
    }

    private func reload() {
        Task { await model.load() }
    }
}

#if DEBUG
    #Preview("Authors") {
        @Previewable @State var model = SeriesAuthorsPreviewData.authors()
        NavigationStack {
            AuthorsContent(model: model)
                .navigationTitle(Text(verbatim: L10n.string(AppTab.authors.titleKey)))
        }
        .task { await model.load() }
        .environment(\.serverID, UUID())
        .absBackground()
    }

    #Preview("Authors, largest text, dark") {
        @Previewable @State var model = SeriesAuthorsPreviewData.authors()
        NavigationStack {
            AuthorsContent(model: model)
                .navigationTitle(Text(verbatim: L10n.string(AppTab.authors.titleKey)))
        }
        .task { await model.load() }
        .environment(\.dynamicTypeSize, .accessibility3)
        .absBackground()
        .preferredColorScheme(.dark)
    }

    #Preview("Authors, failed") {
        @Previewable @State var model = SeriesAuthorsPreviewData.authors(fails: true)
        NavigationStack {
            AuthorsContent(model: model)
                .navigationTitle(Text(verbatim: L10n.string(AppTab.authors.titleKey)))
        }
        .task { await model.load() }
        .absBackground()
    }
#endif

#Preview("Authors, signed out") {
    NavigationStack { AuthorsView() }
        .absBackground()
}
