import ABSAppModel
import ABSCore
import ABSUI
import SwiftUI

/// One episode (legacy `EpisodeRow.vue`): when it was published, its title, subtitle and
/// badges, which open the episode; then Play with the time left, the finished toggle and the
/// progress bar.
///
/// The episode's actions, Play included, are also in a context menu and the VoiceOver actions
/// of the link. Play and the finished toggle are left out or disabled as
/// `ItemAction.available(for:progress:context:)` says, so a missing podcast can't change.
struct PodcastEpisodeRow: View {
    let model: PodcastDetailModel
    let episode: PodcastEpisode
    let context: ItemActionContext
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
        let actions =
            model.summary(for: episode).map {
                ItemAction.available(for: $0, progress: progress, context: context).filter { $0.kind != .openDetails }
            } ?? []
        VStack(alignment: .leading, spacing: ABSSpacing.small) {
            NavigationLink(value: Route.episode(itemID: model.itemID, episodeID: episode.id)) {
                details
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(verbatim: episode.title))
            .accessibilityValue(Text(verbatim: spokenDetails))
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

    private var published: String? { PodcastDetailPresentation.publishedText(episode.publishedAt, locale: locale) }
    private var badges: [String] { PodcastDetailPresentation.badges(episode, locale: locale) }

    private var details: some View {
        VStack(alignment: .leading, spacing: ABSSpacing.xSmall) {
            if let published {
                Text(verbatim: published)
                    .font(.caption)
                    .foregroundStyle(ABSColor.mutedForeground)
            }
            Text(verbatim: episode.title)
                .font(.subheadline.weight(.semibold))
            if let summary = PodcastDetailPresentation.summaryText(episode) {
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

    /// The date, badges and summary, after the title.
    private var spokenDetails: String {
        ([published] + badges.map(Optional.some) + [PodcastDetailPresentation.summaryText(episode)])
            .compactMap { $0 }
            .joined(separator: ", ")
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
            }
            .buttonStyle(.borderless)
            .disabled(!actions.contains(toggle) || isUpdating)
            .help(Text(verbatim: toggleTitle))
            Spacer(minLength: 0)
        }
    }
}
