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

    /// Legacy shows Yes or No for prevent indexing; a feed without the flag was opened with the default, on.
    static func preventIndexingKey(_ feed: RssFeed) -> String {
        feed.meta?.preventIndexing ?? true ? "ButtonYes" : "LabelNo"
    }

    /// Nothing but progress shows until the current feed is known, so the form never flashes before an
    /// open feed.
    static func isLoading(_ state: RssFeedModel.LoadState) -> Bool {
        state == .idle || state == .loading
    }
}

extension View {
    /// Adds RSS Feed (legacy `RssFeedModal.vue`) to the toolbar for admins, opening ``RssFeedSheet`` for
    /// `target`; nothing when `target` is `nil`. The sheet closes when the account changes.
    func rssFeedEntry(_ target: RssFeedTarget?) -> some View {
        modifier(RssFeedEntry(target: target))
    }
}

private struct RssFeedEntry: ViewModifier {
    let target: RssFeedTarget?
    @Environment(AccountManager.self) private var accounts: AccountManager?
    @State private var isPresented = false

    func body(content: Content) -> some View {
        let client = accounts?.client
        let shows = RssFeedPresentation.showsEntry(
            userType: accounts?.authorization?.user.type, hasClient: client != nil)
        content
            .toolbar {
                if target != nil, shows {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            isPresented = true
                        } label: {
                            Label {
                                Text(verbatim: L10n.string("HeaderRSSFeed"))
                            } icon: {
                                Image(systemName: "dot.radiowaves.up.forward")
                            }
                        }
                        .help(Text(verbatim: L10n.string("HeaderRSSFeed")))
                    }
                }
            }
            .sheet(isPresented: $isPresented) {
                if let target, let client {
                    RssFeedSheet(model: RssFeedModel(target: target, service: client))
                }
            }
            .onChange(of: accounts?.activeConnection?.id) { isPresented = false }
            .onChange(of: shows) { _, shows in if !shows { isPresented = false } }
    }
}

/// Opens an RSS feed with a slug, prevent indexing and the owner details, or shows the open feed's
/// address to copy or share and closes it (legacy `RssFeedModal.vue` and `RssFeedMetadataBuilder.vue`).
struct RssFeedSheet: View {
    @State private var model: RssFeedModel
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false

    init(model: RssFeedModel) {
        _model = State(initialValue: model)
    }

    var body: some View {
        NavigationStack {
            Form {
                if let error = model.error {
                    RssFeedErrorSection(error: error)
                }
                if RssFeedPresentation.isLoading(model.loadState) {
                    ProgressView {
                        Text(verbatim: L10n.string("MessageLoading"))
                    }
                    .frame(maxWidth: .infinity)
                } else if let feed = model.feed {
                    openFeed(feed)
                } else if model.loadState == .failed {
                    Button {
                        Task { await model.load() }
                    } label: {
                        Text(verbatim: L10n.string("ButtonRetry"))
                    }
                } else {
                    RssFeedOpenForm(model: model)
                }
            }
            .formStyle(.grouped)
            .disabled(model.isWorking)
            .navigationTitle(
                Text(verbatim: L10n.string(model.feed == nil ? "HeaderOpenRSSFeed" : "HeaderRSSFeedIsOpen"))
            )
            #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar { toolbar }
        }
        .task { await model.load() }
        .task(id: copied) {
            guard copied else { return }
            try? await Task.sleep(for: .seconds(2))
            copied = false
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button {
                dismiss()
            } label: {
                Text(verbatim: L10n.string(model.feed == nil ? "ButtonCancel" : "ButtonDone"))
            }
        }
        if model.feed == nil, model.loadState == .loaded {
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
            if let url = model.feedURL {
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
