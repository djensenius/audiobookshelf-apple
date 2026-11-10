import ABSAPI
import ABSCore
import ABSData
import Foundation
import Observation

/// The signed-in user, as saved with the connection, so it's available offline.
public struct AccountUser: Sendable, Hashable, Identifiable {
    public var id: UUID { connectionID }
    public let connectionID: UUID
    /// The normalized server address.
    public let serverAddress: String
    public let userId: String
    public let username: String
    public let authMethod: ServerAuthMethod
    public let serverVersion: String?

    init(_ connection: ServerConnectionDTO) {
        connectionID = connection.id
        serverAddress = connection.address
        userId = connection.userId
        username = connection.username
        authMethod = connection.authMethod
        serverVersion = connection.serverVersion
    }
}

public enum AccountState: Sendable, Hashable {
    case signedOut
    /// Restoring the saved session or switching to another connection.
    case restoring
    case signedIn(AccountUser)
    /// Signed in with saved tokens, but the server couldn't be reached; see
    /// ``AccountManager/lastError``.
    case offline(AccountUser)

    public var user: AccountUser? {
        switch self {
        case .signedIn(let user), .offline(let user): user
        case .signedOut, .restoring: nil
        }
    }
}

public enum AccountError: Error, Sendable, Hashable, LocalizedError {
    /// No saved connection has this id.
    case connectionNotFound
    /// The connection has no saved session; sign in to it again.
    case notSignedIn

    // TODO: Localise these messages once ABSAppModel has string catalogs.
    public var errorDescription: String? {
        switch self {
        case .connectionNotFound: "This server is no longer saved."
        case .notSignedIn: "You're signed out of this server. Sign in again."
        }
    }
}

/// Signs in to servers, restores the saved session at launch, and owns the active connection's
/// ``APIClient``.
///
/// Connections are saved through ``ServerConnectionStore``. Tokens, the OpenID sign-out cookies
/// and the custom headers are in the Keychain under the connection's id, never in the store.
/// The active client gets its tokens from a ``TokenProvider`` that saves refreshed tokens; when
/// the server rejects the refresh token, the state returns to ``AccountState/signedOut`` with
/// ``lastError`` set to ``ServerValidationError/sessionExpired``. Only the tokens are deleted;
/// the connection and its custom headers stay saved for signing in again.
///
/// Each call supersedes the ones still running: a superseded call leaves the state to the newer
/// one.
@MainActor @Observable
public final class AccountManager {
    public private(set) var state: AccountState = .signedOut
    /// Saved connections, most recently used first. Removed connections that are kept for their
    /// local data aren't listed.
    public private(set) var connections: [ServerConnectionDTO] = []
    /// The active connection, set while signed in, offline or restoring.
    public private(set) var activeConnection: ServerConnectionDTO?
    /// The active connection's client, set while signed in, offline or restoring.
    public private(set) var client: APIClient?
    /// The latest sign-in or authorize response, without its tokens; `nil` offline.
    public private(set) var authorization: AuthResponse?
    public private(set) var features: ServerFeatures?
    /// Why the last restore or switch ended signed out or offline, or why the session expired.
    public private(set) var lastError: ServerValidationError?

    @ObservationIgnored private let store: ServerConnectionStore
    @ObservationIgnored private let vault: CredentialVault
    @ObservationIgnored private let validator: ServerValidator
    @ObservationIgnored private let openID: OIDCLoginService
    @ObservationIgnored private let sessionConfiguration: @Sendable () -> URLSessionConfiguration
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private var credentials: [UUID: ConnectionCredentials] = [:]
    /// The credentials generation of each connection's latest sign-in in this process.
    @ObservationIgnored private var signInGenerations: [UUID: Int] = [:]
    @ObservationIgnored private var operation = 0

    /// - Parameters:
    ///   - keychain: The app passes `KeychainStore()`; tests pass a fake.
    ///   - sessionConfiguration: Tests return a configuration with stub protocol classes.
    public init(
        store: ServerConnectionStore,
        keychain: any KeychainStoring,
        validator: ServerValidator = ServerValidator(),
        openID: OIDCLoginService = OIDCLoginService(),
        sessionConfiguration: @escaping @Sendable () -> URLSessionConfiguration = { .absConnection() },
        now: @escaping @Sendable () -> Date = { .now }
    ) {
        self.store = store
        vault = CredentialVault(keychain: keychain)
        self.validator = validator
        self.openID = openID
        self.sessionConfiguration = sessionConfiguration
        self.now = now
    }

    // MARK: - Sign-in

    /// Signs in to `server` with a username and password and makes it the active connection.
    /// On failure the state is unchanged.
    public func connect(local server: ValidatedServer, username: String, password: String) async throws {
        let result = try await validator.login(to: server, username: username, password: password)
        try await finishSignIn(result, to: server, method: .local)
    }

    /// Signs in to `server` through its OpenID provider and makes it the active connection.
    /// On failure the state is unchanged.
    public func connect(oidc server: ValidatedServer, authenticator: any WebAuthenticator) async throws {
        let result = try await openID.login(to: server, using: authenticator)
        try await finishSignIn(result, to: server, method: .openid)
    }

    private func finishSignIn(_ result: LoginResult, to server: ValidatedServer, method: ServerAuthMethod) async throws
    {
        let operation = begin()
        let session = StoredSession(tokens: result.tokens, openIDSession: result.openIDSession)
        var isSaved = false
        do {
            let connection = try await store.upsertLogin(
                address: server.address, userId: result.response.user.id, username: result.response.user.username,
                authMethod: method, serverVersion: result.response.serverSettings?.version, now: now())
            let credentials = self.credentials(for: connection.id)
            signInGenerations[connection.id] = try await credentials.signIn(
                session, customHeaders: server.configuration.customHeaders)
            isSaved = true
            await reloadConnections()
            // Superseded after saving: the connection stays signed in for switching to later.
            guard isCurrent(operation) else { throw CancellationError() }
            Log.auth.info("Signed in with \(method.rawValue, privacy: .public)")
            setActive(connection, client: makeClient(server.configuration, credentials: credentials))
            didAuthorize(result.response, features: result.features, connection: connection)
        } catch {
            // The tokens weren't saved, so nothing could sign out of this server session later.
            if !isSaved { _ = await serverLogout(session, client: makeClient(server.configuration, credentials: nil)) }
            throw error
        }
    }

    // MARK: - Session

    /// Restores the most recently used connection. With saved tokens it's signed in if the server
    /// accepts them, or offline with the saved user if the server can't be reached. Otherwise,
    /// or if the server rejects the session or is no longer supported, it's signed out with
    /// ``lastError`` set. Call again to retry from offline.
    public func restoreSession() async {
        let operation = begin()
        state = .restoring
        lastError = nil
        await reloadConnections()
        do {
            guard let connection = try await store.connectionToRestore() else { throw AccountError.notSignedIn }
            let client = try await prepare(connection)
            guard isCurrent(operation) else { return }
            await activate(connection, client: client, operation: operation)
        } catch {
            guard isCurrent(operation) else { return }
            if !(error is AccountError) {
                let reason = (error as? KeychainError)?.description ?? String(describing: type(of: error))
                Log.auth.error("Couldn't restore the session: \(reason, privacy: .public)")
            }
            signOutLocally(error: error as? ServerValidationError)
        }
    }

    /// Makes another saved connection active, as ``restoreSession()`` does.
    /// - Throws: ``AccountError`` if the connection isn't saved or has no session, without
    ///   changing anything.
    public func `switch`(to id: UUID) async throws {
        guard let connection = try await store.connection(id: id), !connection.isDisconnected else {
            throw AccountError.connectionNotFound
        }
        let client = try await prepare(connection)
        try await store.markUsed(id: id, at: now())
        let operation = begin()
        lastError = nil
        state = .restoring
        await reloadConnections()
        guard isCurrent(operation) else { throw CancellationError() }
        await activate(connection, client: client, operation: operation)
    }

    /// Signs out of the active connection: deletes its tokens, keeping the connection and its
    /// custom headers, then ends the server session, best effort.
    /// - Returns: The OpenID provider's end-session URL to open for an OpenID session, if the
    ///   server returned one.
    @discardableResult
    public func logout() async -> URL? {
        _ = begin()
        guard let connection = activeConnection, let client else {
            signOutLocally(error: nil)
            return nil
        }
        let ended = await credentials(for: connection.id).signOut()
        if activeConnection?.id == connection.id { signOutLocally(error: nil) }
        Log.auth.info("Signed out")
        guard let ended else { return nil }
        return await serverLogout(ended, client: client)
    }

    /// Forgets a saved connection: deletes its Keychain items and removes it from the store, then
    /// ends its server session, best effort. Removing the active connection signs out.
    /// - Returns: The OpenID provider's end-session URL, as for ``logout()``.
    @discardableResult
    public func remove(_ id: UUID) async throws -> URL? {
        guard let connection = try await store.connection(id: id) else { throw AccountError.connectionNotFound }
        let removed = try await credentials(for: id).removeAll()
        var logoutClient = makeClient(connection, customHeaders: removed.customHeaders, credentials: nil)
        if activeConnection?.id == id {
            _ = begin()
            logoutClient = client ?? logoutClient
            signOutLocally(error: nil)
        }
        _ = try await store.remove(id: id, now: now())
        await reloadConnections()
        guard let session = removed.session, let logoutClient else { return nil }
        return await serverLogout(session, client: logoutClient)
    }

    // MARK: - Private

    private func begin() -> Int {
        operation += 1
        return operation
    }

    private func isCurrent(_ operation: Int) -> Bool {
        operation == self.operation
    }

    private func credentials(for id: UUID) -> ConnectionCredentials {
        if let existing = credentials[id] { return existing }
        let created = ConnectionCredentials(connectionID: id, vault: vault) { [weak self] id, generation in
            self?.sessionExpired(id, generation: generation)
        }
        credentials[id] = created
        return created
    }

    /// Loads the connection's saved session and builds its client.
    private func prepare(_ connection: ServerConnectionDTO) async throws -> APIClient {
        let credentials = self.credentials(for: connection.id)
        let saved = try await credentials.load()
        guard saved.session != nil else { throw AccountError.notSignedIn }
        guard let client = makeClient(connection, customHeaders: saved.customHeaders, credentials: credentials) else {
            throw ServerValidationError.invalidAddress
        }
        return client
    }

    /// Authorizes the saved session: signed in, offline with the saved user if the server can't
    /// be reached, or signed out if the server rejects the session or its version.
    private func activate(_ connection: ServerConnectionDTO, client: APIClient, operation: Int) async {
        setActive(connection, client: client)
        do {
            let result = try await validator.authorize(with: client)
            guard isCurrent(operation), activeConnection?.id == connection.id else { return }
            var connection = connection
            let version = result.response.serverSettings?.version
            if connection.serverVersion != version,
                (try? await store.updateServerVersion(id: connection.id, version)) == true
            {
                connection.serverVersion = version
                await reloadConnections()
            }
            guard isCurrent(operation), activeConnection?.id == connection.id else { return }
            didAuthorize(result.response, features: result.features, connection: connection)
        } catch {
            guard isCurrent(operation), activeConnection?.id == connection.id else { return }
            let error = error as? ServerValidationError
            switch error {
            case .sessionExpired?, .unsupportedVersion?:
                signOutLocally(error: error)
            default:
                // Connection failures, timeouts, server errors and unexpected responses.
                Log.auth.notice("Offline: \(error?.diagnosticDescription ?? "cancelled", privacy: .public)")
                lastError = error
                state = .offline(AccountUser(connection))
            }
        }
    }

    private func setActive(_ connection: ServerConnectionDTO, client: APIClient) {
        activeConnection = connection
        self.client = client
        authorization = nil
        features = nil
    }

    private func didAuthorize(_ response: AuthResponse, features: ServerFeatures, connection: ServerConnectionDTO) {
        activeConnection = connection
        authorization = AuthResponse(
            user: response.user, userDefaultLibraryId: response.userDefaultLibraryId,
            serverSettings: response.serverSettings, ereaderDevices: response.ereaderDevices)
        self.features = features
        lastError = nil
        state = .signedIn(AccountUser(connection))
    }

    private func signOutLocally(error: ServerValidationError?) {
        activeConnection = nil
        client = nil
        authorization = nil
        features = nil
        lastError = error
        state = .signedOut
    }

    /// The server rejected the refresh token. The credentials have deleted the tokens.
    private func sessionExpired(_ id: UUID, generation: Int) {
        // A sign-in since the expiry replaced the session.
        guard generation > signInGenerations[id, default: 0] else { return }
        Log.auth.notice("The session expired")
        guard activeConnection?.id == id else { return }
        signOutLocally(error: .sessionExpired)
    }

    private func reloadConnections() async {
        do {
            connections = try await store.allConnections().filter { !$0.isDisconnected }
        } catch {
            Log.auth.error("Couldn't load saved connections: \(String(describing: type(of: error)), privacy: .public)")
        }
    }

    private func makeClient(_ configuration: APIClientConfiguration, credentials: ConnectionCredentials?) -> APIClient {
        APIClient(
            configuration: configuration, tokenProvider: credentials ?? NoTokens(),
            sessionConfiguration: sessionConfiguration())
    }

    private func makeClient(
        _ connection: ServerConnectionDTO, customHeaders: [String: String], credentials: ConnectionCredentials?
    ) -> APIClient? {
        guard let address = ServerAddress(connection.address),
            let configuration = try? APIClientConfiguration(baseURL: address.url, customHeaders: customHeaders)
        else { return nil }
        return makeClient(configuration, credentials: credentials)
    }

    /// `POST /logout`, best effort. Returns the end-session URL if it's `http` or `https`.
    private func serverLogout(_ session: StoredSession, client: APIClient) async -> URL? {
        do {
            let response = try await client.send(
                AuthEndpoints.logout(refreshToken: session.refreshToken, openIDSession: session.openIDSession))
            guard let string = response.redirectURL, let url = URL(string: string),
                ["https", "http"].contains(url.scheme?.lowercased())
            else { return nil }
            return url
        } catch {
            Log.auth.notice("Server sign-out failed: \(String(describing: type(of: error)), privacy: .public)")
            return nil
        }
    }
}

/// For clients that only send unauthenticated requests, such as `POST /logout`.
private struct NoTokens: TokenProvider {
    func tokens() async -> AuthTokens? { nil }
    func replaceTokens(expected: AuthTokens, with new: AuthTokens) async -> Bool { false }
    func expireSession(ifCurrent rejected: AuthTokens) async -> Bool { false }
}
