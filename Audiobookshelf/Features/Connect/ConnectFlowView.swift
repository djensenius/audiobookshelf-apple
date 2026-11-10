import ABSAppModel
import ABSUI
import SwiftUI

#if os(macOS)
    import AppKit
#endif

/// The server connect and sign-in flow (#40): saved servers, a new server's address and custom
/// headers, then password or OpenID sign-in. A port of `pages/connect.vue`.
///
/// The app shell's auth gate (#44) shows it while no account is signed in, and Account can
/// show it to add or switch servers:
///
/// ```swift
/// ConnectFlowView(accounts: accounts) {
///     // Signed in: `accounts.activeConnection` and `accounts.client` are set.
/// }
/// ```
///
/// The view owns its ``ConnectViewModel`` for as long as it's shown, so a parent's update
/// doesn't restart the flow, and cancels the work in progress when it disappears, except an
/// OpenID sign-in, whose browser can hide it. `onFinish` runs once, when the model reaches
/// ``ConnectViewModel/Phase/done``. The flow saves nothing itself: ``AccountManager`` stores the
/// connection, session and custom headers.
///
/// Keep the view mounted until `onFinish`: the gate must not switch away on
/// ``AccountState/restoring``, which resuming a saved server passes through. Removing the view
/// cancels the flow, but a resume it started isn't stopped and can still make that account
/// active.
struct ConnectFlowView: View {
    @State private var model: ConnectViewModel
    private let onFinish: () -> Void

    init(accounts: AccountManager, onFinish: @escaping () -> Void = {}) {
        _model = State(initialValue: ConnectViewModel(accounts: accounts))
        self.onFinish = onFinish
    }

    var body: some View {
        ConnectFlowStack(model: model, onFinish: onFinish)
    }
}

/// The flow for a model owned elsewhere: ``ConnectFlowView`` and previews.
struct ConnectFlowStack: View {
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
                                Text(verbatim: L10n.string(model.isBusy ? "ButtonCancel" : "ButtonBack"))
                            }
                        }
                    }
                }
        }
        .onChange(of: model.phase, initial: true) { _, phase in
            if phase == .done { onFinish() }
        }
        // Not during OpenID sign-in: presenting the browser can make the flow disappear.
        .onDisappear { if model.phase != .signingIn(.openID) { model.cancel() } }
        // Back from Settings after turning local network access on.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { retryAfterLocalNetworkDenied() }
        }
        #if os(macOS)
            // The scene phase may stay active while System Settings is in front.
            .task {
                for await _ in NotificationCenter.default.notifications(
                    named: NSApplication.didBecomeActiveNotification)
                {
                    retryAfterLocalNetworkDenied()
                }
            }
        #endif
    }

    private func retryAfterLocalNetworkDenied() {
        guard model.failure == .localNetworkDenied else { return }
        Task { await model.retry() }
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
