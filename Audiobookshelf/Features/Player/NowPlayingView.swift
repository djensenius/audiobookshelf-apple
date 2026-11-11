import ABSAppModel
import ABSCore
import ABSUI
import SwiftUI

/// The full player (port of the expanded `components/app/AudioPlayer.vue`): the cover, title,
/// author and chapter, the scrubber with its chapter-track toggle, the transport controls, a
/// speed menu and the AirPlay picker, with ``PlayerActionsBar`` in the bottom toolbar.
///
/// iOS presents it as a full-screen cover on every size (ADR 0004); it dismisses itself when
/// playback closes.
struct NowPlayingView: View {
    let model: PlayerViewModel
    @Environment(AppSettings.self) private var settings: AppSettings?
    @Environment(Router.self) private var router: Router?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    cover
                    titles
                    PlayerScrubber(
                        progress: model.progress, elapsed: model.elapsed, remaining: model.remainingAtRate,
                        onScrub: { model.scrub(to: $0) },
                        onScrubEnd: { Task { await model.endScrub() } },
                        onIncrement: { Task { await model.jumpForward() } },
                        onDecrement: { Task { await model.jumpBackward() } }
                    )
                    TransportControls(
                        style: .full, showsPause: model.showsPause, isBuffering: model.isBuffering,
                        jumpBackwardSeconds: model.jumpBackwardSeconds, jumpForwardSeconds: model.jumpForwardSeconds,
                        hasPreviousChapter: model.hasPreviousChapter, hasNextChapter: model.hasNextChapter,
                        haptic: settings?.hapticFeedback ?? .off
                    ) { action in
                        Task { await model.perform(action) }
                    }
                    secondaryControls
                }
                .padding(.horizontal, 24)
                .padding(.vertical)
                .frame(maxWidth: 600)
                .frame(maxWidth: .infinity)
            }
            .scrollBounceBehavior(.basedOnSize)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        dismiss()
                    } label: {
                        Label {
                            Text(verbatim: L10n.string("LabelMinimizePlayer"))
                        } icon: {
                            Image(systemName: "chevron.down")
                        }
                        .labelStyle(.iconOnly)
                    }
                }
                PlayerActionsBar(model: model)
            }
        }
        .onChange(of: model.hasSession) { _, hasSession in
            if !hasSession { dismiss() }
        }
    }

    /// The current library's cover shape, as the legacy player used the library's aspect ratio.
    private var coverShape: CoverShape {
        router?.libraryKind == .podcast ? .square : .book
    }

    private var cover: some View {
        CoverView(key: model.coverKey, title: model.title, author: model.author, shape: coverShape)
            .clipShape(.rect(cornerRadius: 8))
            .shadow(radius: 8, y: 4)
            .containerRelativeFrame(.vertical) { height, _ in height * 0.45 }
            .accessibilityHidden(true)
    }

    private var titles: some View {
        VStack(spacing: 4) {
            if let chapter = model.chapterTitle {
                Text(verbatim: chapter)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Text(verbatim: model.title)
                .font(.title2.weight(.bold))
                .accessibilityAddTraits(.isHeader)
            if !model.author.isEmpty {
                Text(verbatim: model.author)
                    .font(.headline)
                    .foregroundStyle(.secondary)
            }
        }
        .multilineTextAlignment(.center)
        .lineLimit(3)
    }

    private var secondaryControls: some View {
        HStack {
            Toggle(isOn: Binding(get: { model.usesChapterTrack }, set: { _ in model.toggleChapterTrack() })) {
                Label {
                    Text(verbatim: L10n.string("LabelChapterTrack"))
                } icon: {
                    Image(systemName: "list.bullet.indent")
                }
                .labelStyle(.iconOnly)
                .frame(minWidth: 44, minHeight: 44)
            }
            .toggleStyle(.button)
            Spacer()
            PlaybackSpeedMenu(model: model)
            Spacer()
            RoutePicker(player: nil)
                .frame(width: 44, height: 44)
        }
        .buttonStyle(.borderless)
    }
}

/// The basic speed menu: the legacy speed modal's preset rates. The full speed sheet is #57.
private struct PlaybackSpeedMenu: View {
    let model: PlayerViewModel

    /// Legacy `PlaybackSpeedModal` rates.
    private static let rates: [Double] = [0.5, 1, 1.2, 1.5, 1.7, 2, 3]

    private static func label(_ rate: Double) -> String {
        L10n.string("LabelPlaybackRate", rate.formatted(.number.precision(.fractionLength(0...2))))
    }

    var body: some View {
        Menu {
            Picker(selection: Binding(get: { model.rate }, set: { model.setRate($0) })) {
                ForEach(Self.rates, id: \.self) { rate in
                    Text(verbatim: Self.label(rate)).tag(rate)
                }
            } label: {
                Text(verbatim: L10n.string("LabelPlaybackSpeed"))
            }
        } label: {
            Text(verbatim: Self.label(model.rate))
                .font(.headline)
                .monospacedDigit()
                .frame(minWidth: 44, minHeight: 44)
        }
        .accessibilityLabel(Text(verbatim: L10n.string("LabelPlaybackSpeed")))
        .accessibilityValue(Text(verbatim: Self.label(model.rate)))
    }
}

#Preview("Paused") {
    NowPlayingView(model: .preview())
}

#Preview("Playing") {
    NowPlayingView(model: .preview(at: 9_500, playing: true))
}
