import ABSAPI
import ABSAppModel
import ABSCore
import ABSUI
import SwiftUI

/// The new-podcast form (legacy `components/forms/NewPodcastForm.vue`): title, author, genres, description, folder
/// and auto-download, with the path the server will create. Submit creates the podcast, dismisses and calls
/// `onCreated` with its ID. Present it in a `NavigationStack`, for its title and buttons.
struct NewPodcastForm: View {
    @Bindable var draft: NewPodcastDraft
    let onCreated: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.serverID) private var serverID
    /// The genres as typed, comma-separated; the draft gets them split.
    @State private var genresText: String
    /// The last submit's failure, kept while the alert is dismissed.
    @State private var failureMessage: String?
    @State private var showsFailure = false

    init(draft: NewPodcastDraft, onCreated: @escaping (String) -> Void) {
        self.draft = draft
        self.onCreated = onCreated
        _genresText = State(initialValue: draft.genres.joined(separator: ", "))
    }

    var body: some View {
        let issues = draft.issues
        Form {
            Section {
                HStack(alignment: .top, spacing: ABSSpacing.medium) {
                    CoverView(
                        key: AddPodcastPresentation.coverKey(url: draft.imageURL, serverID: serverID),
                        title: draft.title, author: draft.author, shape: .square, accessibility: .hidden
                    )
                    .frame(width: 80)
                    VStack(alignment: .leading, spacing: ABSSpacing.xSmall) {
                        Text(verbatim: L10n.string("LabelFeedURL"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(verbatim: draft.feedURL)
                            .font(.footnote)
                            .textSelection(.enabled)
                        Text(
                            verbatim: L10n.plural(
                                "LabelPodcastEpisodeCount", count: draft.feed.numEpisodes ?? draft.feed.episodes.count)
                        )
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    }
                }
            }
            Section {
                TextField(text: $draft.title) { Text(verbatim: L10n.string("LabelTitle")) }
                TextField(text: $draft.author) { Text(verbatim: L10n.string("LabelAuthor")) }
                TextField(text: $genresText) { Text(verbatim: L10n.string("LabelGenres")) }
            } footer: {
                if issues.contains(.titleMissing) {
                    Text(verbatim: L10n.string("MessageNewPodcastTitleRequired"))
                }
            }
            Section {
                TextField(text: $draft.description, axis: .vertical) {
                    Text(verbatim: L10n.string("LabelDescription"))
                }
                .lineLimit(3...10)
            } header: {
                Text(verbatim: L10n.string("LabelDescription"))
            }
            Section {
                Picker(selection: $draft.folderID) {
                    ForEach(draft.folders) { folder in
                        Text(verbatim: folder.fullPath).tag(Optional(folder.id))
                    }
                } label: {
                    Text(verbatim: L10n.string("LabelFolder"))
                }
                LabeledContent {
                    Text(verbatim: draft.path ?? "")
                        .textSelection(.enabled)
                } label: {
                    Text(verbatim: L10n.string("LabelPath"))
                }
            } footer: {
                if issues.contains(.folderMissing) {
                    Text(verbatim: L10n.string("MessageNewPodcastFolderRequired"))
                }
            }
            Section {
                Toggle(isOn: $draft.autoDownloadEpisodes) {
                    Text(verbatim: L10n.string("LabelAutoDownloadEpisodes"))
                }
            }
        }
        .formStyle(.grouped)
        .disabled(draft.isSubmitting)
        .navigationTitle(Text(verbatim: L10n.string("HeaderAddPodcast")))
        #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
        #endif
        .interactiveDismissDisabled(draft.isSubmitting)
        .onChange(of: issues) { old, new in
            for issue in new.subtracting(old) {
                let key = issue == .titleMissing ? "MessageNewPodcastTitleRequired" : "MessageNewPodcastFolderRequired"
                AccessibilityNotification.Announcement(L10n.string(key)).post()
            }
        }
        .onChange(of: genresText) { _, text in
            draft.genres = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(L10n.string("ButtonCancel")) { dismiss() }
                    .disabled(draft.isSubmitting)
            }
            ToolbarItem(placement: .confirmationAction) {
                if draft.isSubmitting {
                    ProgressView()
                        .accessibilityLabel(Text(verbatim: L10n.string("MessageLoading")))
                } else {
                    Button(L10n.string("ButtonSubmit")) { submit() }
                        .disabled(!draft.canSubmit)
                }
            }
        }
        .alert(Text(verbatim: failureMessage ?? ""), isPresented: $showsFailure, presenting: failureMessage) { _ in
            Button(L10n.string("ButtonOk")) {}
        }
    }

    private func submit() {
        Task {
            if let itemID = await draft.submit() {
                dismiss()
                onCreated(itemID)
            } else if draft.submitError != nil {
                failureMessage = draft.submitErrorMessage ?? L10n.string("ToastPodcastCreateFailed")
                showsFailure = true
            }
        }
    }
}

#if DEBUG
    @MainActor
    private func newPodcastPreview(title: String = "Classic Tales", folders: Bool = true) -> some View {
        let feedURL = "https://feeds.example.com/classic-tales.xml"
        let metadata = PodcastFeedMetadata(
            title: title, author: "B. J. Harrison", descriptionPlain: "Classic stories, read aloud.",
            categories: ["Arts", "Books"], feedURL: feedURL)
        let draft = NewPodcastDraft(
            service: AddPodcastPreviewService(), libraryID: SampleLibrary.libraryID,
            folders: folders ? [LibraryFolder(id: "f1", fullPath: "/podcasts")] : [],
            feed: PodcastFeed(metadata: metadata, numEpisodes: 812), feedURL: feedURL)
        return NavigationStack { NewPodcastForm(draft: draft) { _ in } }
    }

    #Preview("New podcast") { newPodcastPreview().environment(\.serverID, UUID()) }
    #Preview("Invalid") { newPodcastPreview(title: "", folders: false) }
    #Preview("Submit fails, dark, largest text") {
        newPodcastPreview(title: "Fail: Already Added").environment(\.dynamicTypeSize, .accessibility5)
            .preferredColorScheme(.dark)
    }
#endif
