import ABSAppModel
import ABSUI
import SwiftUI

#if os(macOS)
    import AppKit
#endif

/// The server connect and sign-in flow (#40): saved servers, a new server's address and custom
/// headers, then password or OpenID sign-in. A port of `pages/connect.vue`.
///
/// The app shell's auth gate shows it while no account is signed in:
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
/// The gate must not switch away on
/// ``AccountState/restoring``, which resuming a saved server passes through. Removing the view
/// cancels the flow, but a resume it started isn't stopped and can still make that account
/// active.
///
/// While signed in (adding a server from the server list), pass the `lifecycle`: each sign-in is
/// then a lifecycle-managed account change, which keeps the other accounts' sessions. The flow
/// starts at a new server's address, and `onCancel` adds a Cancel button where there's no Back.
struct ConnectFlowView: View {
    @State private var model: ConnectViewModel
    private let lifecycle: SessionLifecycle?
    private let onFinish: () -> Void
    private let onCancel: (() -> Void)?

    init(
        accounts: AccountManager, lifecycle: SessionLifecycle? = nil, onCancel: (() -> Void)? = nil,
        onFinish: @escaping () -> Void = {}
    ) {
        let model = ConnectViewModel(accounts: accounts, lifecycle: lifecycle)
        if lifecycle != nil { model.startAddingServer() }
        _model = State(initialValue: model)
        self.lifecycle = lifecycle
        self.onFinish = onFinish
        self.onCancel = onCancel
    }

    var body: some View {
        // While another window's account change runs, nothing here may start one; its own
        // sign-in moves the gate off ready too, so that only counts when idle.
        ConnectFlowStack(
            model: model, onFinish: onFinish, onCancel: onCancel,
            isEnabled: model.isBusy || lifecycle?.acceptsAccountChanges != false
        )
        // In the add-server sheet, a sign-in (an OpenID one waits for the browser) keeps running
        // when the stack disappears; Cancel stops it, so a swipe can't dismiss the sheet meanwhile.
        .interactiveDismissDisabled(model.isBusy)
    }
}

/// The flow for a model owned elsewhere: ``ConnectFlowView`` and previews.
struct ConnectFlowStack: View {
    let model: ConnectViewModel
    var onFinish: () -> Void = {}
    var onCancel: (() -> Void)?
    /// Whether the steps' controls take input; the toolbar's Back and Cancel always do.
    var isEnabled = true
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack {
            content
                .disabled(!isEnabled)
                .navigationTitle(Text(verbatim: title))
                .toolbar {
                    DiagnosticsToolbar()
                    if model.canGoBack {
                        ToolbarItem(placement: .cancellationAction) {
                            Button {
                                model.goBack()
                            } label: {
                                Text(verbatim: L10n.string(model.isBusy ? "ButtonCancel" : "ButtonBack"))
                            }
                        }
                    } else if let onCancel, !model.isBusy {
                        ToolbarItem(placement: .cancellationAction) {
                            Button(action: onCancel) {
                                Text(verbatim: L10n.string("ButtonCancel"))
                            }
                        }
                    }
                }
                .navigationDestination(for: Route.self) { RouteDestination(route: $0) }
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
