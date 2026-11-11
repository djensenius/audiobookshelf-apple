import ABSAppModel
import ABSCore
import ABSUI
import SwiftUI

/// One episode (legacy `EpisodeRow.vue`): when it was published, its title, subtitle and
/// badges, which open the episode; then Play with the time left, the finished toggle and the
/// progress bar.
///
/// Play and the finished toggle are also in a context menu and the VoiceOver actions of the
/// link, as ``PodcastEpisodeActions/available(for:progress:context:isGone:)`` offers them; when
/// the podcast is gone from the server only the link, which opens the episode, still works.
/// VoiceOver reads the start of the summary, with the rest under More Content.
struct PodcastEpisodeRow: View {
    let model: PodcastDetailModel
    let episode: PodcastEpisode
    let context: ItemActionContext
    /// The podcast is gone from the server, so its episodes can't be played or marked.
    let isGone: Bool
    /// This episode's Play is starting.
    let isStarting: Bool
    /// Another episode's Play is starting, so this one can't start too.
    let isOtherStarting: Bool
    /// This episode's finished state is being changed.
    let isUpdating: Bool
    /// Performs an action other than ``ItemActionKind/openDetails`` on the episode.
    let perform: (ItemActionKind) -> Void
    @Environment(\.locale) private var locale

    var body: some View {
        let progress = model.itemProgress(for: episode)
        let actions = PodcastEpisodeActions.available(
            for: model.summary(for: episode), progress: progress, context: context, isGone: isGone)
        let published = PodcastDetailPresentation.publishedText(episode.publishedAt, locale: locale)
        let badges = PodcastDetailPresentation.badges(episode, locale: locale)
        let summary = PodcastDetailPresentation.summaryText(episode)
        let spokenSummary = summary.map { PodcastDetailPresentation.spokenSummary($0) }
        VStack(alignment: .leading, spacing: ABSSpacing.small) {
            NavigationLink(value: Route.episode(itemID: model.itemID, episodeID: episode.id)) {
                details(published: published, summary: summary, badges: badges)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(verbatim: episode.title))
            // The date, badges and the start of the summary, after the title.
            .accessibilityValue(
                Text(
                    verbatim: ([published] + badges.map(Optional.some) + [spokenSummary]).compactMap { $0 }
                        .joined(separator: ", "))
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
        VStack(alignment: .leading, spacing: ABSSpacing.xSmall) {
            if let published {
                Text(verbatim: published)
                    .font(.caption)
                    .foregroundStyle(ABSColor.mutedForeground)
            }
            Text(verbatim: episode.title)
                .font(.subheadline.weight(.semibold))
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
        .contentShape(.rect)
    }

    private func controls(progress: ItemProgress?, actions: [ItemActionKind]) -> some View {
        let status = PodcastDetailPresentation.statusText(model.status(for: episode), locale: locale)
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
