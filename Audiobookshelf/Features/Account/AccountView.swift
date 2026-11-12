import ABSAppModel
import ABSData
import ABSUI
import SwiftUI

/// The Account tab (`pages/account.vue`): the signed-in user and server, switching, signing out,
/// Logs and (on iOS) Settings. Reads the accounts and lifecycle from the environment (`RootView`).
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
                        guard
                            let task = AccountActions(lifecycle: lifecycle, accounts: accounts).signOut(openURL: {
                                openURL($0)
                            })
                        else { return }
                        isSigningOut = true
                        // Only while it runs: the lifecycle can refuse it (another window's change
                        // left this account first), and this screen may then stay.
                        Task {
                            await task.value
                            isSigningOut = false
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

/// The saved servers (`Route.servers`): selecting one switches through the lifecycle; adding one
/// signs in with the connect flow in a sheet, keeping the current account's session. Servers other
/// than the running one can be removed, after a confirmation: swipe to delete or Edit on iOS, and
/// the context menu everywhere (``AccountActions/canRemove(_:)``). Log Out covers the running one.
struct ServersView: View {
    @Environment(AccountManager.self) private var accounts: AccountManager?
    @Environment(SessionLifecycle.self) private var lifecycle: SessionLifecycle?
    @State private var switchingTo: UUID?
    @State private var switchFailed = false
    @State private var switchFailure = SwitchFailure.other
    @State private var isAddingServer = false
    /// The server waiting for the removal confirmation.
    @State private var pendingRemoval: ServerConnectionDTO?
    /// A removal in flight, so no switch or other removal starts meanwhile.
    @State private var isRemoving = false
    @State private var removeFailed = false
    #if os(iOS)
        /// Owned here so the list leaves edit mode once nothing is removable.
        @State private var editMode = EditMode.inactive

        /// Whether Edit shows: ``AccountActions/offersRemoval(among:activeID:)``.
        private var offersRemoval: Bool {
            AccountActions.offersRemoval(
                among: (accounts?.connections ?? []).map(\.id), activeID: accounts?.activeConnection?.id)
        }
    #endif
    /// Whether each connection has a saved session to switch to (``AccountManager/hasSession(_:)``).
    @State private var hasSession: [UUID: Bool] = [:]

    var body: some View {
        let servers = accounts?.connections ?? []
        Form {
            Section {
                ForEach(servers) { server in
                    let isActive = server.id == accounts?.activeConnection?.id
                    Button {
                        switchServer(to: server.id)
                    } label: {
                        row(server, isActive: isActive)
                    }
                    .disabled(
                        isActive || switchingTo != nil || isRemoving || hasSession[server.id] != true
                            || lifecycle?.acceptsAccountChanges != true
                    )
                    .accessibilityAddTraits(isActive ? .isSelected : [])
                    .contextMenu {
                        if canRemove(server) {
                            Button(role: .destructive) {
                                pendingRemoval = server
                            } label: {
                                Label {
                                    Text(verbatim: L10n.string("ButtonRemove"))
                                } icon: {
                                    Image(systemName: "trash")
                                }
                            }
                        }
                    }
                    .deleteDisabled(!canRemove(server))
                }
                // Swipe to delete, and Edit's delete buttons; both ask first.
                .onDelete { offsets in
                    pendingRemoval = offsets.first.map { servers[$0] }.flatMap { canRemove($0) ? $0 : nil }
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
                .disabled(switchingTo != nil || isRemoving || lifecycle?.acceptsAccountChanges != true)
            }
        }
        .formStyle(.grouped)
        .navigationTitle(Text(verbatim: L10n.string("HeaderServers")))
        #if os(iOS)
            .toolbar {
                // Shown by the list's structure, never hidden mid-edit; a plain Button, as it
                // toggles the edit mode owned here.
                if offersRemoval {
                    Button {
                        withAnimation { editMode = editMode.isEditing ? .inactive : .active }
                    } label: {
                        Text(verbatim: L10n.string(editMode.isEditing ? "ButtonDone" : "ButtonEdit"))
                    }
                    .disabled(
                        !editMode.isEditing
                            && (switchingTo != nil || isRemoving || lifecycle?.acceptsAccountChanges != true))
                }
            }
            .environment(\.editMode, $editMode)
            .onChange(of: offersRemoval) { _, offers in
                if !offers { withAnimation { editMode = .inactive } }
            }
        #endif
        .switchServerFailedAlert(isPresented: $switchFailed, failure: switchFailure)
        .confirmationDialog(
            Text(verbatim: L10n.string("MessageConfirmDeleteServerConfig")),
            isPresented: Binding {
                pendingRemoval != nil
            } set: {
                if !$0 { pendingRemoval = nil }
            },
            titleVisibility: .visible, presenting: pendingRemoval
        ) { server in
            Button(role: .destructive) {
                remove(server)
            } label: {
                Text(verbatim: L10n.string("ButtonRemove"))
            }
        } message: { server in
            Text(verbatim: L10n.string("MessageRemoveServerAccount", server.username, server.address))
        }
        .alert(Text(verbatim: L10n.string("MessageRemoveServerFailed")), isPresented: $removeFailed) {
            Button(L10n.string("ButtonOk")) {}
        }
        .task(id: accounts?.connections) {
            guard let accounts else { return }
            var sessions: [UUID: Bool] = [:]
            for server in accounts.connections { sessions[server.id] = await accounts.hasSession(server.id) }
            // A newer run, for newer connections, writes its own.
            guard !Task.isCancelled else { return }
            hasSession = sessions
        }
        .sheet(isPresented: $isAddingServer) {
            if let accounts, let lifecycle {
                // Signing in replaces the shell, and this sheet with it.
                ConnectFlowView(
                    accounts: accounts, lifecycle: lifecycle, onCancel: { isAddingServer = false },
                    onFinish: { isAddingServer = false })
            }
        }
    }

    /// Whether `server` offers removal now: not the running server, nor while a switch, here or in
    /// another window, or a removal runs.
    private func canRemove(_ server: ServerConnectionDTO) -> Bool {
        guard let lifecycle, switchingTo == nil, !isRemoving else { return false }
        return AccountActions(lifecycle: lifecycle, accounts: accounts).canRemove(server.id)
    }

    /// Removes `server` once confirmed, unless that's no longer allowed: a switch may have started
    /// while the dialog was open.
    private func remove(_ server: ServerConnectionDTO) {
        guard canRemove(server), let lifecycle,
            let task = AccountActions(lifecycle: lifecycle, accounts: accounts).removeServer(server.id)
        else { return }
        isRemoving = true
        Task {
            if await !task.value { removeFailed = true }
            isRemoving = false
        }
    }

    private func switchServer(to id: UUID) {
        // Two quick taps on different rows must not queue two switches.
        guard switchingTo == nil, let lifecycle,
            let task = AccountActions(lifecycle: lifecycle, accounts: accounts).switchAccount(to: id)
        else { return }
        switchingTo = id
        // On success the shell is replaced; on failure this screen stays, so let it retry.
        Task {
            if case .failed(let failure) = await task.value {
                switchingTo = nil
                switchFailure = failure
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
            } else if hasSession[server.id] == false {
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
