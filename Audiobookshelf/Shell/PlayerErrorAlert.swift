import ABSAppModel
import ABSUI
import Observation
import SwiftUI

/// Which of a window's player error alerts shows a playback failure (`errorMessageKey`), so the
/// window shows it once, where the user is.
///
/// The window's own alert (``SwiftUICore/View/playerErrorAlerts(player:showsWindowAlert:)``) is
/// the base. A view presented over it that the base's alert can't show over, such as the full
/// player's cover or the queue, adds a layer (``SwiftUICore/View/playerErrorAlertLayer(player:)``)
/// while it's on screen, and the last layer added shows the alert instead of the base and the
/// layers below it. The window remembers the failure it was dismissed for in any of them, so
/// closing a layer doesn't show it again.
@MainActor @Observable
final class PlayerErrorAlertOwner {
    /// The layers on screen, in the order they appeared; the last shows the alert.
    private var layers: [UUID] = []
    /// The failure this window's alert was dismissed for.
    var dismissedError: PlayerErrorMessage?

    /// `layer` came on screen, over the others.
    func add(_ layer: UUID) {
        layers.removeAll { $0 == layer }
        layers.append(layer)
    }

    /// `layer` left the screen.
    func remove(_ layer: UUID) {
        layers.removeAll { $0 == layer }
    }

    /// Whether `layer` shows the alert; `nil` is the window's base, which does with no layers.
    func owns(_ layer: UUID?) -> Bool {
        layers.last == layer
    }

    /// The failure `layer` shows: `current`, while the window is active, `layer` owns the alert and
    /// the window didn't dismiss it.
    func shownError(current: PlayerErrorMessage?, in layer: UUID?, isActive: Bool) -> PlayerErrorMessage? {
        guard isActive, owns(layer) else { return nil }
        return PlayerSlot.shownError(current: current, dismissed: dismissedError)
    }

    /// The failure changed to `error`: a different one shows again (``PlayerSlot/dismissed(afterChangeTo:dismissed:)``).
    func errorChanged(to error: PlayerErrorMessage?) {
        dismissedError = PlayerSlot.dismissed(afterChangeTo: error, dismissed: dismissedError)
    }
}

extension View {
    /// Makes this window's ``PlayerErrorAlertOwner`` for the views inside, and shows `player`'s
    /// failures in an alert here when `showsWindowAlert` and no layer is on screen.
    func playerErrorAlerts(player: any PlayerSlotState, showsWindowAlert: Bool = true) -> some View {
        modifier(PlayerErrorAlertHost(player: player, showsWindowAlert: showsWindowAlert))
    }

    /// Shows `player`'s failures here instead of in the window's alert while this view is on screen
    /// and the last layer added. Does nothing outside ``playerErrorAlerts(player:showsWindowAlert:)``.
    func playerErrorAlertLayer(player: any PlayerSlotState) -> some View {
        modifier(PlayerErrorAlertLayer(player: player))
    }
}

private struct PlayerErrorAlertHost: ViewModifier {
    let player: any PlayerSlotState
    let showsWindowAlert: Bool
    @State private var owner = PlayerErrorAlertOwner()

    func body(content: Content) -> some View {
        content
            .modifier(PlayerErrorAlertPresenter(player: player, owner: owner, layer: nil, isEnabled: showsWindowAlert))
            .environment(owner)
            .onChange(of: player.errorMessageKey) { _, error in
                owner.errorChanged(to: error)
            }
    }
}

private struct PlayerErrorAlertLayer: ViewModifier {
    let player: any PlayerSlotState
    @Environment(PlayerErrorAlertOwner.self) private var owner: PlayerErrorAlertOwner?
    @State private var layer = UUID()

    func body(content: Content) -> some View {
        if let owner {
            content
                .modifier(PlayerErrorAlertPresenter(player: player, owner: owner, layer: layer, isEnabled: true))
                .onAppear { owner.add(layer) }
                .onDisappear { owner.remove(layer) }
        } else {
            content
        }
    }
}

/// The alert itself, on the base or a layer. Its buttons are the failure's
/// ``PlayerErrorMessage/actions``, which ``PlayerSlotState/respond(to:with:)`` handles.
private struct PlayerErrorAlertPresenter: ViewModifier {
    let player: any PlayerSlotState
    let owner: PlayerErrorAlertOwner
    let layer: UUID?
    let isEnabled: Bool
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.appearsActive) private var appearsActive

    func body(content: Content) -> some View {
        let error =
            isEnabled
            ? owner.shownError(
                current: player.errorMessageKey, in: layer, isActive: scenePhase == .active && appearsActive)
            : nil
        // The occurrence it shows, so its buttons can't act on a later failure with the same message.
        let failure = error.flatMap { _ in player.failure }
        content.alert(
            Text(verbatim: failure.map { L10n.string(PlayerSlot.messageKey(for: $0.message)) } ?? ""),
            isPresented: Binding(
                get: { failure != nil },
                set: { if !$0 { owner.dismissedError = player.errorMessageKey } }),
            presenting: failure
        ) { failure in
            ForEach(failure.message.actions, id: \.self) { action in
                Button(role: PlayerSlot.role(for: action)) {
                    Task { await player.respond(to: failure, with: action) }
                } label: {
                    Text(verbatim: L10n.string(PlayerSlot.labelKey(for: action)))
                }
            }
        }
    }
}
