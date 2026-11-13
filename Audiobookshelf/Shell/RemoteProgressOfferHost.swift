import ABSAppModel
import ABSCore
import ABSUI
import SwiftUI

extension EnvironmentValues {
    /// The "Jump to latest position" offer (#59), or `nil` without the realtime socket.
    @Entry var remoteProgressOffer: RemoteProgressOffer?
}

/// Asks whether to jump to another session's newer position for the paused item
/// (``RemoteProgressOffer``). Like the player's failures (``PlayerErrorAlertOwner``), the alert
/// shows only in the active window; the offer is shared, so answering it in one window ends it in
/// all of them.
struct RemoteProgressOfferHost: ViewModifier {
    @Environment(\.remoteProgressOffer) private var model
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.appearsActive) private var appearsActive

    func body(content: Content) -> some View {
        let offer = scenePhase == .active && appearsActive ? model?.shown : nil
        content.alert(
            Text(verbatim: L10n.string("HeaderRemoteProgressOffer")),
            isPresented: Binding(
                get: { offer != nil },
                // Both buttons end the offer themselves; the alert's own reset may come before the
                // tapped button's action, so it mustn't dismiss.
                set: { _ in }),
            presenting: offer
        ) { _ in
            Button {
                model?.accept()
            } label: {
                Text(verbatim: L10n.string("ButtonJumpToLatestPosition"))
            }
            Button(role: .cancel) {
                model?.dismiss()
            } label: {
                Text(verbatim: L10n.string("ButtonKeepCurrentPosition"))
            }
        } message: { offer in
            Text(verbatim: Self.message(for: offer))
        }
    }

    static func message(for offer: RemoteProgressOffer.Pending) -> String {
        let position = TimeFormatting.timestamp(offer.position)
        if let device = offer.deviceDescription, !device.isEmpty {
            return L10n.string("MessageRemoteProgressOfferFromDevice", device, position)
        }
        return L10n.string("MessageRemoteProgressOffer", position)
    }
}
