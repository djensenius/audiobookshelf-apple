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
    /// local data aren't listed. A connection's `signedOutAt` is set from ``logout()``, or from an
    /// expiry whose session couldn't be deleted, until it's signed in to again.
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
    /// Bumped whenever a connection's saved session is stored, deleted or found expired, the
    /// active one's or not, so a view that caches ``hasSession(_:)`` reads it again.
    public private(set) var credentialsRevision = 0

    @ObservationIgnored private let store: ServerConnectionStore
    @ObservationIgnored private let vault: CredentialVault
    /// Checks addresses and signs in, over the session configuration the manager was given, so a
    /// connect flow validates a new server the same way.
    @ObservationIgnored public let validator: ServerValidator
    @ObservationIgnored private let openID: OIDCLoginService
    @ObservationIgnored private let sessionConfiguration: @Sendable () -> URLSessionConfiguration
    @ObservationIgnored private let now: @Sendable () -> Date
    /// Where a removed connection's saved preferences and recent searches are cleared.
    @ObservationIgnored private let settings: AppSettings?
    /// Whether ``restoreSession()`` has swept the settings of accounts that aren't saved.
    @ObservationIgnored private var sweptSettings = false
    @ObservationIgnored private var credentials: [UUID: ConnectionCredentials] = [:]
    /// The credentials generation of each connection's latest sign-in in this process.
    @ObservationIgnored private var signInGenerations: [UUID: Int] = [:]
    /// The credentials generation of each connection's latest expiry in this process.
    @ObservationIgnored private var expiredGenerations: [UUID: Int] = [:]
    @ObservationIgnored private var operation = 0
    /// The connection the current restore, switch or sign-in is making active, until that call
    /// returns, so removing it cancels the call at any stage.
    @ObservationIgnored private var pendingConnectionID: UUID?
    /// The operation of the latest ``logout()``, so a sign-in can tell that it was signed out
    /// while running, and whether a sign-in that replaced its session started after that.
    @ObservationIgnored private var latestLogout = 0
    /// Counts ``remove(_:)`` calls, and records the latest that removed each server user's
    /// connection, so a sign-in that started earlier doesn't save it again, even once deleted.
    @ObservationIgnored private var removals = 0
    @ObservationIgnored private var removedLogins: [ServerLogin: Int] = [:]
    /// Connections that ``remove(_:)`` is deleting, whose missing session isn't an expiry, with
    /// how many of its calls are, so one that returns doesn't clear another's (see
    /// ``isRemoving(_:)``). A call stops counting once its delete fails, so an expiry during its
    /// recovery saves its own sign-out.
    @ObservationIgnored private var removing: [UUID: Int] = [:]
    /// A test seam: ``restoreSession()`` awaits it after loading the connections and before
    /// choosing one, so a test can sign out in that window. The store calls there can't be held
    /// from outside: `ServerConnectionStore` is a `@ModelActor`, and each of its jobs runs to
    /// completion.
    @ObservationIgnored var restoreWillChooseConnection: (@MainActor () async -> Void)?
    /// A test seam: an expiry awaits it after signing out locally and before it saves the sign-out,
    /// so a test can sign in again in that window.
    @ObservationIgnored var willSaveExpiry: (@MainActor () async -> Void)?
    /// A test seam: restoring or switching to a signed-out connection awaits it before reading the
    /// session whose delete it retries, so a test can save a session in that window.
    @ObservationIgnored var willReadSignedOutSession: (@MainActor () async -> Void)?
    /// A test seam: a sign-in or switch awaits it just before marking its connection used, so a
    /// test can expire the session in that window.
    @ObservationIgnored var willMarkUsed: (@MainActor () async -> Void)?
    /// A test seam: a call that saves an expiry's skipped or undone sign-out awaits it just before
    /// saving, so a test can sign in again in that window.
    @ObservationIgnored var willSaveSignOutOfExpiry: (@MainActor () async -> Void)?
    /// A test seam: a call that saved an expiry's skipped or undone sign-out, and is about to clear
    /// it for a newer sign-in, awaits it just before clearing, so a test can expire that session in
    /// that window.
    @ObservationIgnored var willClearSignOutOfExpiry: (@MainActor () async -> Void)?
    /// A test seam: a ``remove(_:)`` whose delete failed awaits it after saving an expiry's sign-out
    /// and before reloading the connections, so a test can expire a newer session in that window.
    @ObservationIgnored var willReloadAfterFailedRemoval: (@MainActor () async -> Void)?
    /// A test seam: ``remove(_:)`` awaits it after signing out locally and finding the connection,
    /// and before deleting its session, so a test can change the state in that window.
    @ObservationIgnored var willDeleteRemovedSession: (@MainActor () async -> Void)?

    /// - Parameters:
    ///   - keychain: The app passes `KeychainStore()`; tests pass a fake.
    ///   - sessionConfiguration: Tests return a configuration with stub protocol classes.
    ///   - settings: ``remove(_:)`` clears the removed account's entries from it
    ///     (``AppSettings/removeAccountData(serverID:userID:)``), and the first
    ///     ``restoreSession()`` those of any account that isn't saved; ``logout()`` keeps them.
    public init(
        store: ServerConnectionStore,
        keychain: any KeychainStoring,
        validator: ServerValidator = ServerValidator(),
        openID: OIDCLoginService = OIDCLoginService(),
        sessionConfiguration: @escaping @Sendable () -> URLSessionConfiguration = { .absConnection() },
        now: @escaping @Sendable () -> Date = { .now },
        settings: AppSettings? = nil
    ) {
        self.settings = settings
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
    /// Calls made after it win, whichever finishes first. Starting it supersedes a restore or
    /// switch still running, which leaves the state offline with the active connection, or
    /// signed out if none is active; if the sign-in then fails, the state is otherwise unchanged.
    /// It throws `CancellationError` if a newer call superseded it, including a ``logout()``,
    /// even of another connection, which also signs out of the session it saved, as it does of
    /// the active one, and a ``remove(_:)`` of its connection, which also ends the new session on
    /// the server. It also throws `CancellationError` if its task was cancelled, which keeps the
    /// session as a superseded sign-in does. Either way, it throws that whichever step failed, so
    /// a failure to authenticate or save isn't reported once it's stale. A sign-in superseded
    /// before saving its session ends it on the server. The active connection doesn't change, but
    /// a sign-in superseded or cancelled after it marked its connection used leaves that
    /// connection the one restored at the next launch. It throws
    /// `AccountError.server(.sessionExpired)` if the server rejected the new session before it
    /// became active. A new connection whose session couldn't be saved stays in ``connections``
    /// without one; switching to it throws ``AccountError/notSignedIn``. If the session was saved
    /// but the connection couldn't be marked used, the session is kept as a superseded sign-in's
    /// is.
    public func connect(local server: ValidatedServer, username: String, password: String) async throws {
        let attempt = beginSignIn()
        let result: LoginResult
        do {
            result = try await validator.login(to: server, username: username, password: password)
        } catch {
            throw failure(error, of: attempt.operation)
        }
        try await finishSignIn(result, to: server, method: .local, attempt: attempt)
    }

    /// Signs in to `server` through its OpenID provider and makes it the active connection.
    /// Fails and is cancelled as ``connect(local:username:password:)`` is.
    public func connect(oidc server: ValidatedServer, authenticator: any WebAuthenticator) async throws {
        let attempt = beginSignIn()
        let result: LoginResult
        do {
            result = try await openID.login(to: server, using: authenticator)
        } catch {
            throw failure(error, of: attempt.operation)
        }
        try await finishSignIn(result, to: server, method: .openid, attempt: attempt)
    }

    /// Checks a username and password with `server` without saving or changing anything: the
    /// state, the active connection and the Keychain stay as they were, and no running call is
    /// superseded, so a wrong password leaves the active session untouched. Pass the result to
    /// ``activate(_:)``, or to ``discard(_:)`` if it won't be activated.
    ///
    /// It throws the sign-in's error, or `CancellationError` if its task was cancelled, which also
    /// ends a session the server opened.
    public func authenticate(local server: ValidatedServer, username: String, password: String) async throws
        -> AuthenticatedSignIn
    {
        try await authenticated(server, method: .local) {
            try await validator.login(to: server, username: username, password: password)
        }
    }

    /// Checks a sign-in through `server`'s OpenID provider without saving or changing anything,
    /// as ``authenticate(local:username:password:)`` does. A cancelled browser sign-in throws.
    public func authenticate(oidc server: ValidatedServer, authenticator: any WebAuthenticator) async throws
        -> AuthenticatedSignIn
    {
        try await authenticated(server, method: .openid) {
            try await openID.login(to: server, using: authenticator)
        }
    }

    /// Saves an authenticated sign-in's session and makes its connection active, as
    /// ``connect(local:username:password:)`` does once the server accepted it, and fails and is
    /// cancelled as that does from then on. It's a new call: starting it supersedes the calls
    /// still running, whichever started first. A ``logout()`` since the authentication started
    /// cancels it and ends its server session, as does a ``remove(_:)`` of the server user's
    /// connection, so neither is undone by a sign-in that was checked before it.
    public func activate(_ signIn: AuthenticatedSignIn) async throws {
        guard latestLogout == signIn.latestLogout else {
            await discard(signIn)
            throw CancellationError()
        }
        let attempt = beginSignIn()
        try await finishSignIn(
            signIn.result, to: signIn.server, method: signIn.method,
            attempt: SignInAttempt(
                operation: attempt.operation, latestLogout: attempt.latestLogout, removals: signIn.removals))
    }

    /// Ends the server session of a sign-in that won't be activated, best effort. Nothing saved
    /// or active changes.
    public func discard(_ signIn: AuthenticatedSignIn) async {
        let session = StoredSession(tokens: signIn.result.tokens, openIDSession: signIn.result.openIDSession)
        _ = await serverLogout(session, client: makeClient(signIn.server, credentials: nil))
    }

    /// Runs `login`, capturing the logouts and removals before it starts.
    private func authenticated(
        _ server: ValidatedServer, method: ServerAuthMethod, login: () async throws -> LoginResult
    ) async throws -> AuthenticatedSignIn {
        let (latestLogout, removals) = (self.latestLogout, self.removals)
        let result: LoginResult
        do {
            result = try await login()
        } catch {
            throw Task.isCancelled ? CancellationError() : error
        }
        let signIn = AuthenticatedSignIn(
            server: server, method: method, result: result, latestLogout: latestLogout, removals: removals)
        if Task.isCancelled {
            await discard(signIn)
            throw CancellationError()
        }
        return signIn
    }

    /// Saves the session, then marks the connection used, which also clears a sign-out saved with
    /// it, and activates it. A sign-in superseded by another call keeps its saved session for
    /// switching to later, unless the newer call was ``logout()``, which this sign-in then also
    /// signs out of, or the connection was removed.
    private func finishSignIn(
        _ result: LoginResult, to server: ValidatedServer, method: ServerAuthMethod, attempt: SignInAttempt
    ) async throws {
        let operation = attempt.operation
        defer { if isCurrent(operation) { pendingConnectionID = nil } }
        let session = StoredSession(tokens: result.tokens, openIDSession: result.openIDSession)
        var saved: (id: UUID, credentials: ConnectionCredentials, generation: Int)?
        do {
            try ensureCurrent(operation)
            // Removed while authenticating; saving would bring it back.
            let login = ServerLogin(address: server.address.description, userId: result.response.user.id)
            guard removedLogins[login, default: 0] <= attempt.removals else { throw CancellationError() }
            // Not marked used before the session is saved, so a failed sign-in isn't restored.
            var connection = try await store.upsertLogin(
                address: server.address, userId: result.response.user.id, username: result.response.user.username,
                authMethod: method, serverVersion: result.response.serverSettings?.version, markUsed: false,
                now: now())
            try ensureCurrent(operation)
            pendingConnectionID = connection.id
            let credentials = self.credentials(for: connection.id)
            let stored = try await credentials.signIn(
                session, customHeaders: server.configuration.customHeaders, operation: operation)
            credentialsRevision += 1
            signInGenerations[connection.id] = stored.generation
            saved = (connection.id, credentials, stored.generation)
            if let replaced = stored.replaced, replaced.refreshToken != session.refreshToken {
                // Signed in again: end the session this one replaced, best effort.
                _ = await serverLogout(replaced, client: makeClient(server, credentials: nil))
            }
            try ensureActivatable(operation, id: connection.id, generation: stored.generation)
            // Clears a sign-out saved with the connection in the same save, so it can't be active
            // while still signed out. False if removed since it was saved; the catch deletes the
            // session.
            let usedAt = now()
            let expiredBefore = expiredGenerations[connection.id]
            await willMarkUsed?()
            guard try await store.markUsed(id: connection.id, at: usedAt) else { throw AccountError.connectionNotFound }
            _ = await saveSignOutOfExpiry(connection.id, since: expiredBefore)
            // Published as saved, so `activeConnection` agrees with `connections`.
            connection.lastUsedAt = usedAt
            connection.signedOutAt = nil
            await reloadConnections()
            try ensureActivatable(operation, id: connection.id, generation: stored.generation)
            Log.auth.info("Signed in with \(method.rawValue, privacy: .public)")
            setActive(connection, client: makeClient(server, credentials: credentials))
            didAuthorize(result.response, features: result.features, connection: connection)
        } catch {
            let logoutClient = makeClient(server, credentials: nil)
            if let saved {
                if await isRemoved(saved.id) {
                    // Nothing else would delete what this sign-in saved for the removed connection,
                    // unless a newer sign-in has replaced it, even while the removal is finishing.
                    let removed = try? await saved.credentials.removeAll(ifGeneration: saved.generation)
                    credentialsRevision += 1
                    if let ended = removed?.session {
                        _ = await serverLogout(ended, client: logoutClient)
                    }
                } else if latestLogout != attempt.latestLogout {
                    // Signed out while saving. Save the sign-out first, as logout() does, unless a
                    // newer sign-in has saved a session since, then end the session saved here,
                    // unless it's been replaced. A sign-in started after the sign-out that replaced
                    // it clears the sign-out when it marks the connection used; in case it did so
                    // first, clear it here too, as logout() does.
                    var signedOutAt: Date?
                    if signInGenerations[saved.id] == saved.generation { signedOutAt = await saveSignOut(of: saved.id) }
                    let signedOut = await saved.credentials.signOut(ifGeneration: saved.generation)
                    credentialsRevision += 1
                    if let signedOut {
                        if let ended = signedOut.ended { _ = await serverLogout(ended, client: logoutClient) }
                    } else if let signedOutAt, await saved.credentials.holdsSignIn(after: latestLogout) {
                        _ = try? await store.clearSignedOut(id: saved.id, savedAt: signedOutAt)
                    }
                } else if signInGenerations[saved.id] == saved.generation {
                    // Kept for switching to later, so clear the sign-out saved with the connection. If
                    // that fails, the connection stays signed out; nothing is activated here. It's
                    // cleared by the date read here, so a sign-out saved after the read stays, whatever
                    // order the store runs its jobs in; and not once this session has expired, since
                    // the expiry may have saved the sign-out of tokens it couldn't delete.
                    if let signedOutAt = try? await store.connection(id: saved.id)?.signedOutAt,
                        expiredGenerations[saved.id, default: 0] <= saved.generation
                    {
                        _ = try? await store.clearSignedOut(id: saved.id, savedAt: signedOutAt)
                    }
                }
            } else {
                // The tokens weren't saved, so nothing could sign out of this server session later.
                _ = await serverLogout(session, client: logoutClient)
            }
            await reloadConnections()
            throw failure(error, of: operation)
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
        await sweepSettingsOnce()
        await restoreWillChooseConnection?()
        guard isCurrent(operation) else { return }
        var chosen: ServerConnectionDTO?
        do {
            chosen = try await store.connectionToRestore()
            guard isCurrent(operation) else { return }
            guard let connection = chosen else { throw AccountError.notSignedIn }
            pendingConnectionID = connection.id
            let client = try await prepare(connection, operation: operation)
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
    ///   out if none is active. `CancellationError` if a newer call superseded it, whichever step
    ///   failed, including ``remove(_:)`` of this connection.
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
            client = try await prepare(found, operation: operation)
            try ensureCurrent(operation)
            connection = found
        } catch {
            // A superseded restore or switch won't finish. Keep a connection it was activating or
            // reconnecting, unverified, as offline does.
            endSupersededRestore(operation)
            throw failure(error, of: operation)
        }
        lastError = nil
        state = .restoring
        await activate(connection, client: client, operation: operation)
        try ensureCurrent(operation)
        // Signed out if the server rejected the session or its version.
        guard activeConnection?.id == id else { return }
        let usedAt = now()
        let expiredBefore = expiredGenerations[id]
        await willMarkUsed?()
        do {
            let marked = try await store.markUsed(id: id, at: usedAt)
            if marked { _ = await saveSignOutOfExpiry(id, since: expiredBefore) }
            if marked, isCurrent(operation), activeConnection?.id == id {
                // As saved, so `activeConnection` agrees with `connections`.
                activeConnection?.lastUsedAt = usedAt
            }
        } catch {
            Log.auth.error("Couldn't mark a connection used: \(String(describing: type(of: error)), privacy: .public)")
        }
        await reloadConnections()
        try ensureCurrent(operation)
    }

    /// Signs out of the active connection, or if none is active, of the one being restored,
    /// switched to or signed in to: deletes its tokens, keeping the connection and its custom
    /// headers, then ends the server session, best effort. The sign-out is saved with the
    /// connection first, as its `signedOutAt` in ``connections``, so if the delete fails, the
    /// session isn't restored or switched to, even after a relaunch, and those retry the delete.
    /// With one connection active while a restore or switch to another runs, it signs out of the
    /// active one and cancels the other. A sign-in that's running is cancelled and signed out too.
    /// - Returns: The OpenID provider's end-session URL to open for an OpenID session, if the
    ///   server returned one.
    @discardableResult
    public func logout() async -> URL? {
        var id = activeConnection?.id ?? pendingConnectionID
        let activeClient = client
        let wasRestoring = state == .restoring
        let operation = begin()
        latestLogout = operation
        signOutLocally(error: nil)
        if id == nil, wasRestoring {
            // A restore that hasn't chosen its connection yet.
            id = try? await store.connectionToRestore()?.id
        }
        guard let id else { return nil }
        forgetDownloadClient(id)
        let signedOutAt = await saveSignOut(of: id)
        let credentials = self.credentials(for: id)
        // Not a session that a sign-in started after this call saved, whichever reached the
        // credentials first.
        let signedOut = await credentials.signOut(savedBefore: operation)
        credentialsRevision += 1
        guard let signedOut else {
            // That sign-in clears the sign-out saved above when it marks the connection used, but
            // in case it did so first, clear it here unless another sign-out has replaced it.
            if let signedOutAt { _ = try? await store.clearSignedOut(id: id, savedAt: signedOutAt) }
            await reloadConnections()
            return nil
        }
        if let deleteError = signedOut.deleteError {
            // The credentials retry the delete whenever this session is next loaded or read, and
            // restoring or switching to the connection, even after a relaunch, retries it too.
            Log.auth.error("Couldn't delete the session, will retry: \(deleteError.status, privacy: .public)")
        }
        // Publishes the saved sign-out.
        await reloadConnections()
        Log.auth.info("Signed out")
        guard let ended = signedOut.ended else { return nil }
        var logoutClient = activeClient
        if logoutClient == nil { logoutClient = await makeLogoutClient(for: id, credentials: credentials) }
        guard let logoutClient else { return nil }
        let url = await serverLogout(ended, client: logoutClient)
        // Not once a sign-in has begun: the shared browser would end or interrupt it.
        return isCurrent(operation) ? url : nil
    }

    /// Forgets a saved connection: deletes its Keychain items and removes it from the store, then
    /// ends its server session, best effort. Removing the active connection signs out; a sign-in,
    /// restore or switch to another connection carries on. Removing the one being signed in to
    /// (once the sign-in has created it), restored or switched to cancels that call, and it stays
    /// cancelled if the removal fails: it throws `CancellationError`, and a sign-in that hadn't
    /// saved its session yet ends the server session it opened. A sign-in still authenticating,
    /// before it has created the connection, isn't cancelled by a removal that fails; a removal
    /// that succeeds stops it from saving the connection again.
    /// - Returns: The OpenID provider's end-session URL, as for ``logout()``.
    /// - Throws: ``AccountError/connectionNotFound`` if it isn't saved, or the ``KeychainError`` if
    ///   its Keychain items can't be deleted, which leaves the connection and its session saved.
    ///   Either way the active connection it signed out is put back, unless meanwhile a newer call
    ///   began, another connection became active, or its own session expired: the state stays as
    ///   they left it. If it was restoring, it returns offline, since the cancelled restore doesn't
    ///   resume. If its session expired meanwhile, the sign-out is saved, as an expiry's is. If the items are deleted but the store can't save the removal, it still signs out
    ///   and ends the session, then throws the store's error; the connection stays saved without a
    ///   session, and removing it again retries.
    @discardableResult
    public func remove(_ id: UUID) async throws -> URL? {
        removing[id, default: 0] += 1
        var isCounted = true
        defer { if isCounted { endRemoving(id) } }
        forgetDownloadClient(id)
        let wasActive = activeConnection?.id == id
        let activeClient = wasActive ? client : nil
        // Signed out first, so a restore or switch that's reading the session stops at once; put
        // back if the deletion fails.
        let before = localState
        abandon(id)
        let abandoned = operation
        let expired = expiredGenerations[id]
        let connection: ServerConnectionDTO
        let removed: (session: StoredSession?, customHeaders: [String: String])
        do {
            guard let found = try await store.connection(id: id) else { throw AccountError.connectionNotFound }
            connection = found
            await willDeleteRemovedSession?()
            removed = try await credentials(for: id).removeAll()
            credentialsRevision += 1
        } catch {
            // Not removing it any more: an expiry from here on, such as of a newer session while
            // the sign-out below saves, saves its own, unless another removal of it is running.
            endRemoving(id)
            isCounted = false
            // Only the active connection signed out above is put back, and only over the state it
            // left: a failed removal mustn't undo a newer call, another connection activating, or
            // the session expiring.
            if wasActive, operation == abandoned, expiredGenerations[id] == expired, state == .signedOut,
                activeConnection == nil
            {
                restore(before)
            }
            // An expiry meanwhile didn't save its sign-out, expecting the delete; it failed, so the
            // rejected tokens may still be stored.
            if await saveSignOutOfExpiry(id, since: expired) {
                await willReloadAfterFailedRemoval?()
                await reloadConnections()
            }
            throw error
        }
        // A sign-in to it that started earlier mustn't save it again, even once the store has
        // removed it.
        removals += 1
        removedLogins[ServerLogin(address: connection.address, userId: connection.userId)] = removals
        await credentialsRemoved?(id)
        var storeError: (any Error)?
        do {
            _ = try await store.remove(id: id, now: now())
            // Keyed like `LibraryConnectionKey`. Not if the store kept the connection listed:
            // removing it again retries.
            settings?.removeAccountData(serverID: id.uuidString, userID: connection.userId)
        } catch {
            // The session's already deleted here, so nothing could end it on the server later.
            storeError = error
        }
        // A switch to it that started meanwhile.
        abandon(id)
        await reloadConnections()
        var endSessionURL: URL?
        if let session = removed.session,
            let logoutClient = activeClient
                ?? makeClient(connection, customHeaders: removed.customHeaders, credentials: nil)
        {
            endSessionURL = await serverLogout(session, client: logoutClient)
        }
        if let storeError { throw storeError }
        return endSessionURL
    }

    /// Replaces ``authorization``'s user with `user` from the socket's `user_updated`, when it is
    /// the signed-in user; nothing is saved.
    public func applyUserUpdate(_ user: User) {
        guard authorization?.user.id == user.id else { return }
        authorization?.user = user
    }

    /// The custom headers saved for a connection, kept after sign-out, for signing in again.
    /// - Throws: The ``KeychainError`` if they can't be read.
    public func customHeaders(for id: UUID) async throws -> [String: String] {
        try await credentials(for: id).load().customHeaders
    }

    /// Whether ``switch(to:)`` has a saved session to use for a connection: it isn't signed out
    /// and its tokens are saved. An expiry can delete the tokens without setting `signedOutAt`.
    /// A Keychain that can't be read counts as a session, so the switch says why it failed.
    public func hasSession(_ id: UUID) async -> Bool {
        guard connections.contains(where: { $0.id == id && $0.signedOutAt == nil }) else { return false }
        do {
            return try await credentials(for: id).load().session != nil
        } catch {
            return true
        }
    }

    /// Whether a sign-in, restore or switch began since the last ``logout()``: its end-session URL
    /// would then end or interrupt that in the shared browser.
    public var hasBegunSinceLogout: Bool { operation != latestLogout }

    // MARK: - Downloads

    /// Awaited by ``remove(_:)`` once the connection's Keychain items are deleted, before the
    /// store removes it and its server session is ended: the app stops its downloads and
    /// discards their resume data there. Not called when the delete fails, so the connection
    /// keeps its downloads' progress along with its session.
    @ObservationIgnored public var credentialsRemoved: (@MainActor (UUID) async -> Void)?

    /// Called when a connection's session expires (its tokens are deleted, or a sign-out is
    /// saved), active or not, and even before its session is restored: the app stops that
    /// connection's downloads and discards their resume data there, even when its running
    /// session's end may be a switch. Also for a connection being removed, whose Keychain delete
    /// may still fail, so ``credentialsRemoved`` isn't called; the app serializes the two cleanups.
    @ObservationIgnored public var credentialsExpired: (@MainActor (UUID) -> Void)?

    /// Clients for download credentials of saved connections that aren't active, so a
    /// connection's download parts share one client, with the credentials' generation they were
    /// made for: every sign-in, sign-out, expiry and removal bumps it, so a client made before
    /// a new session (whose custom headers may differ) isn't used after it.
    @ObservationIgnored private var downloadClients: [UUID: (client: APIClient, generation: Int)] = [:]
    /// Counts ``logout()``, ``remove(_:)`` and expiries per connection, so a lookup that
    /// overlapped one doesn't keep a client.
    @ObservationIgnored private var downloadClientResets: [UUID: Int] = [:]

    /// The client for a connection's download credentials (`AccountDownloadCredentials`): the
    /// active client, or for another saved connection that is connected, not signed out, not
    /// being removed and has a saved session, a client over its credentials (shared with the
    /// app's own clients, so a refresh is saved and joined), kept until that connection's next
    /// sign-in, ``logout()``, ``remove(_:)`` or expiry. Reads the store, not ``connections``, so
    /// it works in a background wake before the session is restored. `nil` otherwise.
    public func downloadClient(for id: UUID) async -> APIClient? {
        if let client = await activeClient(for: id) { return client }
        guard !isRemoving(id) else { return nil }
        let reset = downloadClientResets[id, default: 0]
        // Read each time: an expiry whose delete failed saves a sign-out without a logout.
        guard let connection = try? await store.connection(id: id), !connection.isDisconnected,
            connection.signedOutAt == nil, downloadClientResets[id, default: 0] == reset, !isRemoving(id)
        else { return nil }
        if let client = await activeClient(for: id) { return client }
        let credentials = self.credentials(for: id)
        // The generation first: headers a newer sign-in saved meanwhile are kept under the older
        // generation, so the next lookup makes a client again rather than keeping stale ones.
        guard let read = try? await credentials.loadSession(), read.session != nil,
            downloadClientResets[id, default: 0] == reset, !isRemoving(id)
        else { return nil }
        if let client = await activeClient(for: id) { return client }
        if let cached = downloadClients[id], cached.generation == read.generation { return cached.client }
        guard let saved = try? await credentials.load(), saved.session != nil,
            downloadClientResets[id, default: 0] == reset, !isRemoving(id)
        else { return nil }
        if let client = await activeClient(for: id) { return client }
        if let cached = downloadClients[id], cached.generation == read.generation { return cached.client }
        guard let created = makeClient(connection, customHeaders: saved.customHeaders, credentials: credentials) else {
            return nil
        }
        downloadClients[id] = (created, read.generation)
        return created
    }

    /// The active client, if `id` is the active connection and the client has the custom
    /// headers of its saved credentials: a sign-in to it (even one that then failed) may have
    /// saved others, and then a client over the saved credentials is made instead.
    private func activeClient(for id: UUID) async -> APIClient? {
        guard activeConnection?.id == id, let client,
            let saved = try? await credentials(for: id).load(),
            await client.configuration.customHeaders == saved.customHeaders,
            activeConnection?.id == id, self.client === client
        else { return nil }
        return client
    }

    /// Reads a download access token of `id` with `read`, from the client
    /// ``downloadClient(for:)`` returns, and returns both only if they belong to one sign-in:
    /// the connection's credentials weren't replaced during the read (a sign-in, sign-out,
    /// expiry or removal changes their generation; a refresh doesn't) and the client has their
    /// custom headers. Otherwise `nil`, so a token is never sent with another sign-in's headers;
    /// a later lookup makes a client again.
    public func downloadAccess(
        for id: UUID, read: @Sendable (APIClient) async throws -> String?
    ) async throws -> (client: APIClient, token: String)? {
        guard let client = await downloadClient(for: id) else { return nil }
        let credentials = self.credentials(for: id)
        guard let before = try? await credentials.loadSession().generation,
            let token = try await read(client)
        else { return nil }
        // Generations only grow, and a sign-in saves its tokens and generation together, so an
        // unchanged generation means the token is the saved credentials'.
        guard let after = try? await credentials.loadConfiguration(), after.generation == before,
            await client.configuration.customHeaders == after.customHeaders
        else {
            Log.downloads.notice("A connection's credentials changed while reading a download token; not using it")
            return nil
        }
        return (client, token)
    }

    private func forgetDownloadClient(_ id: UUID) {
        downloadClients[id] = nil
        downloadClientResets[id, default: 0] += 1
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

    /// `error`, or `CancellationError` if a newer call superseded `operation` or the task was
    /// cancelled, so a failure isn't reported once it's stale.
    private func failure(_ error: any Error, of operation: Int) -> any Error {
        isCurrent(operation) && !Task.isCancelled ? error : CancellationError()
    }

    /// Starts a sign-in, superseding the running calls before it authenticates.
    private func beginSignIn() -> SignInAttempt {
        let operation = begin()
        // A superseded restore or switch won't finish, and the sign-in may wait for a browser.
        endSupersededRestore(operation)
        return SignInAttempt(operation: operation, latestLogout: latestLogout, removals: removals)
    }

    /// Throws as ``ensureCurrent(_:)`` does, or if the task is cancelled, or
    /// `AccountError.server(.sessionExpired)` if the session saved at `generation` has expired
    /// since, as when the active client used it while the sign-in waited.
    private func ensureActivatable(_ operation: Int, id: UUID, generation: Int) throws {
        try ensureCurrent(operation)
        try Task.checkCancellation()
        guard expiredGenerations[id, default: 0] <= generation else { throw AccountError.server(.sessionExpired) }
    }

    /// For a call that superseded a restore or switch, which then won't finish: keeps the active
    /// connection, unverified, as offline does, or signs out if none is active.
    private func endSupersededRestore(_ operation: Int) {
        guard isCurrent(operation), state == .restoring else { return }
        if let active = activeConnection {
            goOffline(active, client: client, error: nil)
        } else {
            signOutLocally(error: nil)
        }
    }

    /// Cancels the running call if it's activating `id`, and signs out locally if `id` is active.
    /// Another active connection stays, as offline if the cancelled call was restoring it.
    private func abandon(_ id: UUID) {
        let isPending = pendingConnectionID == id
        let operation = isPending ? begin() : self.operation
        if activeConnection?.id == id {
            signOutLocally(error: nil)
        } else if isPending {
            endSupersededRestore(operation)
        }
    }

    private var localState: LocalState {
        LocalState(
            state: state, activeConnection: activeConnection, client: client, authorization: authorization,
            features: features, lastError: lastError)
    }

    /// Puts back what ``abandon(_:)`` and a sign-out cleared. A restore or switch it cancelled
    /// doesn't resume: the connection stays offline if it was active.
    private func restore(_ saved: LocalState) {
        if saved.state == .restoring {
            if let active = saved.activeConnection { goOffline(active, client: saved.client, error: saved.lastError) }
            return
        }
        activeConnection = saved.activeConnection
        client = saved.client
        authorization = saved.authorization
        features = saved.features
        lastError = saved.lastError
        state = saved.state
    }

    /// Whether a ``remove(_:)`` of `id` is running, and its delete hasn't failed.
    private func isRemoving(_ id: UUID) -> Bool {
        removing[id] != nil
    }

    /// Stops counting one ``remove(_:)`` of `id`, keeping any other that's running.
    private func endRemoving(_ id: UUID) {
        removing[id, default: 1] -= 1
        if removing[id] == 0 { removing[id] = nil }
    }

    /// Whether `id` is being removed or is no longer saved and connected.
    private func isRemoved(_ id: UUID) async -> Bool {
        guard !isRemoving(id) else { return true }
        do {
            return try await store.connection(id: id)?.isDisconnected ?? true
        } catch {
            return false
        }
    }

    /// The connection's credentials, which all of its clients share. Internal for tests.
    func credentials(for id: UUID) -> ConnectionCredentials {
        if let existing = credentials[id] { return existing }
        let created = ConnectionCredentials(connectionID: id, vault: vault) {
            [weak self] id, generation, deleteFailed in
            await self?.sessionExpired(id, generation: generation, deleteFailed: deleteFailed)
        }
        credentials[id] = created
        return created
    }

    /// Loads the connection's saved session and builds its client.
    /// - Throws: `CancellationError` if a newer call started while it read a signed-out session.
    private func prepare(_ connection: ServerConnectionDTO, operation: Int) async throws -> APIClient {
        let credentials = self.credentials(for: connection.id)
        guard connection.signedOutAt == nil else {
            // Signed out, maybe before a relaunch, but the session's delete failed: retry it.
            // Not if a newer call started meanwhile, such as a sign-in that has saved a session,
            // and not if a sign-in saved the session read here: it clears the sign-out.
            await willReadSignedOutSession?()
            let read = try? await credentials.loadSession()
            try ensureCurrent(operation)
            if let read, read.session != nil, !read.storedBySignIn {
                _ = await credentials.signOut(ifGeneration: read.generation)
                credentialsRevision += 1
            }
            throw AccountError.notSignedIn
        }
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
                signOutLocally(error: isRemoving(connection.id) ? nil : error.map(AccountError.server))
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

    /// The server rejected the refresh token. The credentials have deleted the tokens, or if
    /// `deleteFailed`, retry that; then the sign-out is saved with the connection, as a logout's
    /// is, so a relaunch doesn't restore the rejected tokens offline.
    private func sessionExpired(_ id: UUID, generation: Int, deleteFailed: Bool) async {
        // A sign-in since the expiry replaced the session.
        guard generation > signInGenerations[id, default: 0] else { return }
        // A kept download client has no tokens now, and a lookup that overlapped this mustn't keep one.
        forgetDownloadClient(id)
        // A sign-in that saved the expired session mustn't activate it.
        expiredGenerations[id] = generation
        Log.auth.notice("The session expired")
        credentialsRevision += 1
        credentialsExpired?(id)
        if activeConnection?.id == id, !isRemoving(id) { signOutLocally(error: .server(.sessionExpired)) }
        // Not for a connection being removed, whose record the removal deletes; if it fails, it
        // saves this then.
        guard deleteFailed, !isRemoving(id) else { return }
        let logoutBefore = latestLogout
        await willSaveExpiry?()
        guard let savedAt = await saveSignOut(of: id) else { return }
        // A sign-in that saved a newer session while this saved: it clears a sign-out when it marks
        // the connection used, unless that came first, so clear this one by its date. One recorded
        // after this check marks the connection used after this save finished, so that clears it.
        // Not after a logout meanwhile, whose sign-out this save replaced, as in
        // `saveSignOutOfExpiry`.
        if signInGenerations[id, default: 0] > generation, expiredGenerations[id, default: 0] <= generation,
            latestLogout == logoutBefore
        {
            _ = try? await store.clearSignedOut(id: id, savedAt: savedAt)
        }
        await reloadConnections()
    }

    /// Saves the sign-out of an expiry of `id` recorded since its latest was `expiredBefore`, unless
    /// a sign-in has replaced that session since: for a call that skipped or undid the expiry's
    /// save. ``remove(_:)`` skips it for a connection it expects to delete, and marking the
    /// connection used clears it, whichever of the two saves the store runs first. Otherwise the
    /// tokens, if the expiry couldn't delete them, would restore offline after a relaunch. Saved
    /// even if they were deleted, which changes nothing: the connection has no session either way.
    /// Returns whether it saved.
    private func saveSignOutOfExpiry(_ id: UUID, since expiredBefore: Int?) async -> Bool {
        guard let expired = expiredGenerations[id], expired != expiredBefore,
            expired > signInGenerations[id, default: 0]
        else { return false }
        let logoutBefore = latestLogout
        await willSaveSignOutOfExpiry?()
        guard let savedAt = await saveSignOut(of: id) else { return false }
        // As in `sessionExpired`: a sign-in that saved a newer session while this saved may have
        // marked the connection used first, so clear this one by its date, unless a newer expiry
        // or a logout since signed that session out too. This save replaced a logout's sign-out,
        // whose delete may have failed, so it's kept for it; any logout counts, which at worst
        // keeps a sign-out the newer session didn't need.
        if signInGenerations[id, default: 0] > expired, expiredGenerations[id, default: 0] <= expired,
            latestLogout == logoutBefore
        {
            await willClearSignOutOfExpiry?()
            _ = try? await store.clearSignedOut(id: id, savedAt: savedAt)
        }
        return true
    }

    /// Clears, once, the settings of accounts that aren't saved: ``remove(_:)`` clears them
    /// after the store removes the connection, so a removal the app was terminated in, or one
    /// from before that, left them with no connection to remove again. Keeps the saved
    /// connections' and, in case one was saved since the store was read, the listed and active
    /// ones'. Not if the store can't be read.
    private func sweepSettingsOnce() async {
        guard let settings, !sweptSettings,
            let saved = try? await store.allConnections().filter({ !$0.isDisconnected })
        else { return }
        sweptSettings = true
        let accounts = saved + connections + [activeConnection].compactMap(\.self)
        settings.removeAccountData(keepingOnly: accounts.map { (serverID: $0.id.uuidString, userID: $0.userId) })
    }

    /// The ids of the saved connections, read from the store as the settings sweep reads them,
    /// plus the listed and active ones in case one was saved since; `nil` if the store can't be
    /// read. For sweeping data of connections removed in an earlier launch (#421), which must
    /// never go by ``connections`` alone: it's empty until it has loaded.
    public func savedConnectionIDs() async -> Set<UUID>? {
        guard let saved = try? await store.allConnections().filter({ !$0.isDisconnected }) else { return nil }
        return Set((saved + connections + [activeConnection].compactMap(\.self)).map(\.id))
    }

    private func reloadConnections() async {
        do {
            connections = try await store.allConnections().filter { !$0.isDisconnected }
        } catch {
            Log.auth.error("Couldn't load saved connections: \(String(describing: type(of: error)), privacy: .public)")
        }
    }

    /// Saves a sign-out with the connection, so that if its session's delete fails, the session
    /// isn't restored or switched to, even after a relaunch. A logout saves it before deleting; an
    /// expiry can only save it after its delete failed, so a crash in between leaves the rejected
    /// tokens, which restore offline until the next request is rejected. Returns its date, or
    /// `nil` if it couldn't be saved.
    @discardableResult
    private func saveSignOut(of id: UUID) async -> Date? {
        let date = now()
        do {
            try await store.setSignedOut(id: id, at: date)
            return date
        } catch {
            Log.auth.error("Couldn't save the sign-out: \(String(describing: type(of: error)), privacy: .public)")
            return nil
        }
    }

    /// A client for the server just validated, with the validation's cookie jar, so a cookie a
    /// proxy or load balancer set while validating or signing in keeps being sent. That includes
    /// `POST /logout`, which sends the jar's cookies except `refresh_token` (withheld so the
    /// `x-refresh-token` header names the session to end), follows only same-origin redirects,
    /// and is best effort, after the local sign-out.
    private func makeClient(_ server: ValidatedServer, credentials: ConnectionCredentials?) -> APIClient {
        server.makeClient(tokenProvider: credentials ?? NoTokens(), sessionConfiguration: sessionConfiguration())
    }

    private func makeClient(_ configuration: APIClientConfiguration, credentials: ConnectionCredentials?) -> APIClient {
        APIClient(
            configuration: configuration, tokenProvider: credentials ?? NoTokens(),
            sessionConfiguration: sessionConfiguration())
    }

    /// A client for a saved connection, with a new, empty cookie jar; recovering from a proxy
    /// that challenges it again is #172.
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

    /// `POST /logout`, best effort, in its own task so that cancelling the caller, such as a
    /// sign-in, doesn't stop the revoke. Returns the end-session URL if
    /// ``isAllowedEndSessionURL(_:server:)``.
    private func serverLogout(_ session: StoredSession, client: APIClient) async -> URL? {
        await Task {
            do {
                let server = await client.configuration.baseURL
                let response = try await client.send(
                    AuthEndpoints.logout(refreshToken: session.refreshToken, openIDSession: session.openIDSession))
                guard let string = response.redirectURL, let url = URL(string: string),
                    Self.isAllowedEndSessionURL(url, server: server)
                else { return nil }
                return url
            } catch {
                Log.auth.notice("Server sign-out failed: \(String(describing: type(of: error)), privacy: .public)")
                return nil
            }
        }.value
    }

    /// Whether to open `url`, an end-session URL the server at `server` returned: `https`, or
    /// `http` only from an `http` server. It can carry an OpenID `id_token_hint`, which an `https`
    /// account must not send in cleartext.
    static func isAllowedEndSessionURL(_ url: URL, server: URL) -> Bool {
        switch url.scheme?.lowercased() {
        case "https": true
        case "http": server.scheme?.lowercased() == "http"
        default: false
        }
    }
}

/// For clients that only send unauthenticated requests, such as `POST /logout`.
private struct NoTokens: TokenProvider {
    func tokens() async -> AuthTokens? { nil }
    func replaceTokens(expected: AuthTokens, with new: AuthTokens) async -> Bool { false }
    func expireSession(ifCurrent rejected: AuthTokens) async -> Bool { false }
}

/// A connection's natural key, which outlives a deleted row.
private struct ServerLogin: Hashable {
    let address: String
    let userId: String
}

/// What `AccountManager` publishes about the active connection, for ``AccountManager/restore(_:)``.
private struct LocalState {
    let state: AccountState
    let activeConnection: ServerConnectionDTO?
    let client: APIClient?
    let authorization: AuthResponse?
    let features: ServerFeatures?
    let lastError: AccountError?
}

/// What a sign-in captured when it was called.
private struct SignInAttempt {
    let operation: Int
    let latestLogout: Int
    let removals: Int
}

/// A sign-in the server accepted, from ``AccountManager/authenticate(local:username:password:)``
/// or ``AccountManager/authenticate(oidc:authenticator:)``, that isn't saved or active yet. Pass
/// it to ``AccountManager/activate(_:)``, or to ``AccountManager/discard(_:)`` to end its server
/// session. Dropping it saves nothing, but leaves that session open until the server expires it.
public struct AuthenticatedSignIn: Sendable {
    let server: ValidatedServer
    let method: ServerAuthMethod
    let result: LoginResult
    /// The manager's latest ``AccountManager/logout()`` and count of removals when the
    /// authentication started.
    let latestLogout: Int
    let removals: Int
}
