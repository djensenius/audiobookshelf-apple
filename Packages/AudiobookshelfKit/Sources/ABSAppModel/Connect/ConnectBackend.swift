import ABSAPI
import ABSCore
import ABSData
import Foundation

/// A server whose `/status` was read, ready to sign in to.
public struct ConnectServer: Sendable {
    /// The address the status was served from, which may differ from what was typed (a scheme
    /// was added, or a same-host redirect was followed).
    public let address: ServerAddress
    public let status: ServerStatus
    /// `nil` only for fakes in tests and previews.
    let validated: ValidatedServer?

    init(_ validated: ValidatedServer) {
        address = validated.address
        status = validated.status
        self.validated = validated
    }

    /// A server for fake ``ConnectBackend``s. The app's backend can't sign in to it.
    public init(address: ServerAddress, status: ServerStatus) {
        self.address = address
        self.status = status
        validated = nil
    }
}

/// What ``ConnectViewModel`` needs from ``ServerValidator`` and ``AccountManager``. The app uses
/// ``ConnectViewModel/init(accounts:validator:localNetwork:lifecycle:)``; tests and previews use fakes.
@MainActor
public protocol ConnectBackend {
    /// Saved connections, most recently used first.
    var connections: [ServerConnectionDTO] { get }
    /// Reads `/status` at the typed address with the custom headers.
    func validate(address: String, customHeaders: [String: String]) async throws -> ConnectServer
    func signIn(to server: ConnectServer, username: String, password: String) async throws
    func signIn(openIDTo server: ConnectServer, authenticator: any WebAuthenticator) async throws
    /// Makes a saved connection active with its saved session. Returns `false` if it has no
    /// session, was signed out (`signedOutAt`), or the session has expired, so the user must sign
    /// in again.
    func resume(_ id: UUID) async throws -> Bool
    /// The custom headers saved for a connection.
    func customHeaders(for id: UUID) async throws -> [String: String]
    func remove(_ id: UUID) async throws
}

/// The app's ``ConnectBackend``: validates with ``ServerValidator`` and signs in through
/// ``AccountManager``, which saves the session and the custom headers.
///
/// With a `lifecycle`, the flow runs while signed in (adding a server from the Account tab): a
/// sign-in or resume is an account change (``SessionLifecycle/performAccountChange(_:)``), so the
/// running session ends first, and the other accounts keep their sessions; a removal goes
/// through ``SessionLifecycle/removeAccount(_:)``. Resuming the active connection changes
/// nothing, and a signed-out one goes straight to the login step, so neither ends the running
/// session.
///
/// The account change starts before the server checks the credentials, so a wrong password or
/// a cancelled OpenID sign-in still ends the running session (and its playback), which then
/// starts again. Checking first needs `AccountManager` to sign in before it activates; that is
/// a follow-up.
struct AccountConnectBackend: ConnectBackend {
    let accounts: AccountManager
    private let validator: ServerValidator
    private let lifecycle: SessionLifecycle?

    init(accounts: AccountManager, validator: ServerValidator = ServerValidator(), lifecycle: SessionLifecycle? = nil) {
        self.accounts = accounts
        self.validator = validator
        self.lifecycle = lifecycle
    }

    var connections: [ServerConnectionDTO] { accounts.connections }

    func validate(address: String, customHeaders: [String: String]) async throws -> ConnectServer {
        ConnectServer(try await validator.validate(address: address, customHeaders: customHeaders))
    }

    func signIn(to server: ConnectServer, username: String, password: String) async throws {
        let server = try Self.validated(server)
        try await changingAccount {
            try await accounts.connect(local: server, username: username, password: password)
        }
    }

    func signIn(openIDTo server: ConnectServer, authenticator: any WebAuthenticator) async throws {
        let server = try Self.validated(server)
        try await changingAccount { try await accounts.connect(oidc: server, authenticator: authenticator) }
    }

    func resume(_ id: UUID) async throws -> Bool {
        if lifecycle != nil {
            if id == accounts.activeConnection?.id { return true }
            if accounts.connections.first(where: { $0.id == id })?.signedOutAt != nil { return false }
        }
        do {
            try await changingAccount { try await accounts.switch(to: id) }
        } catch AccountError.notSignedIn {
            return false
        }
        // Offline counts as resumed: the session is kept and reconnects later.
        if accounts.activeConnection?.id == id, accounts.state.user != nil { return true }
        if let error = accounts.lastError, error != .server(.sessionExpired) { throw error }
        return false
    }

    func customHeaders(for id: UUID) async throws -> [String: String] {
        try await accounts.customHeaders(for: id)
    }

    func remove(_ id: UUID) async throws {
        // An OpenID end-session URL isn't opened from the connect screen.
        if let lifecycle {
            _ = try await lifecycle.removeAccount(id)
        } else {
            _ = try await accounts.remove(id)
        }
    }

    private func changingAccount(_ body: @MainActor () async throws -> Void) async throws {
        if let lifecycle {
            try await lifecycle.performAccountChange(body)
        } else {
            try await body()
        }
    }

    private static func validated(_ server: ConnectServer) throws -> ValidatedServer {
        guard let validated = server.validated else { throw ServerValidationError.invalidAddress }
        return validated
    }
}
