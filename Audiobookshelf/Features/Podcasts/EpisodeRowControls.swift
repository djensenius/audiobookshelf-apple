import ABSAppModel
import ABSCore
import ABSUI
import SwiftUI

/// What an episode row's controls show (legacy `EpisodeRow.vue`), kept out of the view so app tests cover it.
struct EpisodeRowControlsState: Equatable {
    /// The play button's text: the time left, the duration or "Finished", else "Play Episode".
    let playTitle: String
    /// What VoiceOver reads for the play button after its label.
    let playSpoken: String
    let canPlay: Bool
    let isFinished: Bool
    /// The finished toggle: mark finished, or not finished once finished.
    let toggle: ItemActionKind
    let toggleTitle: String
    let toggleSystemImage: String
    let canToggle: Bool
    /// The progress bar's value, while the episode is in progress.
    let progressFraction: Double?

    /// - Parameters:
    ///   - actions: The actions the row offers (``PodcastEpisodeActions/available(for:progress:context:isGone:)``).
    ///   - isStarting: This episode's Play is starting.
    ///   - isOtherStarting: Another episode's Play is starting, so this one can't start too.
    ///   - isUpdating: This episode's finished state is being changed.
    init(
        status: PodcastDetailModel.EpisodeStatus, progress: ItemProgress?, actions: [ItemActionKind],
        isStarting: Bool, isOtherStarting: Bool, isUpdating: Bool, locale: Locale
    ) {
        let status = PodcastDetailPresentation.statusText(status, locale: locale)
        playTitle = status.text.isEmpty ? L10n.string("ButtonPlayEpisode") : status.text
        playSpoken = status.spoken
        canPlay = actions.contains(.play) && !isStarting && !isOtherStarting
        isFinished = progress?.isFinished == true
        toggle = isFinished ? .markNotFinished : .markFinished
        toggleTitle = L10n.string(isFinished ? "SharedMarkAsNotFinished" : "MessageMarkAsFinished")
        toggleSystemImage = isFinished ? "checkmark.circle.fill" : "checkmark.circle"
        canToggle = actions.contains(toggle) && !isUpdating
        progressFraction = progress.flatMap { $0.isInProgress ? $0.fraction : nil }
    }
}

/// Play with the time left, the finished toggle and the progress bar under an episode row, on the podcast screen
/// (``PodcastEpisodeRow``) and the Latest screen (``LatestEpisodeRow``).
struct EpisodeRowControls: View {
    let status: PodcastDetailModel.EpisodeStatus
    let progress: ItemProgress?
    let actions: [ItemActionKind]
    let isStarting: Bool
    let isOtherStarting: Bool
    let isUpdating: Bool
    let perform: (ItemActionKind) -> Void
    @Environment(\.locale) private var locale

    var body: some View {
        let state = EpisodeRowControlsState(
            status: status, progress: progress, actions: actions, isStarting: isStarting,
            isOtherStarting: isOtherStarting, isUpdating: isUpdating, locale: locale)
        VStack(alignment: .leading, spacing: ABSSpacing.small) {
            HStack(spacing: ABSSpacing.medium) {
                Button {
                    perform(.play)
                } label: {
                    Label {
                        Text(verbatim: state.playTitle)
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
                .tint(state.isFinished ? Color.secondary : ABSColor.success)
                .disabled(!state.canPlay)
                .accessibilityLabel(Text(verbatim: L10n.string("ButtonPlayEpisode")))
                .accessibilityValue(Text(verbatim: state.playSpoken))
                Button {
                    perform(state.toggle)
                } label: {
                    Label {
                        Text(verbatim: state.toggleTitle)
                    } icon: {
                        Image(systemName: state.toggleSystemImage)
                            .foregroundStyle(
                                state.isFinished
                                    ? AnyShapeStyle(ABSColor.success) : AnyShapeStyle(ABSColor.mutedForeground))
                    }
                    .labelStyle(.iconOnly)
                    .imageScale(.large)
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(.rect)
                }
                .buttonStyle(.borderless)
                .disabled(!state.canToggle)
                .help(Text(verbatim: state.toggleTitle))
                Spacer(minLength: 0)
            }
            if let fraction = state.progressFraction {
                ProgressView(value: fraction)
                    .tint(ABSColor.progress)
                    .accessibilityHidden(true)
            }
        }
    }
}

/// An episode's badges (``PodcastDetailPresentation/badges(_:locale:)``) as capsules that wrap; nothing without any.
struct EpisodeBadges: View {
    let badges: [String]

    var body: some View {
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
}

#if DEBUG
    #Preview("Episode controls") {
        VStack(alignment: .leading, spacing: ABSSpacing.large) {
            EpisodeRowControls(
                status: .notStarted(duration: 1_800), progress: nil, actions: [.play, .markFinished],
                isStarting: false, isOtherStarting: false, isUpdating: false
            ) { _ in }
            EpisodeRowControls(
                status: .inProgress(remaining: 840), progress: ItemProgress(fraction: 0.6),
                actions: [.play, .markFinished], isStarting: true, isOtherStarting: false, isUpdating: false
            ) { _ in }
            EpisodeRowControls(
                status: .finished, progress: ItemProgress(fraction: 1, isFinished: true),
                actions: [.play, .markNotFinished], isStarting: false, isOtherStarting: false, isUpdating: true
            ) { _ in }
            EpisodeBadges(badges: ["Episode #3", "Season #1", "Bonus"])
        }
        .padding()
        .absBackground()
    }
#endif
