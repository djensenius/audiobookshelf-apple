import ABSAPI
import ABSCore
import ABSData
import Foundation
import Observation

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
    /// Whether the session the flow was opened from has ended, so its sign-ins are refused.
    var originHasEnded: Bool { get }
}

extension ConnectBackend {
    public var originHasEnded: Bool { false }
}

/// The app's ``ConnectBackend``: validates with ``ServerValidator`` and signs in through
/// ``AccountManager``, which saves the session and the custom headers.
///
/// With a `lifecycle` (adding a server while signed in), a sign-in or resume is an account change
/// (``SessionLifecycle/performAccountChange(from:_:)``) from the session the sheet opened on, and
/// a removal goes through ``SessionLifecycle/removeAccount(_:)``. Resuming the active connection
/// or a signed-out one ends nothing. The change starts before the server checks the credentials,
/// so a wrong password still restarts the running session; checking first is a follow-up.
@Observable final class AccountConnectBackend: ConnectBackend {
    let accounts: AccountManager
    private let validator: ServerValidator
    private let lifecycle: SessionLifecycle?
    /// The session the sheet was opened from; after a change of its own, the one it left running.
    private var origin: ReadySession?
    /// Whether a change of its own runs, until its transition ends, even if the flow cancelled it.
    private var isChanging = false

    init(accounts: AccountManager, validator: ServerValidator = ServerValidator(), lifecycle: SessionLifecycle? = nil) {
        self.accounts = accounts
        self.validator = validator
        self.lifecycle = lifecycle
        origin = lifecycle?.readySession
    }

    var connections: [ServerConnectionDTO] { accounts.connections }
    var originHasEnded: Bool { !isChanging && lifecycle.map { $0.readySession != origin } ?? false }

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
            // Skips the session source's removal effects (`onRemoved` in the app). The app always
            // passes a lifecycle; only previews and tests don't.
            _ = try await accounts.remove(id)
        }
    }

    private func changingAccount(_ body: @MainActor () async throws -> Void) async throws {
        guard let lifecycle else { return try await body() }
        // Refused, silently as a cancel, unless the sheet's session is ready now and still
        // running at the change's turn: another window may have switched since the sheet opened.
        guard let origin, lifecycle.readySession == origin else { throw CancellationError() }
        var ran = true  // Unless refused; `body` may throw.
        isChanging = true
        defer {
            if ran { self.origin = lifecycle.readySession }
            isChanging = false
        }
        ran = try await lifecycle.performAccountChange(from: origin, body)
        guard ran else { throw CancellationError() }
    }

    private static func validated(_ server: ConnectServer) throws -> ValidatedServer {
        guard let validated = server.validated else { throw ServerValidationError.invalidAddress }
        return validated
    }
}
