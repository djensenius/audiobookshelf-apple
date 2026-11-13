import ABSAppModel
import ABSUI
import Observation
import SwiftUI

/// What ``PlayerSlot`` reads about playback. ``PlayerViewModel`` conforms, and is what the app
/// passes; previews and tests pass ``PlaceholderPlayerState``.
@MainActor
protocol PlayerSlotState: AnyObject, Observable {
    /// Whether a playback session exists. The mini player shows only then.
    var hasSession: Bool { get }
    /// The title of what is playing.
    var title: String { get }
    /// The failure to show, with or without a session; `nil` when there is none.
    var errorMessageKey: PlayerErrorMessage? { get }
    /// "Stream" for a `.streamingNeedsConfirmation` failure.
    func confirmMeteredStreaming() async
    /// "Cancel" for a `.streamingNeedsConfirmation` failure.
    func declineMeteredStreaming()
}

extension PlayerViewModel: PlayerSlotState {}

/// A player state for previews and tests.
@MainActor @Observable
final class PlaceholderPlayerState: PlayerSlotState {
    var hasSession: Bool
    var title: String
    var errorMessageKey: PlayerErrorMessage?

    init(hasSession: Bool = false, title: String = "", errorMessageKey: PlayerErrorMessage? = nil) {
        self.hasSession = hasSession
        self.title = title
        self.errorMessageKey = errorMessageKey
    }

    func confirmMeteredStreaming() async {
        errorMessageKey = nil
    }

    func declineMeteredStreaming() {
        errorMessageKey = nil
    }
}

/// What a playback failure's alert offers besides dismissing it; a failure without one shows OK
/// alone, and one with it shows the action and Cancel.
enum PlayerErrorAction: Equatable {
    /// "Stream", for a confirmation ("ask"), never for "never".
    case streamAnyway

    init?(_ error: PlayerErrorMessage) {
        switch error {
        case .streamingNeedsConfirmation: self = .streamAnyway
        default: return nil
        }
    }

    var titleKey: String {
        switch self {
        case .streamAnyway: "ButtonStream"
        }
    }
}

/// Places the player around the tab shell (ADR 0004). Whether the full player and the queue
/// inspector are shown is per scene, so both follow the scene's ``Router``.
///
/// - iOS: the mini player is the tab view's bottom accessory, which sits above the tab bar and
///   follows the sidebar layout too; the full player is a full-screen cover.
/// - macOS: the mini player is a bar under the content. The full player is the
///   ``NowPlayingWindow``, which opens when `Router/isFullPlayerPresented` turns on with a
///   session; the flag then resets, so it can turn on again from any scene.
/// - Both: the queue is an inspector, which compact width shows as a sheet.
///
/// The mini and full players are ``MiniPlayerView`` and ``NowPlayingView`` when `player` is a
/// ``PlayerViewModel``, as in the app, else placeholders. The queue inspector is
/// ``QueueInspector``.
///
/// Without a session the full player closes, also when it is opened with none (on macOS, the
/// flag resets and the window closes itself). A queue auto-advance that passes through `.idle`
/// would close it too (#60).
///
/// A playback failure (`errorMessageKey`) shows in an alert, with or without a session, and only
/// in the active scene, so other windows don't repeat it (``PlayerErrorAlertOwner``). The queue
/// inspector and, on iOS, the full player show it while they're on screen, the one on top
/// instead of the content. Each scene shows a failure until it's dismissed there, and again only
/// after the player has had none (or a different one). A failure with a ``PlayerErrorAction``
/// offers it and Cancel instead of OK.
struct PlayerSlot: ViewModifier {
    @Bindable var router: Router
    let player: any PlayerSlotState
    #if os(macOS)
        @Environment(\.openWindow) private var openWindow
    #endif

    func body(content: Content) -> some View {
        hosting(content)
            .playerErrorAlerts(player: player)
            .onChange(
                of: Self.presentsWithoutSession(
                    isPresented: router.isFullPlayerPresented, hasSession: player.hasSession),
                initial: true
            ) { _, stale in
                if stale { router.isFullPlayerPresented = false }
            }
    }

    /// Whether the full player is presented with nothing to play, so it must close: the session
    /// ended while it was open, or it was opened without one.
    nonisolated static func presentsWithoutSession(isPresented: Bool, hasSession: Bool) -> Bool {
        isPresented && !hasSession
    }

    /// Whether turning the full player on opens the Now Playing window (macOS): only with a session.
    nonisolated static func opensNowPlayingWindow(isPresented: Bool, hasSession: Bool) -> Bool {
        isPresented && hasSession
    }

    /// The failure to show: the current one, unless the scene dismissed it.
    nonisolated static func shownError(
        current: PlayerErrorMessage?, dismissed: PlayerErrorMessage?
    ) -> PlayerErrorMessage? {
        current == dismissed ? nil : current
    }

    /// The dismissal left once the failure changes: none, unless it changed back to the dismissed
    /// one, so a different failure (or the first again, after another) shows.
    nonisolated static func dismissed(
        afterChangeTo error: PlayerErrorMessage?, dismissed: PlayerErrorMessage?
    ) -> PlayerErrorMessage? {
        error == dismissed ? dismissed : nil
    }

    /// The string key of a failure's message.
    nonisolated static func messageKey(for error: PlayerErrorMessage) -> String {
        switch error {
        case .streamingNeedsConfirmation: "MessageStreamingNeedsConfirmation"
        case .streamingNotAllowed: "ToastStreamingNotAllowedOnCellular"
        case .sessionStartFailed, .playbackFailed: "MessagePlaybackStartFailed"
        case .streamUnavailable: "MessagePlaybackStreamUnavailable"
        case .streamingInterrupted: "MessagePlaybackStreamingInterrupted"
        case .streamRejected: "MessagePlaybackStreamRejected"
        }
    }

    @ViewBuilder private func hosting(_ content: Content) -> some View {
        #if os(iOS)
            content
                .tabViewBottomAccessory(isEnabled: player.hasSession) {
                    miniPlayer
                }
                .fullScreenCover(isPresented: $router.isFullPlayerPresented) {
                    fullPlayer.playerErrorAlertLayer(player: player)
                }
                .inspector(isPresented: $router.isQueueInspectorPresented) {
                    QueueInspector(router: router)
                        .playerErrorAlertLayer(player: player)
                }
        #else
            content
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    if player.hasSession {
                        miniPlayer
                            .background(.bar)
                    }
                }
                .inspector(isPresented: $router.isQueueInspectorPresented) {
                    QueueInspector(router: router)
                        .playerErrorAlertLayer(player: player)
                }
                .onChange(of: router.isFullPlayerPresented) { _, isPresented in
                    if Self.opensNowPlayingWindow(isPresented: isPresented, hasSession: player.hasSession) {
                        openWindow(id: NowPlayingWindow.id)
                        router.isFullPlayerPresented = false
                    }
                }
        #endif
    }

    @ViewBuilder private var miniPlayer: some View {
        if let model = player as? PlayerViewModel {
            MiniPlayerView(model: model, router: router)
        } else {
            MiniPlayerPlaceholder(router: router, player: player)
        }
    }

    #if os(iOS)
        @ViewBuilder private var fullPlayer: some View {
            if let model = player as? PlayerViewModel {
                NowPlayingView(model: model)
            } else {
                FullPlayerPlaceholder(player: player)
            }
        }
    #endif
}

private struct MiniPlayerPlaceholder: View {
    let router: Router
    let player: any PlayerSlotState

    var body: some View {
        Button {
            router.isFullPlayerPresented = true
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "waveform")
                    .accessibilityHidden(true)
                Text(verbatim: player.title)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(verbatim: L10n.string("LabelMiniPlayerAccessibility", player.title)))
        .accessibilityHint(Text(verbatim: L10n.string("LabelMiniPlayerHint")))
    }
}

#if os(iOS)
    private struct FullPlayerPlaceholder: View {
        let player: any PlayerSlotState
        @Environment(\.dismiss) private var dismiss

        var body: some View {
            NavigationStack {
                ContentUnavailableView {
                    Label {
                        Text(verbatim: player.title)
                    } icon: {
                        Image(systemName: "waveform")
                    }
                }
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button {
                            dismiss()
                        } label: {
                            Label {
                                Text(verbatim: L10n.string("LabelClosePlayer"))
                            } icon: {
                                Image(systemName: "chevron.down")
                            }
                            .labelStyle(.iconOnly)
                        }
                    }
                }
            }
        }
    }
#endif
