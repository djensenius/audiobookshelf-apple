import ABSAPI
import ABSAppModel
import ABSCore
import ABSUI
import SwiftUI

/// The podcast's feed episodes (legacy `PodcastEpisodesFeedModal.vue`): newest first, those the
/// library has marked and not selectable, the others selectable together with Select All, and a
/// button that queues the selection for download on the server. Shown from the podcast screen's
/// management menu (``PodcastEpisodeManagementMenu``) to admins who may update items.
///
/// When the server accepts the episodes, the sheet closes and `onQueued` gets their number; the
/// podcast screen reloads the item and says so. Other outcomes show in an alert on the sheet.
struct PodcastEpisodesFeedSheet: View {
    @State private var model: PodcastFeedEpisodesModel
    let onQueued: (Int) -> Void
    @State private var alertKey: String?
    @State private var showsAlert = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale

    init(model: PodcastFeedEpisodesModel, onQueued: @escaping (Int) -> Void) {
        _model = State(initialValue: model)
        self.onQueued = onQueued
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(Text(verbatim: L10n.string("HeaderPodcastFeedEpisodes")))
                #if os(iOS)
                    .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar { toolbar }
                .safeAreaInset(edge: .bottom) {
                    if model.phase == .loaded, !model.rows.isEmpty { downloadButton }
                }
        }
        #if os(macOS)
            .frame(minWidth: 420, minHeight: 480)
        #endif
        .task { if model.phase == .idle { await model.load() } }
        .interactiveDismissDisabled(model.isDownloading)
        .alert(
            Text(verbatim: alertKey.map { L10n.string($0) } ?? ""), isPresented: $showsAlert, presenting: alertKey
        ) { _ in
            Button(L10n.string("ButtonOk")) {}
        }
    }

    @ViewBuilder private var content: some View {
        switch model.phase {
        case .idle, .loading:
            LoadingView()
        case .failed:
            ErrorStateView(title: L10n.string("MessagePodcastFeedLoadFailed")) {
                Task { await model.load() }
            }
        case .loaded:
            if model.rows.isEmpty {
                ContentUnavailableView {
                    Label {
                        Text(verbatim: L10n.string("MessagePodcastFeedNoEpisodes"))
                    } icon: {
                        Image(systemName: "dot.radiowaves.up.forward")
                            .accessibilityHidden(true)
                    }
                }
            } else {
                List(model.rows) { row in
                    PodcastFeedEpisodeRow(
                        row: row, isSelected: model.selection.contains(row.id), isDisabled: model.isDownloading
                    ) {
                        model.toggle(row.id)
                    }
                }
            }
        }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button {
                dismiss()
            } label: {
                Text(verbatim: L10n.string("ButtonCancel"))
            }
            .disabled(model.isDownloading)
        }
        if model.phase == .loaded, !model.selectableIDs.isEmpty {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    model.toggleAll()
                } label: {
                    Text(
                        verbatim: L10n.string(
                            model.isAllSelected ? "ButtonPodcastDeselectAll" : "ButtonPodcastSelectAll"))
                }
                .disabled(model.isDownloading)
            }
        }
    }

    private var downloadButton: some View {
        let count = model.selection.count
        return Button {
            Task { await download() }
        } label: {
            HStack(spacing: ABSSpacing.small) {
                if model.isDownloading {
                    ProgressView()
                }
                Text(
                    verbatim: count == 0
                        ? L10n.string("MessagePodcastFeedNoneSelected")
                        : L10n.plural(
                            "ButtonPodcastDownloadEpisodes", count: count, count.formatted(.number.locale(locale)),
                            locale: locale)
                )
            }
            .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.borderedProminent)
        .disabled(!model.canDownload)
        .padding(ABSSpacing.large)
        .background(.bar)
    }

    private func download() async {
        switch await model.download() {
        case .queued(let count):
            onQueued(count)
            dismiss()
        case .tooLarge:
            show("MessagePodcastEpisodesRequestTooLarge")
        case .failed:
            show("MessagePodcastEpisodesDownloadFailed")
        case .ignored:
            break
        }
    }

    private func show(_ key: String) {
        alertKey = key
        showsAlert = true
    }
}

/// One feed episode: a checkbox, or a checkmark when the library has it, then its number, title,
/// subtitle and publish date. The whole row toggles it; VoiceOver reads it as a selected or
/// unselected button.
private struct PodcastFeedEpisodeRow: View {
    let row: PodcastFeedEpisodesModel.Row
    let isSelected: Bool
    let isDisabled: Bool
    let toggle: () -> Void
    @Environment(\.locale) private var locale

    var body: some View {
        let episode = row.episode
        let number = episode.episode.map { L10n.string("LabelPodcastDetailEpisodeNumber", $0, locale: locale) }
        let published = PodcastDetailPresentation.publishedText(episode.publishedAt, locale: locale)
        let inLibrary = row.isInLibrary ? L10n.string("LabelPodcastFeedInLibrary") : nil
        Button(action: toggle) {
            HStack(alignment: .firstTextBaseline, spacing: ABSSpacing.medium) {
                Image(
                    systemName: row.isInLibrary
                        ? "checkmark.circle.fill" : isSelected ? "checkmark.square.fill" : "square"
                )
                .foregroundStyle(
                    row.isInLibrary
                        ? AnyShapeStyle(ABSColor.success)
                        : isSelected ? AnyShapeStyle(ABSColor.accent) : AnyShapeStyle(ABSColor.mutedForeground)
                )
                .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: ABSSpacing.xSmall) {
                    if let number {
                        Text(verbatim: number)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(ABSColor.mutedForeground)
                    }
                    Text(verbatim: episode.title)
                        .font(.subheadline)
                    if let subtitle = episode.subtitle {
                        Text(verbatim: subtitle)
                            .font(.caption)
                            .foregroundStyle(ABSColor.mutedForeground)
                            .lineLimit(2)
                    }
                    if let published {
                        Text(verbatim: published)
                            .font(.caption2)
                            .foregroundStyle(ABSColor.mutedForeground)
                    }
                    if let inLibrary {
                        Text(verbatim: inLibrary)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(ABSColor.success)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(row.isInLibrary || isDisabled)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: PodcastFeedEpisodePresentation.accessibilityLabel(episode, locale: locale)))
        .accessibilityValue(
            Text(
                verbatim: PodcastFeedEpisodePresentation.accessibilityValue(
                    episode, isInLibrary: row.isInLibrary, locale: locale))
        )
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

/// What VoiceOver reads for a feed episode's row.
enum PodcastFeedEpisodePresentation {
    /// The title; for an untitled episode, "Untitled episode" and what tells it apart: the
    /// episode number, else the publish date, else the enclosure's file name (never the URL).
    static func accessibilityLabel(_ episode: RSSFeedEpisode, locale: Locale) -> String {
        let title = episode.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard title.isEmpty else { return title }
        let detail =
            episode.episode.map { L10n.string("LabelPodcastDetailEpisodeNumber", $0, locale: locale) }
            ?? PodcastDetailPresentation.publishedText(episode.publishedAt, locale: locale)
            ?? fileName(of: episode.enclosureURL)
        return [L10n.string("LabelPodcastFeedUntitledEpisode", locale: locale), detail]
            .compactMap { $0 }
            .joined(separator: ", ")
    }

    /// The last path component of `url`, decoded; `nil` without one.
    private static func fileName(of url: String) -> String? {
        guard let name = URL(string: url)?.lastPathComponent, !name.isEmpty, name != "/" else { return nil }
        return name
    }

    /// What VoiceOver reads after a feed episode's title, as the row shows it: the episode
    /// number, the publish date, In library, then the subtitle (whole, as the row truncates it).
    static func accessibilityValue(_ episode: RSSFeedEpisode, isInLibrary: Bool, locale: Locale) -> String {
        [
            episode.episode.map { L10n.string("LabelPodcastDetailEpisodeNumber", $0, locale: locale) },
            PodcastDetailPresentation.publishedText(episode.publishedAt, locale: locale),
            isInLibrary ? L10n.string("LabelPodcastFeedInLibrary") : nil,
            episode.subtitle,
        ]
        .compactMap { $0 }
        .joined(separator: ", ")
    }
}

// MARK: - Previews

/// A feed of four episodes, one already in the library, that queues downloads instantly.
private struct PreviewFeedService: PodcastEpisodeManagementService {
    func feedEpisodes(rssFeed: String) async throws -> [RSSFeedEpisode] {
        [
            ("https://example.com/4.mp3", "The Final Problem", "4", 1_702_000_000_000),
            ("https://example.com/3.mp3", "A Scandal in Bohemia", "3", 1_701_000_000_000),
            ("https://example.com/2.mp3", "The Red-Headed League", "2", 1_700_000_000_000),
            ("https://example.com/1.mp3", "Coming Soon", "1", 1_699_000_000_000),
        ].compactMap { url, title, number, date in
            RSSFeedEpisode(
                raw: .object([
                    "enclosure": .object(["url": .string(url)]), "title": .string(title), "episode": .string(number),
                    "subtitle": .string("A story from the public domain."), "publishedAt": .number(Double(date)),
                ]))
        }
    }
    func downloadEpisodes(podcastID: String, episodes: [RSSFeedEpisode]) async throws {}
    func clearDownloadQueue(podcastID: String) async throws {}
    func removeEpisode(podcastID: String, episodeID: String, deleteFile: Bool) async throws {}
}

#Preview("Feed episodes") {
    PodcastEpisodesFeedSheet(
        model: PodcastFeedEpisodesModel(
            podcastID: "li_podcast_preview", feedURL: "https://example.com/feed.xml",
            libraryEpisodes: [
                ABSCore.PodcastEpisode(
                    id: "pe_1", enclosure: PodcastEpisodeEnclosure(url: "https://example.com/1.mp3"))
            ],
            service: PreviewFeedService())
    ) { _ in }
}

#Preview("Accessibility text") {
    PodcastEpisodesFeedSheet(
        model: PodcastFeedEpisodesModel(
            podcastID: "li_podcast_preview", feedURL: "https://example.com/feed.xml", libraryEpisodes: [],
            service: PreviewFeedService())
    ) { _ in }
    .environment(\.dynamicTypeSize, .accessibility2)
}
