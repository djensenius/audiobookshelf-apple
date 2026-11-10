import ABSAppModel
import ABSUI
import Observation
import SwiftUI

/// What ``PlayerSlot`` reads about playback. The player UI (#56) makes the shared player view
/// model conform and `AppEnvironment` passes it to the shell, so the shell doesn't depend on
/// playback until then; ``PlaceholderPlayerState`` stands in.
@MainActor
protocol PlayerSlotState: AnyObject, Observable {
    /// Whether a playback session exists. The mini player shows only then.
    var hasSession: Bool { get }
    /// The title of what is playing.
    var title: String { get }
}

/// A player state with nothing playing, until #56 provides the real one.
@MainActor @Observable
final class PlaceholderPlayerState: PlayerSlotState {
    var hasSession: Bool
    var title: String

    init(hasSession: Bool = false, title: String = "") {
        self.hasSession = hasSession
        self.title = title
    }
}

/// Places the player around the tab shell (ADR 0004). Whether the full player and the queue
/// inspector are shown is per scene, so both follow the scene's ``Router``.
///
/// - iOS: the mini player is the tab view's bottom accessory, which sits above the tab bar and
///   follows the sidebar layout too; the full player is a full-screen cover.
/// - macOS: the mini player is a bar under the content. The full player is the Now Playing
///   window, which #56 opens when `Router/isFullPlayerPresented` turns on.
/// - Both: the queue is an inspector, which compact width shows as a sheet.
///
/// The content of all three is a placeholder until #56.
struct PlayerSlot: ViewModifier {
    @Bindable var router: Router
    let player: any PlayerSlotState

    func body(content: Content) -> some View {
        #if os(iOS)
            content
                .tabViewBottomAccessory(isEnabled: player.hasSession) {
                    MiniPlayerPlaceholder(router: router, player: player)
                }
                .fullScreenCover(isPresented: $router.isFullPlayerPresented) {
                    FullPlayerPlaceholder(player: player)
                }
                .inspector(isPresented: $router.isQueueInspectorPresented) {
                    QueueInspectorPlaceholder()
                }
        #else
            content
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    if player.hasSession {
                        MiniPlayerPlaceholder(router: router, player: player)
                            .background(.bar)
                    }
                }
                .inspector(isPresented: $router.isQueueInspectorPresented) {
                    QueueInspectorPlaceholder()
                }
        #endif
    }
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
