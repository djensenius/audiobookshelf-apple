import ABSAPI
import ABSAppModel
import ABSCore
import ABSUI
import SwiftUI

/// What the RSS feed sheet and its toolbar entry show, kept apart from the views for tests.
enum RssFeedPresentation {
    /// The message for a failure, and the server's own reason when it gave one (legacy shows it as is).
    static func message(for error: RssFeedModelError) -> (key: String, detail: String?) {
        switch error {
        case .slugRequired: ("MessageRSSFeedSlugRequired", nil)
        case .slugChanged: ("MessageRSSFeedSlugChanged", nil)
        case .invalidOwnerEmail: ("MessageRSSFeedInvalidOwnerEmail", nil)
        case .loadFailed: ("MessageRSSFeedLoadFailed", nil)
        case .openFailed(let message): ("MessageRSSFeedOpenFailed", message)
        case .closeFailed: ("ToastRSSFeedCloseFailed", nil)
        }
    }

    /// The feed a group screen can open: collections only, as the server has no playlist route.
    static func target(_ kind: GroupSummary.Kind, id: String) -> RssFeedTarget? {
        kind == .collection ? RssFeedTarget(.collection, id: id) : nil
    }

    /// The entry shows for admins and root users with a client; offline there's no user type.
    static func showsEntry(userType: UserType?, hasClient: Bool) -> Bool {
        hasClient && RssFeedModel.canManageFeeds(userType)
    }

    /// What VoiceOver announces for a failure: the message, then the server's reason.
    static func announcement(for error: RssFeedModelError, locale: Locale? = nil) -> String {
        let message = message(for: error)
        return [L10n.string(message.key, locale: locale), message.detail].compactMap { $0 }.joined(separator: " ")
    }

    /// Legacy's Yes or No for prevent indexing. The server blocks indexing (`itunes:block`) only when the
    /// flag is set, so a missing flag reads No.
    static func preventIndexingKey(_ feed: RssFeed) -> String {
        feed.meta?.preventIndexing == true ? "ButtonYes" : "LabelNo"
    }

    /// Nothing but progress shows until the current feed is known, so the form never flashes before an
    /// open feed.
    static func isLoading(_ state: RssFeedModel.LoadState) -> Bool {
        state == .idle || state == .loading
    }

    /// What the sheet's form shows.
    enum Content: Equatable {
        case loading
        case retry
        case open(RssFeed)
        case openForm
    }

    /// Progress, then Retry when the lookup failed, before any feed: one carried over from the last
    /// sheet may be stale (replaced elsewhere), so it isn't offered for closing until a lookup succeeds.
    static func content(_ state: RssFeedModel.LoadState, feed: RssFeed?) -> Content {
        if isLoading(state) { return .loading }
        if state == .failed { return .retry }
        return feed.map(Content.open) ?? .openForm
    }

    /// Whether the entry shows a feed as open: the sheet's model once it knows the feed's state
    /// (loaded, opened, closed, a live change, or carried over from the last sheet), else what the
    /// screen fetched (`include=rssfeed`).
    @MainActor
    static func showsOpen(fetched: Bool, model: RssFeedModel?) -> Bool {
        guard let model, model.hasKnownState else { return fetched }
        return model.feed != nil
    }
}

extension View {
    /// Adds RSS Feed (legacy `RssFeedModal.vue`) to the toolbar for admins, opening ``RssFeedSheet`` for
    /// `target`; nothing when `target` is `nil`. `isOpen` is what the screen fetched, until the sheet
    /// has loaded. The sheet closes when the account changes.
    func rssFeedEntry(
        _ target: RssFeedTarget?, isOpen: Bool = false, hasEpisodesWithoutPubDate: Bool = false
    ) -> some View {
        modifier(RssFeedEntry(target: target, isOpen: isOpen, hasEpisodesWithoutPubDate: hasEpisodesWithoutPubDate))
    }

    /// Adds RSS Feed for a book or podcast; nothing when `entry` is `nil`.
    func rssFeedEntry(_ entry: RssFeedItemEntry?) -> some View {
        rssFeedEntry(
            entry?.target, isOpen: entry?.isOpen ?? false,
            hasEpisodesWithoutPubDate: entry?.hasEpisodesWithoutPubDate ?? false)
    }
}

private struct RssFeedEntry: ViewModifier {
    let target: RssFeedTarget?
    let isOpen: Bool
    let hasEpisodesWithoutPubDate: Bool
    @Environment(AccountManager.self) private var accounts: AccountManager?
    @State private var isPresented = false
    /// The last sheet's model, kept after it closes so the entry shows what it last saw.
    @State private var model: RssFeedModel?

    func body(content: Content) -> some View {
        let client = accounts?.client
        let shows = RssFeedPresentation.showsEntry(
            userType: accounts?.authorization?.user.type, hasClient: client != nil)
        let open = RssFeedPresentation.showsOpen(fetched: isOpen, model: model?.target == target ? model : nil)
        content
            .toolbar {
                if let target, let client, shows {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            // A fresh sheet each time, as before, starting from what the last one knew.
                            let fresh = RssFeedModel(
                                target: target, service: client, hasEpisodesWithoutPubDate: hasEpisodesWithoutPubDate)
                            if let model { fresh.seed(from: model) }
                            model = fresh
                            isPresented = true
                        } label: {
                            Label {
                                Text(verbatim: L10n.string("HeaderRSSFeed"))
                            } icon: {
                                // Open shows a different symbol as well as the tint, not colour alone.
                                Image(systemName: open ? "dot.radiowaves.left.and.right" : "dot.radiowaves.up.forward")
                                    .foregroundStyle(open ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                            }
                        }
                        .help(Text(verbatim: L10n.string(open ? "LabelRSSFeedOpen" : "HeaderRSSFeed")))
                        .accessibilityValue(open ? Text(verbatim: L10n.string("LabelRSSFeedOpen")) : Text(verbatim: ""))
                    }
                }
            }
            .sheet(isPresented: $isPresented) {
                if let model {
                    RssFeedSheet(model: model)
                }
            }
            .onChange(of: accounts?.activeConnection?.id) {
                isPresented = false
                model = nil
            }
            .onChange(of: shows) { _, shows in if !shows { isPresented = false } }
    }
}

/// Opens an RSS feed with a slug, prevent indexing and the owner details, or shows the open feed's
/// address to copy or share and closes it (legacy `RssFeedModal.vue` and `RssFeedMetadataBuilder.vue`).
struct RssFeedSheet: View {
    @State private var model: RssFeedModel
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false
    /// The feed that was just closed, shown while the sheet goes away instead of the open form.
    @State private var closedFeed: RssFeed?

    private static let errorID = "rss-feed-error"

    init(model: RssFeedModel) {
        _model = State(initialValue: model)
    }

    var body: some View {
        let feed = model.feed ?? closedFeed
        NavigationStack {
            ScrollViewReader { proxy in
                Form {
                    if let error = model.error {
                        RssFeedErrorSection(error: error)
                            .id(Self.errorID)
                    }
                    switch RssFeedPresentation.content(model.loadState, feed: feed) {
                    case .loading:
                        ProgressView {
                            Text(verbatim: L10n.string("MessageLoading"))
                        }
                        .frame(maxWidth: .infinity)
                    case .retry:
                        Button {
                            Task { await model.load() }
                        } label: {
                            Text(verbatim: L10n.string("ButtonRetry"))
                        }
                    case .open(let feed):
                        openFeed(feed)
                    case .openForm:
                        RssFeedOpenForm(model: model)
                    }
                }
                .formStyle(.grouped)
                .disabled(model.isWorking || closedFeed != nil)
                // A failure, such as a slug that was changed and must be checked, is announced and scrolled
                // to, as the message can be off screen at large text sizes.
                .onChange(of: model.failureCount) {
                    guard let error = model.error else { return }
                    withAnimation { proxy.scrollTo(Self.errorID, anchor: .top) }
                    AccessibilityNotification.Announcement(RssFeedPresentation.announcement(for: error)).post()
                }
            }
            .navigationTitle(Text(verbatim: L10n.string(feed == nil ? "HeaderOpenRSSFeed" : "HeaderRSSFeedIsOpen")))
            #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar { toolbar(feed: feed) }
        }
        .interactiveDismissDisabled(model.isWorking)
        .task { await model.load() }
        .task(id: copied) {
            guard copied else { return }
            try? await Task.sleep(for: .seconds(2))
            copied = false
        }
    }

    @ToolbarContentBuilder
    private func toolbar(feed: RssFeed?) -> some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button {
                dismiss()
            } label: {
                Text(verbatim: L10n.string(feed == nil ? "ButtonCancel" : "ButtonDone"))
            }
            .disabled(model.isWorking)
        }
        if feed == nil, model.loadState == .loaded {
            ToolbarItem(placement: .confirmationAction) {
                if model.isWorking {
                    ProgressView()
                } else {
                    Button {
                        Task { await model.open() }
                    } label: {
                        Text(verbatim: L10n.string("ButtonOpenFeed"))
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func openFeed(_ feed: RssFeed) -> some View {
        Section {
            if let url = model.serverURL.flatMap(feed.url(on:)) {
                Text(verbatim: url.absoluteString)
                    .textSelection(.enabled)
                    .font(.callout.monospaced())
                Button {
                    copy(url)
                } label: {
                    Label {
                        Text(verbatim: L10n.string("ButtonCopyFeedURL"))
                    } icon: {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    }
                }
                ShareLink(item: url) {
                    Label {
                        Text(verbatim: L10n.string("ButtonShare"))
                    } icon: {
                        Image(systemName: "square.and.arrow.up")
                    }
                }
            }
        }
        Section {
            LabeledContent {
                Text(verbatim: L10n.string(RssFeedPresentation.preventIndexingKey(feed)))
            } label: {
                Text(verbatim: L10n.string("LabelRSSFeedPreventIndexing"))
            }
            if let name = feed.meta?.ownerName, !name.isEmpty {
                LabeledContent {
                    Text(verbatim: name)
                } label: {
                    Text(verbatim: L10n.string("LabelRSSFeedCustomOwnerName"))
                }
            }
            if let email = feed.meta?.ownerEmail, !email.isEmpty {
                LabeledContent {
                    Text(verbatim: email)
                } label: {
                    Text(verbatim: L10n.string("LabelRSSFeedCustomOwnerEmail"))
                }
            }
        }
        Section {
            Button(role: .destructive) {
                Task {
                    guard await model.close() else { return }
                    closedFeed = feed
                    AccessibilityNotification.Announcement(L10n.string("ToastRSSFeedCloseSuccess")).post()
                    dismiss()
                }
            } label: {
                Text(verbatim: L10n.string("ButtonCloseFeed"))
            }
        }
    }

    private func copy(_ url: URL) {
        #if os(iOS)
            UIPasteboard.general.string = url.absoluteString
        #else
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(url.absoluteString, forType: .string)
        #endif
        copied = true
        AccessibilityNotification.Announcement(L10n.string("MessageFeedURLCopied")).post()
    }
}

/// The failure, with the server's reason under it when there is one.
private struct RssFeedErrorSection: View {
    let error: RssFeedModelError

    var body: some View {
        let message = RssFeedPresentation.message(for: error)
        Section {
            Label {
                VStack(alignment: .leading, spacing: ABSSpacing.xxSmall) {
                    Text(verbatim: L10n.string(message.key))
                    if let detail = message.detail {
                        Text(verbatim: detail)
                            .font(.footnote)
                            .foregroundStyle(ABSColor.mutedForeground)
                    }
                }
            } icon: {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
            .accessibilityElement(children: .combine)
        }
    }
}

/// The slug with the address it gives, prevent indexing, and the owner details (legacy's Advanced tab).
private struct RssFeedOpenForm: View {
    @Bindable var model: RssFeedModel

    var body: some View {
        Section {
            TextField(text: $model.slug) {
                Text(verbatim: L10n.string("LabelRSSFeedSlug"))
            }
            .autocorrectionDisabled()
            #if os(iOS)
                .textInputAutocapitalization(.never)
            #endif
        } header: {
            Text(verbatim: L10n.string("LabelRSSFeedSlug"))
        } footer: {
            VStack(alignment: .leading, spacing: ABSSpacing.xSmall) {
                if let preview = model.previewURL {
                    Text(verbatim: L10n.string("MessageFeedURLWillBe", preview))
                }
                if model.isInsecureServer {
                    Text(verbatim: L10n.string("NoteRSSFeedPodcastAppsHttps"))
                        .foregroundStyle(.orange)
                }
                if model.hasEpisodesWithoutPubDate {
                    Text(verbatim: L10n.string("NoteRSSFeedPodcastAppsPubDate"))
                        .foregroundStyle(.orange)
                }
            }
        }
        Section {
            Toggle(isOn: $model.preventIndexing) {
                Text(verbatim: L10n.string("LabelRSSFeedPreventIndexing"))
            }
        } footer: {
            Text(verbatim: L10n.string("LabelPreventIndexing"))
        }
        Section {
            TextField(text: $model.ownerName) {
                Text(verbatim: L10n.string("LabelRSSFeedCustomOwnerName"))
            }
            #if os(iOS)
                .textContentType(.name)
            #endif
            TextField(text: $model.ownerEmail) {
                Text(verbatim: L10n.string("LabelRSSFeedCustomOwnerEmail"))
            }
            .autocorrectionDisabled()
            #if os(iOS)
                .textContentType(.emailAddress)
                .keyboardType(.emailAddress)
                .textInputAutocapitalization(.never)
            #endif
        } header: {
            Text(verbatim: L10n.string("HeaderAdvanced"))
        }
    }
}

#if DEBUG
    /// A server with one open series feed; anything else opens.
    private struct PreviewRssFeedService: RssFeedService {
        var server = URL(string: "http://abs.local:13378")!
        var open: RssFeed?

        func serverURL() async -> URL { server }
        func currentFeed(for target: RssFeedTarget) async throws -> RssFeed? { open }
        func openFeed(for target: RssFeedTarget, _ request: RssFeedOpenRequest) async throws -> RssFeed {
            if request.slug == "taken" { throw APIError.http(status: 400, message: "Slug already in use") }
            return RssFeed(
                id: "feed-\(request.slug)", entityType: "series", entityId: target.id, feedUrl: "/feed/\(request.slug)")
        }
        func closeFeed(id: String) async throws {}
    }

    #Preview("New feed, http server") {
        RssFeedSheet(
            model: RssFeedModel(target: RssFeedTarget(.series, id: "series-1"), service: PreviewRssFeedService()))
    }

    #Preview("Open feed, largest text, dark") {
        let feed = RssFeed(
            id: "feed-1", entityType: "collection", entityId: "collection-1", feedUrl: "/feed/my-collection",
            meta: .init(preventIndexing: false, ownerName: "Ada Fixture", ownerEmail: "ada@example.com"))
        RssFeedSheet(
            model: RssFeedModel(
                target: RssFeedTarget(.collection, id: "collection-1"),
                service: PreviewRssFeedService(server: URL(string: "https://abs.example")!, open: feed))
        )
        .dynamicTypeSize(.accessibility5)
        .preferredColorScheme(.dark)
    }
#endif
