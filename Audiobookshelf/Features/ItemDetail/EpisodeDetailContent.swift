import ABSAppModel
import ABSCore
import ABSUI
import SwiftUI

/// The loaded episode (legacy `pages/item/_id/_episode/index.vue`): the cover, a link to the
/// podcast, when it was published and how long it is, the title and badges, Play, the user's
/// progress, and the show notes. Across a fold running down through it (iOS 27.1 and later), the
/// show notes go on the other side of the fold (``DetailArrangement``).
///
/// Play starts the episode through the environment's `playItem`, which is `nil` while signed
/// out (and until the shell provides it), so it's disabled then, while a start is in progress,
/// and while the podcast is gone from the server. A failed start shows an alert.
struct EpisodeDetailContent: View {
    let model: EpisodeDetailModel
    let episode: PodcastEpisode
    @Environment(\.playItem) private var playItem
    @Environment(\.locale) private var locale
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var isStarting = false
    @State private var playFailure: ItemDetailPlayFailure?
    @State private var goneState = ItemDetailGoneState()

    var body: some View {
        let snapshot = ItemDetailGoneState.Snapshot(model: model.detail)
        let isGone = goneState.isGone(snapshot)
        let refreshFailure = ItemDetailRefreshFailure(model: model.detail, isGone: isGone)
        let play = EpisodeDetailPresentation.play(
            for: model, canPlay: playItem != nil && !isStarting, isGone: isGone)
        ScrollView {
            VStack(alignment: .leading, spacing: ABSSpacing.large) {
                refreshBanner(refreshFailure)
                heading
                playButton(play)
                EpisodeDetailProgress(model: model)
                EpisodeDetailShowNotes(html: model.showNotesHTML)
            }
            .padding(ItemDetailLayout.padding)
            .frame(maxWidth: 800, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        // Across a fold running down through it (book pose), the show notes on the other side (#85).
        .detailSplitAtFold {
            refreshBanner(refreshFailure)
            heading
            playButton(play)
            EpisodeDetailProgress(model: model)
        } secondary: {
            EpisodeDetailShowNotes(html: model.showNotesHTML)
        }
        .refreshable { await model.detail.load() }
        .absBackground()
        .onChange(of: snapshot, initial: true) { _, snapshot in goneState.update(snapshot) }
        .alert(
            Text(verbatim: L10n.string("MessagePlaybackStartFailed")),
            isPresented: Binding {
                playFailure != nil
            } set: {
                if !$0 { playFailure = nil }
            },
            presenting: playFailure
        ) { _ in
        } message: { failure in
            Text(verbatim: failure.message)
        }
    }

    @ViewBuilder private func refreshBanner(_ failure: ItemDetailRefreshFailure?) -> some View {
        if let failure {
            ItemDetailRefreshFailedBanner(messageKey: failure.messageKey) {
                Task { await model.detail.load() }
            }
        }
    }

    /// The cover beside the header, or above it at accessibility sizes.
    @ViewBuilder private var heading: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: ABSSpacing.medium) {
                cover
                header
            }
        } else {
            HStack(alignment: .top, spacing: ABSSpacing.medium) {
                cover
                header
            }
        }
    }

    /// The podcast's cover, which the title beside it speaks for.
    private var cover: some View {
        EpisodeDetailCover(model: model, title: model.podcastTitle ?? episode.title)
            .frame(width: 120)
    }

    private var header: some View {
        let badges = PodcastDetailPresentation.badges(episode, locale: locale)
        return VStack(alignment: .leading, spacing: ABSSpacing.xSmall) {
            if let podcastTitle = model.podcastTitle {
                NavigationLink(value: Route.item(id: model.itemID)) {
                    Text(verbatim: podcastTitle)
                        .font(.subheadline)
                        .underline()
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(verbatim: L10n.string("LabelPodcast")))
                .accessibilityValue(Text(verbatim: podcastTitle))
                .accessibilityHint(Text(verbatim: L10n.string("SharedOpenDetailsHint")))
            }
            if let detail = EpisodeDetailPresentation.detailLine(episode, locale: locale) {
                Text(verbatim: detail)
                    .font(.footnote)
                    .foregroundStyle(ABSColor.mutedForeground)
            }
            Text(verbatim: episode.title)
                .font(.title2.bold())
                .accessibilityAddTraits(.isHeader)
            if !badges.isEmpty {
                ItemDetailFlowLayout(spacing: ABSSpacing.xSmall) {
                    ForEach(Array(badges.enumerated()), id: \.offset) { _, badge in
                        Text(verbatim: badge)
                            .font(.caption)
                            .padding(.horizontal, ABSSpacing.small)
                            .padding(.vertical, ABSSpacing.xxSmall)
                            .background(ABSColor.secondarySurface, in: .capsule)
                    }
                }
                .padding(.top, ABSSpacing.xSmall)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func playButton(_ play: ItemDetailPlayPresentation) -> some View {
        Button(action: start) {
            Label {
                Text(verbatim: L10n.string(play.titleKey))
            } icon: {
                if isStarting {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: play.systemImage)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(!play.isEnabled)
        .accessibilityValue(Text(verbatim: episode.title))
    }

    /// Plays the episode (``EpisodeDetailPresentation/startPlayback(of:with:)``) and shows an
    /// alert if that fails.
    private func start() {
        guard let playItem, !isStarting else { return }
        isStarting = true
        Task {
            defer { isStarting = false }
            if let failure = await EpisodeDetailPresentation.startPlayback(of: model, with: playItem) {
                playFailure = failure
            }
        }
    }
}

/// The podcast's cover through the environment's image pipeline, with the episode's progress.
private struct EpisodeDetailCover: View {
    let model: EpisodeDetailModel
    let title: String
    @Environment(\.serverID) private var serverID

    var body: some View {
        let progress = model.progressFraction
        CoverView(
            key: serverID.flatMap { model.summary?.coverKey(serverID: $0, bucket: .small) }, title: title,
            shape: .square, progress: progress > 0 ? progress : nil, isFinished: model.isFinished,
            accessibility: .hidden)
    }
}

/// The user's progress on the episode: a bar with the percentage, and the time left or when
/// they finished; nothing before they start (legacy `progressPercent > 0`).
private struct EpisodeDetailProgress: View {
    let model: EpisodeDetailModel
    @Environment(\.locale) private var locale

    var body: some View {
        if let text = ItemDetailProgressText(
            fraction: model.progressFraction, isFinished: model.isFinished, timeRemaining: model.timeRemaining,
            finishedAt: model.finishedAt, locale: locale)
        {
            VStack(alignment: .leading, spacing: ABSSpacing.xSmall) {
                HStack {
                    Text(verbatim: L10n.string("LabelYourProgress"))
                    Spacer(minLength: ABSSpacing.small)
                    Text(verbatim: text.percent)
                        .monospacedDigit()
                }
                .font(.subheadline.weight(.semibold))
                ProgressView(value: model.isFinished ? 1 : min(max(model.progressFraction, 0), 1))
                    .tint(model.isFinished ? ABSColor.success : ABSColor.progress)
                    .accessibilityHidden(true)
                if let detail = text.detail {
                    Text(verbatim: detail)
                        .font(.footnote)
                        .foregroundStyle(ABSColor.mutedForeground)
                }
            }
            .padding(ABSSpacing.medium)
            .background(ABSColor.secondarySurface, in: .rect(cornerRadius: ABSRadius.medium))
            .accessibilityElement(children: .combine)
        }
    }
}

/// The show notes in full, converted off the main actor once per distinct HTML
/// (``EpisodeDetailPresentation/showNotes(html:)``); links open in the browser.
private struct EpisodeDetailShowNotes: View {
    let html: String?
    @State private var converted: (html: String, text: AttributedString?)?

    var body: some View {
        // Empty until converted, and when there are no notes.
        VStack(alignment: .leading, spacing: ABSSpacing.small) {
            if converted?.html == html, let text = converted?.text {
                Text(verbatim: L10n.string("LabelDescription"))
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                Text(text)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
        .task(id: html) { await convert() }
    }

    private func convert() async {
        guard let html, converted?.html != html else { return }
        let text = await Task.detached(priority: .userInitiated) {
            EpisodeDetailPresentation.showNotes(html: html)
        }
        .value
        guard !Task.isCancelled else { return }
        converted = (html, text)
    }
}
