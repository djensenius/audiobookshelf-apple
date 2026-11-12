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
/// ``PlayerViewModel``, as in the app, else placeholders. The queue inspector is a placeholder
/// until #60.
///
/// Without a session the full player closes, also when it is opened with none (on macOS, the
/// flag resets and the window closes itself). A queue auto-advance that passes through `.idle`
/// would close it too (#60).
///
/// A playback failure (`errorMessageKey`) shows in an alert, with or without a session, and only
/// in the active scene, so other windows don't repeat it. On iOS the full player shows it while
/// it covers the scene. Each scene shows a failure until it's dismissed there, and again only
/// after the player has had none (or a different one).
struct PlayerSlot: ViewModifier {
    @Bindable var router: Router
    let player: any PlayerSlotState
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.appearsActive) private var appearsActive
    #if os(macOS)
        @Environment(\.openWindow) private var openWindow
    #endif
    /// The failure this scene's alert was dismissed for.
    @State private var dismissedError: PlayerErrorMessage?

    func body(content: Content) -> some View {
        errorAlert(hosting(content), isEnabled: !fullPlayerCoversContent)
            .onChange(
                of: Self.presentsWithoutSession(
                    isPresented: router.isFullPlayerPresented, hasSession: player.hasSession),
                initial: true
            ) { _, stale in
                if stale { router.isFullPlayerPresented = false }
            }
            .onChange(of: player.errorMessageKey) { _, error in
                if error == nil { dismissedError = nil }
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

    /// The failure this scene shows, while it's the active one.
    private var shownError: PlayerErrorMessage? {
        guard scenePhase == .active, appearsActive else { return nil }
        return Self.shownError(current: player.errorMessageKey, dismissed: dismissedError)
    }

    /// Whether the full-screen player covers the content (iOS), which then can't present the alert.
    private var fullPlayerCoversContent: Bool {
        #if os(iOS)
            router.isFullPlayerPresented
        #else
            false
        #endif
    }

    /// ``shownError``'s alert on `view`, while `isEnabled`.
    private func errorAlert(_ view: some View, isEnabled: Bool) -> some View {
        let error = isEnabled ? shownError : nil
        return view.alert(
            Text(verbatim: error.map { L10n.string(Self.messageKey(for: $0)) } ?? ""),
            isPresented: Binding(
                get: { error != nil },
                set: { if !$0 { dismissedError = player.errorMessageKey } }),
            presenting: error
        ) { _ in
            Button(role: .cancel) {
            } label: {
                Text(verbatim: L10n.string("ButtonOk"))
            }
        }
    }

    @ViewBuilder private func hosting(_ content: Content) -> some View {
        #if os(iOS)
            content
                .tabViewBottomAccessory(isEnabled: player.hasSession) {
                    miniPlayer
                }
                .fullScreenCover(isPresented: $router.isFullPlayerPresented) {
                    errorAlert(fullPlayer, isEnabled: true)
                }
                .inspector(isPresented: $router.isQueueInspectorPresented) {
                    QueueInspectorPlaceholder()
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
                    QueueInspectorPlaceholder()
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

private struct QueueInspectorPlaceholder: View {
    var body: some View {
        ContentUnavailableView {
            Label {
                Text(verbatim: L10n.string("MessageNoItems"))
            } icon: {
                Image(systemName: "list.bullet")
            }
        }
    }
}
