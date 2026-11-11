import ABSAppModel
import ABSData
import ABSUI
import SwiftUI

/// The Account tab, a port of `pages/account.vue`: who is signed in to which server, switching
/// servers, signing out, and the entry points to Logs and (on iOS; a Mac has the Settings
/// window) Settings. Reads the accounts and the lifecycle from the environment (`RootView`).
struct AccountView: View {
    @Environment(AccountManager.self) private var accounts: AccountManager?
    @Environment(SessionLifecycle.self) private var lifecycle: SessionLifecycle?
    @Environment(\.openURL) private var openURL
    @State private var isSigningOut = false

    var body: some View {
        Form {
            if let user = accounts?.state.user {
                Section {
                    row("LabelUsername", value: user.username)
                    row("LabelHost", value: user.serverAddress)
                    if let version = user.serverVersion {
                        row("LabelServerVersion", value: version)
                    }
                }
            }
            Section {
                NavigationLink(value: Route.servers) {
                    label("ButtonSwitchServerUser", systemImage: "server.rack")
                }
                if let lifecycle {
                    Button(role: .destructive) {
                        if AccountActions(lifecycle: lifecycle).signOut(openURL: { openURL($0) }) != nil {
                            isSigningOut = true
                        }
                    } label: {
                        label("ButtonLogout", systemImage: "rectangle.portrait.and.arrow.right")
                    }
                    .disabled(isSigningOut || !lifecycle.acceptsAccountChanges)
                }
            }
            Section {
                #if os(iOS)
                    NavigationLink(value: Route.settings) {
                        label("HeaderSettings", systemImage: "gearshape")
                    }
                #endif
                NavigationLink(value: Route.logs) {
                    label("ButtonLogs", systemImage: "doc.text.magnifyingglass")
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(Text(verbatim: L10n.string(AppTab.account.titleKey)))
    }

    private func row(_ titleKey: String, value: String) -> some View {
        LabeledContent {
            Text(verbatim: value)
                .textSelection(.enabled)
        } label: {
            Text(verbatim: L10n.string(titleKey))
        }
    }

    private func label(_ titleKey: String, systemImage: String) -> some View {
        Label {
            Text(verbatim: L10n.string(titleKey))
        } icon: {
            Image(systemName: systemImage)
        }
    }
}

/// The saved server connections (`Route.servers`): selecting another one switches to it through
/// the session lifecycle. Adding a server signs in to it with the connect flow in a sheet, as an
/// account change, so the account signed in now keeps its session to switch back to.
struct ServersView: View {
    @Environment(AccountManager.self) private var accounts: AccountManager?
    @Environment(SessionLifecycle.self) private var lifecycle: SessionLifecycle?
    @State private var switchingTo: UUID?
    @State private var switchFailed = false
    @State private var isAddingServer = false

    var body: some View {
        Form {
            Section {
                ForEach(accounts?.connections ?? []) { server in
                    let isActive = server.id == accounts?.activeConnection?.id
                    Button {
                        switchServer(to: server.id)
                    } label: {
                        row(server, isActive: isActive)
                    }
                    .disabled(
                        isActive || switchingTo != nil || server.signedOutAt != nil
                            || lifecycle?.acceptsAccountChanges != true
                    )
                    .accessibilityAddTraits(isActive ? .isSelected : [])
                }
            }
            Section {
                Button {
                    isAddingServer = true
                } label: {
                    Label {
                        Text(verbatim: L10n.string("ButtonAddNewServer"))
                    } icon: {
                        Image(systemName: "plus")
                    }
                }
                .disabled(switchingTo != nil || lifecycle?.acceptsAccountChanges != true)
            }
        }
        .formStyle(.grouped)
        .navigationTitle(Text(verbatim: L10n.string("HeaderServers")))
        .switchServerFailedAlert(isPresented: $switchFailed)
        .sheet(isPresented: $isAddingServer) {
            if let accounts, let lifecycle {
                // Signing in replaces the shell, and this sheet with it.
                ConnectFlowView(
                    accounts: accounts, lifecycle: lifecycle, onCancel: { isAddingServer = false },
                    onFinish: { isAddingServer = false })
            }
        }
    }

    private func switchServer(to id: UUID) {
        // Two quick taps on different rows must not queue two switches.
        guard switchingTo == nil, let lifecycle,
            let task = AccountActions(lifecycle: lifecycle).switchAccount(to: id)
        else { return }
        switchingTo = id
        // On success the shell is replaced; on failure this screen stays, so let it retry.
        Task {
            if await !task.value {
                switchingTo = nil
                switchFailed = true
            }
        }
    }

    private func row(_ server: ServerConnectionDTO, isActive: Bool) -> some View {
        HStack {
            VStack(alignment: .leading) {
                Text(verbatim: server.address)
                    .foregroundStyle(.primary)
                Text(verbatim: server.username)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if switchingTo == server.id {
                ProgressView()
                    .controlSize(.small)
            } else if isActive {
                Image(systemName: "checkmark")
                    .foregroundStyle(.tint)
            } else if server.signedOutAt != nil {
                Text(verbatim: L10n.string("LabelLoggedOut"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .contentShape(.rect)
    }
}

#Preview("Account") {
    NavigationStack {
        AccountView()
            .navigationDestination(for: Route.self) { RouteDestination(route: $0) }
    }
}

#Preview("Servers") {
    NavigationStack { ServersView() }
}
