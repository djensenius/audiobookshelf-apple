import ABSAppModel
import ABSCore
import ABSUI
import SwiftUI

/// One episode of the Latest screen (legacy `LatestEpisodeRow.vue`): the podcast's cover, the podcast, when the
/// episode was published, its title, summary and badges, which open the episode; then Play with the time left,
/// the finished toggle and the progress bar, as on the podcast screen (``PodcastEpisodeRow``).
///
/// Play and the finished toggle are also in the context menu and the VoiceOver actions of the link. VoiceOver
/// reads the start of the summary, with the rest under More Content.
struct LatestEpisodeRow: View {
    let model: LatestEpisodesModel
    let row: LatestEpisode
    let context: ItemActionContext
    /// What "3 days ago" is relative to: the list's minute timeline, so the text moves on while the list stays open.
    let now: Date
    /// This episode's Play is starting.
    let isStarting: Bool
    /// Another episode's Play is starting, so this one can't start too.
    let isOtherStarting: Bool
    /// This episode's finished state is being changed.
    let isUpdating: Bool
    /// Performs an action other than ``ItemActionKind/openDetails`` on the episode.
    let perform: (ItemActionKind) -> Void
    @Environment(\.serverID) private var serverID
    @Environment(\.locale) private var locale
    @ScaledMetric(relativeTo: .body) private var coverWidth: CGFloat = 56

    var body: some View {
        let progress = model.itemProgress(for: row)
        let actions = PodcastEpisodeActions.available(
            for: row.summary, progress: progress, context: context, isGone: false)
        let published = LatestPresentation.publishedText(row.episode.publishedAt, now: now, locale: locale)
        let badges = PodcastDetailPresentation.badges(row.episode, locale: locale)
        let summary = PodcastDetailPresentation.summaryText(row.episode)
        let spokenSummary = summary.map { PodcastDetailPresentation.spokenSummary($0) }
        VStack(alignment: .leading, spacing: ABSSpacing.small) {
            NavigationLink(value: Route.episode(itemID: row.itemID, episodeID: row.episode.id)) {
                details(published: published, summary: summary, badges: badges)
            }
            .buttonStyle(.plain)
            .itemHover()
            .accessibilityLabel(Text(verbatim: row.episode.title))
            .accessibilityValue(
                Text(
                    verbatim: LatestPresentation.detailsValue(
                        row, published: published, badges: badges, spokenSummary: spokenSummary))
            )
            .accessibilityCustomContent(
                AccessibilityCustomContentKey(Text(verbatim: L10n.string("LabelDescription")), id: "description"),
                summary == spokenSummary ? nil : summary.map { Text(verbatim: $0) }
            )
            .accessibilityHint(Text(verbatim: L10n.string("SharedOpenDetailsHint")))
            .itemActions(actions, perform: perform)
            controls(progress: progress, actions: actions.map(\.kind))
            if let progress, progress.isInProgress {
                ProgressView(value: progress.fraction)
                    .tint(ABSColor.progress)
                    .accessibilityHidden(true)
            }
        }
        .padding(.vertical, ABSSpacing.medium)
    }

    private func details(published: String?, summary: String?, badges: [String]) -> some View {
        HStack(alignment: .top, spacing: ABSSpacing.medium) {
            CoverView(
                key: serverID.flatMap { row.summary.coverKey(serverID: $0, bucket: .small) },
                title: row.summary.subtitle ?? row.episode.title, shape: .square, accessibility: .hidden
            )
            .frame(width: min(coverWidth, 120))
            VStack(alignment: .leading, spacing: ABSSpacing.xSmall) {
                HStack(spacing: ABSSpacing.xxSmall) {
                    if let podcast = row.summary.subtitle {
                        Text(verbatim: podcast)
                            .lineLimit(1)
                    }
                    if row.summary.isExplicit { ExplicitBadge() }
                }
                .font(.caption)
                .foregroundStyle(ABSColor.mutedForeground)
                if let published {
                    Text(verbatim: published)
                        .font(.caption)
                        .foregroundStyle(ABSColor.mutedForeground)
                }
                Text(verbatim: row.episode.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(ABSColor.foreground)
                if let summary {
                    Text(verbatim: summary)
                        .font(.subheadline)
                        .lineLimit(2)
                }
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
        .contentShape(.rect)
    }

    private func controls(progress: ItemProgress?, actions: [ItemActionKind]) -> some View {
        let status = PodcastDetailPresentation.statusText(model.status(for: row), locale: locale)
        let isFinished = progress?.isFinished == true
        let toggle: ItemActionKind = isFinished ? .markNotFinished : .markFinished
        let toggleTitle = L10n.string(isFinished ? "SharedMarkAsNotFinished" : "MessageMarkAsFinished")
        return HStack(spacing: ABSSpacing.medium) {
            Button {
                perform(.play)
            } label: {
                Label {
                    Text(verbatim: status.text.isEmpty ? L10n.string("ButtonPlayEpisode") : status.text)
                        .monospacedDigit()
                } icon: {
                    if isStarting {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "play.fill")
                    }
                }
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
            .tint(isFinished ? Color.secondary : ABSColor.success)
            .disabled(!actions.contains(.play) || isStarting || isOtherStarting)
            .accessibilityLabel(Text(verbatim: L10n.string("ButtonPlayEpisode")))
            .accessibilityValue(Text(verbatim: status.spoken))
            Button {
                perform(toggle)
            } label: {
                Label {
                    Text(verbatim: toggleTitle)
                } icon: {
                    Image(systemName: isFinished ? "checkmark.circle.fill" : "checkmark.circle")
                        .foregroundStyle(
                            isFinished ? AnyShapeStyle(ABSColor.success) : AnyShapeStyle(ABSColor.mutedForeground))
                }
                .labelStyle(.iconOnly)
                .imageScale(.large)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(.rect)
            }
            .buttonStyle(.borderless)
            .disabled(!actions.contains(toggle) || isUpdating)
            .help(Text(verbatim: toggleTitle))
            Spacer(minLength: 0)
        }
    }
}
