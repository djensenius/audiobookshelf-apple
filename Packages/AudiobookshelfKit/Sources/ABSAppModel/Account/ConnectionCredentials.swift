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

/// One connection's Keychain items, under account `connectionID.uuidString` (ADR 0003): the
/// session, and the custom headers (names and values, since values may be proxy credentials).
/// Both are JSON and `AfterFirstUnlock`, so refreshes work while the device is locked. An item
/// that doesn't decode reads as missing.
struct CredentialVault: Sendable {
    static let sessionService = "org.davidjensenius.Audiobookshelf.session"
    static let customHeadersService = "org.davidjensenius.Audiobookshelf.customHeaders"

    let keychain: any KeychainStoring

    func session(for id: UUID) throws(KeychainError) -> StoredSession? {
        try read(StoredSession.self, from: Self.item(Self.sessionService, id))
    }

    /// Stores `session`, or deletes the item for `nil`.
    func setSession(_ session: StoredSession?, for id: UUID) throws(KeychainError) {
        try write(session, to: Self.item(Self.sessionService, id))
    }

    func customHeaders(for id: UUID) throws(KeychainError) -> [String: String] {
        try read([String: String].self, from: Self.item(Self.customHeadersService, id)) ?? [:]
    }

    /// Stores `headers`, or deletes the item when there are none.
    func setCustomHeaders(_ headers: [String: String], for id: UUID) throws(KeychainError) {
        try write(headers.isEmpty ? nil : headers, to: Self.item(Self.customHeadersService, id))
    }

    func removeAll(for id: UUID) throws(KeychainError) {
        try keychain.delete(Self.item(Self.sessionService, id))
        try keychain.delete(Self.item(Self.customHeadersService, id))
    }

    static func item(_ service: String, _ id: UUID) -> KeychainItem {
        KeychainItem(service: service, account: id.uuidString)
    }

    private func read<Value: Decodable>(_ type: Value.Type, from item: KeychainItem) throws(KeychainError) -> Value? {
        guard let data = try keychain.data(for: item) else { return nil }
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            Log.auth.error("Ignoring an unreadable Keychain item in \(item.service, privacy: .public)")
            return nil
        }
    }

    private func write<Value: Encodable>(_ value: Value?, to item: KeychainItem) throws(KeychainError) {
        guard let value else { return try keychain.delete(item) }
        // Encoding strings and dictionaries of strings can't fail.
        guard let data = try? JSONEncoder().encode(value) else { throw KeychainError(status: errSecParam) }
        try keychain.set(data, for: item, accessibility: .afterFirstUnlock)
    }
}

/// The ``TokenProvider`` for one connection's ``APIClient``, backed by the Keychain.
///
/// ``AccountManager`` keeps one instance per connection for the life of the process, so the
/// compare-and-swap also covers refreshes still in flight from a client it has replaced. Memory
/// is the source of truth once loaded: a refreshed pair that couldn't be written is kept and the
/// write is retried before the tokens are next read.
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

    /// The stored session and custom headers, read from the Keychain the first time.
    func load() throws(KeychainError) -> (session: StoredSession?, customHeaders: [String: String]) {
        if !isLoaded {
            let headers = try vault.customHeaders(for: connectionID)
            // A sign-out whose delete failed is still pending; the Keychain copy is stale.
            if !needsWrite { session = try vault.session(for: connectionID) }
            customHeaders = headers
            isLoaded = true
        }
        return (session, customHeaders)
    }

    /// Stores a new sign-in and returns its generation. Throws, keeping the previous session, if
    /// the Keychain can't be written.
    func signIn(_ new: StoredSession, customHeaders headers: [String: String]) throws(KeychainError) -> Int {
        try vault.setCustomHeaders(headers, for: connectionID)
        customHeaders = headers
        try vault.setSession(new, for: connectionID)
        session = new
        isLoaded = true
        needsWrite = false
        generation += 1
        return generation
    }

    /// Ends the session, keeping the custom headers, and returns the session that ended for the
    /// server sign-out.
    func signOut() -> StoredSession? {
        let ended = try? load().session
        clearSession()
        return ended
    }

    /// Deletes both Keychain items. Returns what they held, for the server sign-out. Throws,
    /// changing nothing in memory, if a delete fails.
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
        writeIfNeeded()
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

    private func clearSession() {
        session = nil
        generation += 1
        needsWrite = true
        writeIfNeeded()
    }

    private func writeIfNeeded() {
        guard needsWrite else { return }
        do {
            try vault.setSession(session, for: connectionID)
            needsWrite = false
        } catch {
            Log.auth.error("Couldn't save a connection's session: \(error.description, privacy: .public)")
        }
    }
}
