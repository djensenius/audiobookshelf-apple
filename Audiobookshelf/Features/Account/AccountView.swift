import ABSAppModel
import ABSCore
import ABSData
import ABSUI
import SwiftUI

/// The Account tab (`pages/account.vue`, `SideDrawer.vue`): the signed-in user, their type and
/// server, with a warning for a server older than the app supports; switching and signing out,
/// after a confirmation; Stats, Logs and (on iOS) Settings; and the app's version, repository and
/// license. Reads the accounts and lifecycle from the environment (`RootView`).
struct AccountView: View {
    @Environment(AccountManager.self) private var accounts: AccountManager?
    @Environment(SessionLifecycle.self) private var lifecycle: SessionLifecycle?
    @Environment(\.openURL) private var openURL
    @State private var isSigningOut = false
    /// The session the Log Out confirmation was opened from, while it shows; signing out names it,
    /// so the lifecycle refuses a confirmation that outlived it (say, another window's failed
    /// switch restarted the account).
    @State private var signOutOrigin: ReadySession?

    /// The legacy app's repository (`pages/account.vue`, `pages/connect.vue`) and its license.
    private static let repositoryURL = URL(string: "https://github.com/advplyr/audiobookshelf-app")
    private static let licenseURL = URL(string: "https://github.com/advplyr/audiobookshelf-app/blob/master/LICENSE")

    var body: some View {
        Form {
            if let user = accounts?.state.user {
                Section {
                    row("LabelUsername", value: user.username)
                    if let type = userType(of: user) {
                        row("LabelAccountType", value: type)
                    }
                    row("LabelHost", value: user.serverAddress)
                    if let version = user.serverVersion {
                        row("LabelServerVersion", value: version)
                    }
                    if let warning = AccountDetails.serverVersionWarning(user.serverVersion) {
                        Label {
                            Text(verbatim: warning.message)
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(ABSColor.warning)
                        }
                        .font(.footnote)
                    }
                }
            }
            Section {
                NavigationLink(value: Route.servers) {
                    label("ButtonSwitchServerUser", systemImage: "server.rack")
                }
                if let lifecycle {
                    Button(role: .destructive) {
                        signOutOrigin = lifecycle.readySession
                    } label: {
                        label("ButtonLogout", systemImage: "rectangle.portrait.and.arrow.right")
                    }
                    .disabled(isSigningOut || !lifecycle.acceptsAccountChanges)
                }
            }
            Section {
                NavigationLink(value: Route.stats) {
                    label("ButtonUserStats", systemImage: "chart.bar")
                }
                #if os(iOS)
                    NavigationLink(value: Route.settings) {
                        label("HeaderSettings", systemImage: "gearshape")
                    }
                #endif
                NavigationLink(value: Route.logs) {
                    label("ButtonLogs", systemImage: "doc.text.magnifyingglass")
                }
            }
            Section {
                if let version = AccountDetails.appVersion(infoDictionary: Bundle.main.infoDictionary) {
                    row("LabelAppVersion", value: version)
                }
                if let repositoryURL = Self.repositoryURL {
                    Link(destination: repositoryURL) {
                        label("MessageFollowTheProjectOnGithub", systemImage: "chevron.left.forwardslash.chevron.right")
                    }
                }
                if let licenseURL = Self.licenseURL {
                    Link(destination: licenseURL) {
                        label("LabelLicenseGPL", systemImage: "doc.plaintext")
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(Text(verbatim: L10n.string(AppTab.account.titleKey)))
        .confirmationDialog(
            Text(verbatim: L10n.string("MessageConfirmLogout")), isPresented: isConfirmingSignOut,
            titleVisibility: .visible, presenting: signOutOrigin
        ) { origin in
            Button(role: .destructive) {
                signOut(from: origin)
            } label: {
                Text(verbatim: L10n.string("ButtonLogout"))
            }
        }
    }

    /// The user's type, when the authorization is this user's (it isn't offline): its label, or
    /// the server's value for a type this client doesn't know.
    private func userType(of user: AccountUser) -> String? {
        guard let authorized = accounts?.authorization?.user, authorized.id == user.userId else { return nil }
        return AccountDetails.userTypeKey(authorized.type).map { L10n.string($0) } ?? authorized.type.rawValue
    }

    /// Whether the Log Out confirmation shows: while it has the session it was opened from.
    private var isConfirmingSignOut: Binding<Bool> {
        Binding(get: { signOutOrigin != nil }, set: { if !$0 { signOutOrigin = nil } })
    }

    /// Signs out of `origin`, the session the confirmation was opened from. The lifecycle does
    /// nothing if that session has ended or restarted since, so a stale confirmation can't sign
    /// out the session that replaced it.
    private func signOut(from origin: ReadySession) {
        guard !isSigningOut, let lifecycle else { return }
        let actions = AccountActions(lifecycle: lifecycle, accounts: accounts)
        isSigningOut = true
        // Only while it runs: the lifecycle can refuse it (another window's change left this
        // session first), and this screen may then stay.
        Task {
            await actions.signOut(from: origin) { openURL($0) }
            isSigningOut = false
        }
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

    /// What ``hasSession`` is read again for: the connections, or a saved session stored, deleted
    /// or found expired without the list changing (an inactive account's expiry).
    struct SessionsKey: Equatable {
        let connections: [ServerConnectionDTO]
        let credentialsRevision: Int

        @MainActor init(_ accounts: AccountManager) {
            connections = accounts.connections
            credentialsRevision = accounts.credentialsRevision
        }
    }

    /// Whether each of `accounts`' connections has a saved session, for ``hasSession``.
    static func sessions(of accounts: AccountManager) async -> [UUID: Bool] {
        var sessions: [UUID: Bool] = [:]
        for server in accounts.connections { sessions[server.id] = await accounts.hasSession(server.id) }
        return sessions
    }

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
        .task(id: accounts.map(SessionsKey.init)) {
            guard let accounts else { return }
            let sessions = await Self.sessions(of: accounts)
            // A newer run, for newer connections or credentials, writes its own.
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

extension ServerVersionWarning {
    /// The warning's text: the connect screen's messages for an unsupported or unknown version.
    var message: String {
        switch self {
        case .tooOld(let version, let minimum):
            L10n.string("MessageConnectUnsupportedVersion", version, minimum.description)
        case .unknownVersion(let minimum): L10n.string("MessageConnectUnknownVersion", minimum.description)
        }
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
