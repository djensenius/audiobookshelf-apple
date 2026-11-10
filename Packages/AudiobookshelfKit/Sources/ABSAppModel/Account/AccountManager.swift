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

public enum AccountError: Error, Sendable, Equatable, LocalizedError {
    /// No saved connection has this id.
    case connectionNotFound
    /// The connection has no saved session; sign in to it again.
    case notSignedIn
    /// The server rejected the session or its version, or couldn't be reached.
    case server(ServerValidationError)
    /// The saved session couldn't be read, for example while the device is locked.
    case keychain(KeychainError)

    // TODO: Localise these messages once ABSAppModel has string catalogs.
    public var errorDescription: String? {
        switch self {
        case .connectionNotFound: "This server is no longer saved."
        case .notSignedIn: "You're signed out of this server. Sign in again."
        case .server(let error): error.errorDescription
        case .keychain(let error) where error.isUnavailable:
            "Your saved sign-in can't be read right now. Unlock your device and try again."
        case .keychain: "Your saved sign-in couldn't be read. Sign in again."
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
/// ``lastError`` set to `.server(.sessionExpired)`. Only the tokens are deleted; the connection
/// and its custom headers stay saved for signing in again.
///
/// From ``AccountState/offline(_:)``, call ``restoreSession()`` again to reconnect, for example
/// when the network or the app comes back.
///
/// Each call supersedes the ones still running: a superseded call leaves the state to the newer
/// one, and throws `CancellationError` if it throws. ``logout()`` and ``remove(_:)`` also end
/// the session of a connection that's still being restored, switched to or signed in to.
@MainActor @Observable
public final class AccountManager {
    public private(set) var state: AccountState = .signedOut
    /// Saved connections, most recently used first. Removed connections that are kept for their
    /// local data aren't listed.
    public private(set) var connections: [ServerConnectionDTO] = []
    /// The active connection, set while signed in, offline or restoring.
    public private(set) var activeConnection: ServerConnectionDTO?
    /// The active connection's client, set while signed in or restoring, and offline unless the
    /// Keychain couldn't be read.
    public private(set) var client: APIClient?
    /// The latest sign-in or authorize response, without its tokens; `nil` offline.
    public private(set) var authorization: AuthResponse?
    /// From the authorize response, or offline from the version saved with the connection.
    public private(set) var features: ServerFeatures?
    /// Why the last restore or switch ended signed out or offline, or why the session expired.
    public private(set) var lastError: AccountError?

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
    /// The connection the current restore, switch or sign-in is making active, until that call
    /// returns, so removing it cancels the call at any stage.
    @ObservationIgnored private var pendingConnectionID: UUID?
    /// Counts ``logout()`` calls, so a sign-in can tell that it was signed out while running.
    @ObservationIgnored private var logouts = 0
    /// Connections that ``remove(_:)`` is deleting, whose missing session isn't an expiry.
    @ObservationIgnored private var removing: Set<UUID> = []
    /// A test seam: ``restoreSession()`` awaits it after loading the connections and before
    /// choosing one, so a test can sign out in that window. The store calls there can't be held
    /// from outside: SwiftData runs them on the calling thread, the main actor.
    @ObservationIgnored var restoreWillChooseConnection: (@MainActor () async -> Void)?

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
    ///
    /// If the sign-in fails, the state is unchanged. It throws `CancellationError` if a newer call
    /// superseded it, including a ``logout()`` while it runs, even of another connection, which
    /// also signs out of the session it saved. A new connection whose session couldn't be saved
    /// stays in ``connections`` without one; switching to it throws ``AccountError/notSignedIn``.
    public func connect(local server: ValidatedServer, username: String, password: String) async throws {
        let logouts = self.logouts
        let result = try await validator.login(to: server, username: username, password: password)
        try await finishSignIn(result, to: server, method: .local, logoutsBefore: logouts)
    }

    /// Signs in to `server` through its OpenID provider and makes it the active connection.
    /// Fails and is cancelled as ``connect(local:username:password:)`` is.
    public func connect(oidc server: ValidatedServer, authenticator: any WebAuthenticator) async throws {
        let logouts = self.logouts
        let result = try await openID.login(to: server, using: authenticator)
        try await finishSignIn(result, to: server, method: .openid, logoutsBefore: logouts)
    }

    /// Saves the session, then marks the connection used and activates it. A sign-in superseded
    /// by another call keeps its saved session for switching to later, unless the newer call was
    /// ``logout()``, which this sign-in then also signs out of, or the connection was removed.
    private func finishSignIn(
        _ result: LoginResult, to server: ValidatedServer, method: ServerAuthMethod, logoutsBefore: Int
    ) async throws {
        let operation = begin()
        defer { if isCurrent(operation) { pendingConnectionID = nil } }
        let session = StoredSession(tokens: result.tokens, openIDSession: result.openIDSession)
        var saved: (id: UUID, credentials: ConnectionCredentials, generation: Int)?
        do {
            guard logouts == logoutsBefore else { throw CancellationError() }
            // Not marked used before the session is saved, so a failed sign-in isn't restored.
            let connection = try await store.upsertLogin(
                address: server.address, userId: result.response.user.id, username: result.response.user.username,
                authMethod: method, serverVersion: result.response.serverSettings?.version, markUsed: false,
                now: now())
            guard logouts == logoutsBefore else { throw CancellationError() }
            if isCurrent(operation) { pendingConnectionID = connection.id }
            let credentials = self.credentials(for: connection.id)
            let stored = try await credentials.signIn(session, customHeaders: server.configuration.customHeaders)
            signInGenerations[connection.id] = stored.generation
            saved = (connection.id, credentials, stored.generation)
            if let replaced = stored.replaced, replaced.refreshToken != session.refreshToken {
                // Signed in again: end the session this one replaced, best effort.
                _ = await serverLogout(replaced, client: makeClient(server.configuration, credentials: nil))
            }
            try ensureCurrent(operation)
            // Removed since it was saved; the catch deletes the session.
            guard try await store.markUsed(id: connection.id, at: now()) else { throw AccountError.connectionNotFound }
            await reloadConnections()
            try ensureCurrent(operation)
            Log.auth.info("Signed in with \(method.rawValue, privacy: .public)")
            setActive(connection, client: makeClient(server.configuration, credentials: credentials))
            didAuthorize(result.response, features: result.features, connection: connection)
        } catch {
            let logoutClient = makeClient(server.configuration, credentials: nil)
            if let saved {
                if await isRemoved(saved.id) {
                    // Nothing else would delete what this sign-in saved for the removed connection.
                    if let ended = try? await saved.credentials.removeAll().session {
                        _ = await serverLogout(ended, client: logoutClient)
                    }
                } else if logouts != logoutsBefore,
                    // Signed out while saving: end the session saved here, unless it's been replaced.
                    let ended = await saved.credentials.signOut(ifGeneration: saved.generation).ended
                {
                    _ = await serverLogout(ended, client: logoutClient)
                }
            } else {
                // The tokens weren't saved, so nothing could sign out of this server session later.
                _ = await serverLogout(session, client: logoutClient)
            }
            await reloadConnections()
            throw error
        }
    }

    // MARK: - Session

    /// Restores the most recently used connection. With saved tokens it's signed in if the server
    /// accepts them, or offline with the saved user if the server can't be reached, a proxy
    /// refuses the request, or the Keychain is locked. Otherwise, or if the server rejects the
    /// session or is no longer supported, it's signed out, with ``lastError`` set unless there was
    /// nothing to restore. Call again to reconnect from offline.
    public func restoreSession() async {
        let operation = begin()
        defer { if isCurrent(operation) { pendingConnectionID = nil } }
        state = .restoring
        lastError = nil
        await reloadConnections()
        await restoreWillChooseConnection?()
        guard isCurrent(operation) else { return }
        var chosen: ServerConnectionDTO?
        do {
            chosen = try await store.connectionToRestore()
            guard isCurrent(operation) else { return }
            guard let connection = chosen else { throw AccountError.notSignedIn }
            pendingConnectionID = connection.id
            let client = try await prepare(connection)
            guard isCurrent(operation) else { return }
            await activate(connection, client: client, operation: operation)
        } catch {
            guard isCurrent(operation) else { return }
            restoreFailed(chosen, error: error)
        }
    }

    /// Makes another saved connection active, as ``restoreSession()`` does, and marks it used
    /// unless the server rejected it.
    /// - Throws: ``AccountError`` if the connection isn't saved or has no session, or the
    ///   ``KeychainError`` if the session can't be read. The state is then unchanged, unless this
    ///   superseded a restore or switch: then it's offline with the active connection, or signed
    ///   out if none is active. `CancellationError` if a newer call superseded it, including
    ///   ``remove(_:)`` of this connection.
    public func `switch`(to id: UUID) async throws {
        let operation = begin()
        defer { if isCurrent(operation) { pendingConnectionID = nil } }
        pendingConnectionID = id
        let connection: ServerConnectionDTO
        let client: APIClient
        do {
            guard let found = try await store.connection(id: id), !found.isDisconnected else {
                throw AccountError.connectionNotFound
            }
            try ensureCurrent(operation)
            client = try await prepare(found)
            try ensureCurrent(operation)
            connection = found
        } catch {
            // A superseded restore or switch won't finish. Keep a connection it was activating or
            // reconnecting, unverified, as offline does.
            if isCurrent(operation), state == .restoring {
                if let active = activeConnection {
                    goOffline(active, client: self.client, error: nil)
                } else {
                    signOutLocally(error: nil)
                }
            }
            throw error
        }
        lastError = nil
        state = .restoring
        await activate(connection, client: client, operation: operation)
        try ensureCurrent(operation)
        // Signed out if the server rejected the session or its version.
        guard activeConnection?.id == id else { return }
        do {
            try await store.markUsed(id: id, at: now())
        } catch {
            Log.auth.error("Couldn't mark a connection used: \(String(describing: type(of: error)), privacy: .public)")
        }
        await reloadConnections()
        try ensureCurrent(operation)
    }

    /// Signs out of the active connection, or if none is active, of the one being restored,
    /// switched to or signed in to: deletes its tokens, keeping the connection and its custom
    /// headers, then ends the server session, best effort. With one connection active while a
    /// restore or switch to another runs, it signs out of the active one and cancels the other.
    /// A sign-in that's running is cancelled and signed out too.
    /// - Returns: The OpenID provider's end-session URL to open for an OpenID session, if the
    ///   server returned one.
    @discardableResult
    public func logout() async -> URL? {
        var id = activeConnection?.id ?? pendingConnectionID
        let activeClient = client
        let wasRestoring = state == .restoring
        _ = begin()
        logouts += 1
        signOutLocally(error: nil)
        if id == nil, wasRestoring {
            // A restore that hasn't chosen its connection yet.
            id = try? await store.connectionToRestore()?.id
        }
        guard let id else { return nil }
        let credentials = self.credentials(for: id)
        let (ended, deleteError) = await credentials.signOut()
        if let deleteError {
            // The credentials retry the delete whenever this session is next loaded or read.
            Log.auth.error("Couldn't delete the session, will retry: \(deleteError.status, privacy: .public)")
        }
        Log.auth.info("Signed out")
        guard let ended else { return nil }
        var logoutClient = activeClient
        if logoutClient == nil { logoutClient = await makeLogoutClient(for: id, credentials: credentials) }
        guard let logoutClient else { return nil }
        return await serverLogout(ended, client: logoutClient)
    }

    /// Forgets a saved connection: deletes its Keychain items and removes it from the store, then
    /// ends its server session, best effort. Removing the active connection signs out; a sign-in,
    /// restore or switch to another connection carries on. Removing the one being signed in to,
    /// restored or switched to cancels that call.
    /// - Returns: The OpenID provider's end-session URL, as for ``logout()``.
    @discardableResult
    public func remove(_ id: UUID) async throws -> URL? {
        removing.insert(id)
        defer { removing.remove(id) }
        let activeClient = activeConnection?.id == id ? client : nil
        abandon(id)
        guard let connection = try await store.connection(id: id) else { throw AccountError.connectionNotFound }
        let removed = try await credentials(for: id).removeAll()
        _ = try await store.remove(id: id, now: now())
        // A switch to it that started meanwhile.
        abandon(id)
        await reloadConnections()
        guard let session = removed.session,
            let logoutClient = activeClient
                ?? makeClient(connection, customHeaders: removed.customHeaders, credentials: nil)
        else { return nil }
        return await serverLogout(session, client: logoutClient)
    }

    // MARK: - Private

    private func begin() -> Int {
        operation += 1
        pendingConnectionID = nil
        return operation
    }

    private func isCurrent(_ operation: Int) -> Bool {
        operation == self.operation
    }

    private func ensureCurrent(_ operation: Int) throws {
        guard isCurrent(operation) else { throw CancellationError() }
    }

    /// Signs out locally if `id` is active or being activated, and supersedes the running calls
    /// only if they're activating `id`.
    private func abandon(_ id: UUID) {
        if pendingConnectionID == id {
            _ = begin()
        } else if activeConnection?.id != id {
            return
        }
        signOutLocally(error: nil)
    }

    /// Whether `id` is being removed or is no longer saved and connected.
    private func isRemoved(_ id: UUID) async -> Bool {
        guard !removing.contains(id) else { return true }
        do {
            return try await store.connection(id: id)?.isDisconnected ?? true
        } catch {
            return false
        }
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

    /// Ends a restore that failed before authorizing.
    private func restoreFailed(_ connection: ServerConnectionDTO?, error: any Error) {
        switch error {
        case let error as KeychainError:
            Log.auth.error("Couldn't read the saved session: \(error.description, privacy: .public)")
            if error.isUnavailable, let connection {
                // The saved session may be fine once the Keychain can be read again.
                goOffline(connection, client: nil, error: .keychain(error))
            } else {
                signOutLocally(error: .keychain(error))
            }
        case is AccountError:
            // Nothing saved to restore.
            signOutLocally(error: nil)
        case let error as ServerValidationError:
            signOutLocally(error: .server(error))
        default:
            Log.auth.error("Couldn't restore the session: \(String(describing: type(of: error)), privacy: .public)")
            signOutLocally(error: nil)
        }
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
                // Removing the connection deleted its session; that isn't an expiry.
                signOutLocally(error: removing.contains(connection.id) ? nil : error.map(AccountError.server))
            default:
                // Connection failures, timeouts, server errors, a proxy's 401 or 403, a refused
                // redirect and unexpected responses.
                Log.auth.notice("Offline: \(error?.diagnosticDescription ?? "cancelled", privacy: .public)")
                goOffline(connection, client: client, error: error.map(AccountError.server))
            }
        }
    }

    private func setActive(_ connection: ServerConnectionDTO, client: APIClient) {
        activeConnection = connection
        self.client = client
        authorization = nil
        features = nil
    }

    /// Offline with the saved user, and the features of the version saved with the connection.
    private func goOffline(_ connection: ServerConnectionDTO, client: APIClient?, error: AccountError?) {
        activeConnection = connection
        self.client = client
        authorization = nil
        features = connection.serverVersion.flatMap(ServerFeatures.init(serverVersion:))
        lastError = error
        state = .offline(AccountUser(connection))
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

    private func signOutLocally(error: AccountError?) {
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
        guard activeConnection?.id == id, !removing.contains(id) else { return }
        signOutLocally(error: .server(.sessionExpired))
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

    /// A client for `POST /logout` to a saved connection that isn't active.
    private func makeLogoutClient(for id: UUID, credentials: ConnectionCredentials) async -> APIClient? {
        guard let connection = try? await store.connection(id: id) else { return nil }
        let customHeaders = (try? await credentials.load().customHeaders) ?? [:]
        return makeClient(connection, customHeaders: customHeaders, credentials: nil)
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
