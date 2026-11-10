import ABSAppModel
import ABSUI
import SwiftUI

/// The server connect and sign-in flow (#40): saved servers, a new server's address and custom
/// headers, then password or OpenID sign-in. A port of `pages/connect.vue`.
///
/// The app shell's auth gate (#44) shows it while no account is signed in, and Account can
/// show it to add or switch servers:
///
/// ```swift
/// ConnectFlowView(model: ConnectViewModel(accounts: accounts)) {
///     // Signed in: `accounts.activeConnection` and `accounts.client` are set.
/// }
/// ```
///
/// `onFinish` runs once, when the model reaches ``ConnectViewModel/Phase/done``. The flow saves
/// nothing itself: ``AccountManager`` stores the connection, session and custom headers.
struct ConnectFlowView: View {
    let model: ConnectViewModel
    var onFinish: () -> Void = {}
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(Text(verbatim: title))
                .toolbar {
                    if model.canGoBack {
                        ToolbarItem(placement: .cancellationAction) {
                            Button {
                                model.goBack()
                            } label: {
                                Text(verbatim: L10n.string("ButtonBack"))
                            }
                        }
                    }
                }
        }
        .onChange(of: model.phase, initial: true) { _, phase in
            if phase == .done { onFinish() }
        }
        // Back from Settings after turning local network access on.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active, model.failure == .localNetworkDenied {
                Task { await model.retry() }
            }
        }
    }

    @ViewBuilder private var content: some View {
        switch model.phase {
        case .servers, .signingIn(.savedSession):
            ServerListView(model: model)
        case .address, .validating:
            ServerAddressView(model: model)
        case .login, .signingIn(.password), .signingIn(.openID):
            LoginView(model: model)
        case .done:
            ProgressView()
        }
    }

    private var title: String {
        switch model.phase {
        case .servers, .signingIn(.savedSession), .done: L10n.string("HeaderServers")
        case .address, .validating: L10n.string("HeaderAddServer")
        case .login, .signingIn: L10n.string("HeaderLogin")
        }
    }
}

// MARK: - Previews

#Preview("First server") {
    ConnectPreview()
}
