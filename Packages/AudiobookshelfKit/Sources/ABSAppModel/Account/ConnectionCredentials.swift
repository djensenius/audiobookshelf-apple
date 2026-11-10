import ABSAPI
import ABSCore
import Foundation
import Security

/// A connection's session as stored in the Keychain: the token pair and, after an OpenID
/// sign-in, the cookies `POST /logout` needs.
struct StoredSession: Sendable, Hashable, Codable {
    var accessToken: String
    var refreshToken: String
    var openIDSession: OpenIDSessionCookies?

    init(tokens: AuthTokens, openIDSession: OpenIDSessionCookies?) {
        accessToken = tokens.accessToken
        refreshToken = tokens.refreshToken
        self.openIDSession = openIDSession
    }

    var tokens: AuthTokens { AuthTokens(accessToken: accessToken, refreshToken: refreshToken) }
}

extension StoredSession: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    var description: String { "StoredSession(<redacted>)" }
    var debugDescription: String { description }
    var customMirror: Mirror { Mirror(self, children: [], displayStyle: .struct) }
}

/// One connection's credentials, in one Keychain item under account `connectionID.uuidString`
/// (ADR 0003): the session, and the custom headers (names and values, since values may be proxy
/// credentials). One item makes each change a single Keychain call that succeeds or changes
/// nothing, so a failed sign-in can't leave its headers next to the previous session, and a
/// failed removal can't leave half. The item is JSON and `AfterFirstUnlock`, so refreshes work
/// while the device is locked; one that doesn't decode reads as missing.
struct CredentialVault: Sendable {
    static let service = "org.davidjensenius.Audiobookshelf.credentials"

    private struct Stored: Codable {
        var session: StoredSession?
        var customHeaders: [String: String]
    }

    let keychain: any KeychainStoring

    func credentials(for id: UUID) throws(KeychainError) -> (session: StoredSession?, customHeaders: [String: String]) {
        let item = Self.item(id)
        guard let data = try keychain.data(for: item) else { return (nil, [:]) }
        guard let stored = try? JSONDecoder().decode(Stored.self, from: data) else {
            Log.auth.error("Ignoring an unreadable Keychain item in \(item.service, privacy: .public)")
            return (nil, [:])
        }
        return (stored.session, stored.customHeaders)
    }

    func session(for id: UUID) throws(KeychainError) -> StoredSession? {
        try credentials(for: id).session
    }

    func customHeaders(for id: UUID) throws(KeychainError) -> [String: String] {
        try credentials(for: id).customHeaders
    }

    /// Stores both in one write, or deletes the item when there's neither.
    func setCredentials(
        session: StoredSession?, customHeaders: [String: String], for id: UUID
    ) throws(KeychainError) {
        guard session != nil || !customHeaders.isEmpty else { return try removeAll(for: id) }
        // Encoding strings and dictionaries of strings can't fail.
        guard let data = try? JSONEncoder().encode(Stored(session: session, customHeaders: customHeaders)) else {
            throw KeychainError(status: errSecParam)
        }
        try keychain.set(data, for: Self.item(id), accessibility: .afterFirstUnlock)
    }

    func removeAll(for id: UUID) throws(KeychainError) {
        try keychain.delete(Self.item(id))
    }

    static func item(_ id: UUID) -> KeychainItem {
        KeychainItem(service: service, account: id.uuidString)
    }
}

/// The ``TokenProvider`` for one connection's ``APIClient``, backed by the Keychain.
///
/// ``AccountManager`` keeps one instance per connection for the life of the process, so the
/// compare-and-swap also covers refreshes still in flight from a client it has replaced. Memory
/// is the source of truth once loaded: a refreshed pair or a sign-out that couldn't be written is
/// kept, and the write is retried whenever the session is next loaded or read.
///
/// A sign-out while a refresh is in flight ends the session it holds, so `POST /logout` sends
/// the refresh token from before the refresh. The refreshed pair is then rejected by
/// ``replaceTokens(expected:with:)`` and never stored; if the server had already rotated the
/// token, its session for the new token stays until it expires there.
actor ConnectionCredentials: TokenProvider {
    nonisolated let connectionID: UUID
    private let vault: CredentialVault
    /// Runs after a rejected refresh token ended the session, before ``APIClient`` throws
    /// `sessionExpired`, with the ``generation`` that ended it.
    private let onExpire: @MainActor @Sendable (UUID, Int) -> Void
    private var session: StoredSession?
    private var customHeaders: [String: String] = [:]
    private var isLoaded = false
    /// `session` hasn't been written to the Keychain yet.
    private var needsWrite = false
    /// Bumped by every sign-in, sign-out, expiry and removal, so ``AccountManager`` can ignore an
    /// expiry that a newer sign-in has already replaced.
    private var generation = 0

    init(connectionID: UUID, vault: CredentialVault, onExpire: @escaping @MainActor @Sendable (UUID, Int) -> Void) {
        self.connectionID = connectionID
        self.vault = vault
        self.onExpire = onExpire
    }

    /// The stored session and custom headers, read from the Keychain the first time. Retries a
    /// pending write.
    func load() throws(KeychainError) -> (session: StoredSession?, customHeaders: [String: String]) {
        try readIfNeeded()
        writeIfNeeded()
        return (session, customHeaders)
    }

    /// Stores a new sign-in. Returns its generation and the session it replaced, for the server
    /// sign-out. Throws, keeping the previous session and custom headers in memory and in the
    /// Keychain, if the Keychain can't be written.
    func signIn(
        _ new: StoredSession, customHeaders headers: [String: String]
    ) throws(KeychainError) -> (generation: Int, replaced: StoredSession?) {
        let replaced = try? load().session
        try vault.setCredentials(session: new, customHeaders: headers, for: connectionID)
        session = new
        customHeaders = headers
        isLoaded = true
        needsWrite = false
        generation += 1
        return (generation, replaced)
    }

    /// Ends the session, keeping the custom headers. Returns the session that ended, for the
    /// server sign-out, and the error if the Keychain item couldn't be deleted yet.
    /// - Parameter expected: Only sign out if the session is still the one this generation
    ///   stored.
    func signOut(ifGeneration expected: Int? = nil) -> (ended: StoredSession?, deleteError: KeychainError?) {
        guard expected == nil || expected == generation else { return (nil, nil) }
        let ended = try? load().session
        return (ended, clearSession())
    }

    /// Deletes the Keychain item. Returns what it held, for the server sign-out. Throws, changing
    /// nothing in memory or in the Keychain, if the delete fails.
    func removeAll() throws(KeychainError) -> (session: StoredSession?, customHeaders: [String: String]) {
        let loaded = (try? load()) ?? (session, customHeaders)
        try vault.removeAll(for: connectionID)
        session = nil
        customHeaders = [:]
        isLoaded = true
        needsWrite = false
        generation += 1
        return loaded
    }

    // MARK: - TokenProvider

    func tokens() -> AuthTokens? {
        do {
            _ = try load()
        } catch {
            Log.auth.error("Couldn't read a connection's session: \(error.description, privacy: .public)")
            return nil
        }
        return session?.tokens
    }

    func replaceTokens(expected: AuthTokens, with new: AuthTokens) -> Bool {
        guard let current = session, current.tokens == expected else { return false }
        session = StoredSession(tokens: new, openIDSession: current.openIDSession)
        needsWrite = true
        writeIfNeeded()
        return true
    }

    func expireSession(ifCurrent rejected: AuthTokens) async -> Bool {
        guard let current = session, current.tokens == rejected else { return false }
        clearSession()
        await onExpire(connectionID, generation)
        return true
    }

    // MARK: - Private

    @discardableResult
    private func clearSession() -> KeychainError? {
        session = nil
        generation += 1
        needsWrite = true
        return writeIfNeeded()
    }

    private func readIfNeeded() throws(KeychainError) {
        guard !isLoaded else { return }
        let stored = try vault.credentials(for: connectionID)
        // A sign-out whose delete failed is still pending; the Keychain copy is stale.
        if !needsWrite { session = stored.session }
        customHeaders = stored.customHeaders
        isLoaded = true
    }

    @discardableResult
    private func writeIfNeeded() -> KeychainError? {
        guard needsWrite else { return nil }
        do {
            // The custom headers are written with the session, so they must be read first.
            try readIfNeeded()
            try vault.setCredentials(session: session, customHeaders: customHeaders, for: connectionID)
            needsWrite = false
            return nil
        } catch {
            Log.auth.error("Couldn't save a connection's session: \(error.description, privacy: .public)")
            return error
        }
    }
}
