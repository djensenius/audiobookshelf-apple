import ABSAPI
import ABSCore
import ABSData
import Foundation
import Observation

/// One row of the custom headers editor.
public struct CustomHeader: Sendable, Hashable, Identifiable {
    public let id: UUID
    public var name: String
    public var value: String

    public init(id: UUID = UUID(), name: String = "", value: String = "") {
        self.id = id
        self.name = name
        self.value = value
    }

    var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    var trimmedValue: String { value.trimmingCharacters(in: .whitespacesAndNewlines) }
    /// A row with neither a name nor a value, which is ignored.
    var isBlank: Bool { trimmedName.isEmpty && trimmedValue.isEmpty }

    /// What's wrong with the row, or `nil` if it's valid or blank.
    public var problem: ConnectFailure? {
        guard !isBlank else { return nil }
        let name = trimmedName
        if APIClientConfiguration.reservedHeaderNames.contains(name.lowercased()) {
            return .reservedHeader(name: name)
        }
        guard !name.isEmpty, name.unicodeScalars.allSatisfy(Self.tokenCharacters.contains),
            !trimmedValue.unicodeScalars.contains(where: Self.lineBreaks.contains)
        else { return .invalidCustomHeader }
        return nil
    }

    /// HTTP field name characters (RFC 9110 `token`).
    private static let tokenCharacters = CharacterSet(
        charactersIn: "!#$%&'*+-.^_`|~0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz")
    private static let lineBreaks = CharacterSet.newlines.union(CharacterSet(charactersIn: "\0"))
}

/// The server connect and sign-in flow, a port of `pages/connect.vue` and
/// `ServerConnectForm.vue`.
///
/// ```text
/// servers ─select─▶ signingIn(.savedSession) ─▶ done
///    │                     └─ no session ─▶ login
///    └─add─▶ address ─▶ validating ─▶ login ─▶ signingIn(.password / .openID) ─▶ done
/// ```
///
/// A failure returns to the step the user can fix it from (``Phase/address``, ``Phase/login``
/// or ``Phase/servers``) with ``failure`` set; a cancelled OpenID sign-in returns to
/// ``Phase/login`` without one. Selecting a saved server first reads its status with its saved
/// custom headers, as the legacy app pinged it, so an unreachable server or a denied local
/// network permission shows here rather than after going offline.
@MainActor @Observable
public final class ConnectViewModel {
    public enum Phase: Sendable, Hashable {
        /// Saved servers to pick from, or add one.
        case servers
        /// Entering a server address and custom headers.
        case address
        /// Reading the server's `/status`.
        case validating
        /// The status was read: sign in with a password or OpenID.
        case login
        case signingIn(SignInMethod)
        /// Signed in. The flow is finished.
        case done
    }

    public enum SignInMethod: Sendable, Hashable {
        case password
        case openID
        /// Checking a saved server and resuming its saved session.
        case savedSession
    }

    public private(set) var phase: Phase
    /// Why the last action failed, shown on the current step.
    public private(set) var failure: ConnectFailure?
    public var address = ""
    public var customHeaders: [CustomHeader] = []
    public var username = ""
    public var password = ""
    /// The server whose status was read, from ``Phase/login`` on.
    public private(set) var server: ConnectServer?
    /// The saved server being resumed or signed in to again.
    public private(set) var savedConnection: ServerConnectionDTO?

    private enum Action {
        case validate
        case select(ServerConnectionDTO)
    }

    @ObservationIgnored private let backend: any ConnectBackend
    @ObservationIgnored private let localNetwork: any LocalNetworkAccessChecking
    /// Bumped by every action, so the result of one the user has left is dropped.
    @ObservationIgnored private var attempt = 0
    /// The action ``retry()`` repeats.
    @ObservationIgnored private var lastAction: Action?

    public init(backend: any ConnectBackend, localNetwork: any LocalNetworkAccessChecking = SystemLocalNetworkAccess())
    {
        self.backend = backend
        self.localNetwork = localNetwork
        phase = backend.connections.isEmpty ? .address : .servers
    }

    /// The app's flow: validates with `validator` and signs in through `accounts`.
    public convenience init(
        accounts: AccountManager, validator: ServerValidator = ServerValidator(),
        localNetwork: any LocalNetworkAccessChecking = SystemLocalNetworkAccess()
    ) {
        self.init(backend: AccountConnectBackend(accounts: accounts, validator: validator), localNetwork: localNetwork)
    }

    // MARK: - State

    public var savedServers: [ServerConnectionDTO] { backend.connections }

    public var isBusy: Bool {
        switch phase {
        case .validating, .signingIn: true
        case .servers, .address, .login, .done: false
        }
    }

    public var canGoBack: Bool {
        switch phase {
        case .address: !savedServers.isEmpty
        case .validating, .login: true
        case .servers, .signingIn, .done: false
        }
    }

    /// Username and password sign-in. Hidden for OpenID-only servers.
    public var showsPasswordLogin: Bool { server?.status.supportsLocalLogin ?? false }
    public var showsOpenIDLogin: Bool { server?.status.supportsOpenID ?? false }
    /// The OpenID button's label set by the server's admin, or `nil` for the default.
    public var openIDButtonTitle: String? { Self.nonBlank(server?.status.authFormData?.authOpenIDButtonText) }
    /// The admin's sign-in message, as sanitised HTML.
    public var loginMessageHTML: String? { Self.nonBlank(server?.status.authFormData?.authLoginCustomMessage) }
    /// Audiobookshelf allows an empty password, so only the username is required.
    public var canSignIn: Bool { phase == .login && showsPasswordLogin && !username.isEmpty }

    /// Whether to warn that the connection is plain `http` to a public host (ADR 0002). Before
    /// validation, from a typed `http://` address; after, from the server's address, which may
    /// have fallen back to `http`. The warning doesn't block connecting.
    public var showsPlainHTTPWarning: Bool {
        switch phase {
        case .address, .validating:
            guard let typed = ServerAddress(address), !typed.isSchemeInferred else { return false }
            return typed.isPlainHTTPOnPublicHost
        case .login, .signingIn(.password), .signingIn(.openID):
            return server?.address.isPlainHTTPOnPublicHost ?? false
        case .servers, .signingIn(.savedSession), .done:
            return false
        }
    }

    // MARK: - Actions

    /// Starts entering a new server.
    public func addServer() {
        guard !isBusy else { return }
        next()
        failure = nil
        server = nil
        savedConnection = nil
        address = ""
        customHeaders = []
        username = ""
        password = ""
        phase = .address
    }

    public func goBack() {
        guard canGoBack else { return }
        next()
        failure = nil
        switch phase {
        case .address:
            phase = .servers
        case .validating:
            phase = .address
        case .login:
            server = nil
            password = ""
            if savedConnection != nil, !savedServers.isEmpty {
                savedConnection = nil
                phase = .servers
            } else {
                phase = .address
            }
        case .servers, .signingIn, .done:
            break
        }
    }

    /// Reads the typed server's status with the custom headers, then moves to ``Phase/login``.
    public func submitAddress() async {
        guard phase == .address else { return }
        await validate(attempt: next())
    }

    /// After ``ConnectFailure/httpsUnavailable(_:)``, connects to the `http` address, sending the
    /// custom headers unencrypted.
    public func connectWithoutEncryption() async {
        guard phase == .address, case .httpsUnavailable(let fallback)? = failure else { return }
        address = fallback.description
        await validate(attempt: next())
    }

    /// Resumes a saved server's session. Its status is read first with its saved custom headers;
    /// without a session it moves to ``Phase/login`` with the username filled in.
    public func select(_ connection: ServerConnectionDTO) async {
        guard !isBusy else { return }
        let attempt = next()
        lastAction = .select(connection)
        failure = nil
        server = nil
        savedConnection = connection
        phase = .signingIn(.savedSession)
        do {
            let headers = try await backend.customHeaders(for: connection.id)
            try ensureCurrent(attempt)
            let server = try await backend.validate(address: connection.address, customHeaders: headers)
            try ensureCurrent(attempt)
            let resumed = try await backend.resume(connection.id)
            try ensureCurrent(attempt)
            guard !resumed else { return finish() }
            address = connection.address
            customHeaders = headers.sorted { $0.key < $1.key }.map { CustomHeader(name: $0.key, value: $0.value) }
            username = connection.username
            password = ""
            self.server = server
            phase = .login
        } catch {
            guard isCurrent(attempt) else { return }
            let failure = await failure(for: error, address: connection.address)
            guard isCurrent(attempt) else { return }
            self.failure = failure
            savedConnection = nil
            phase = .servers
        }
    }

    /// Forgets a saved server, its session and its custom headers.
    public func remove(_ connection: ServerConnectionDTO) async {
        guard !isBusy else { return }
        failure = nil
        do {
            try await backend.remove(connection.id)
        } catch {
            failure = ConnectFailure(error)
        }
        if phase == .servers, savedServers.isEmpty { phase = .address }
    }

    public func signIn() async {
        guard canSignIn, let server else { return }
        await signIn(.password) { [backend, username, password] in
            try await backend.signIn(to: server, username: username, password: password)
        }
    }

    /// Signs in through the server's OpenID provider in `authenticator`'s browser session.
    public func signInWithOpenID(using authenticator: any WebAuthenticator) async {
        guard phase == .login, showsOpenIDLogin, let server else { return }
        await signIn(.openID) { [backend] in
            try await backend.signIn(openIDTo: server, authenticator: authenticator)
        }
    }

    /// Repeats the server check that failed, for example when the app becomes active again
    /// after the user turned on local network access.
    public func retry() async {
        switch lastAction {
        case .validate? where phase == .address:
            await submitAddress()
        case .select(let connection)? where phase == .servers:
            await select(connection)
        default:
            break
        }
    }

    // MARK: - Private

    private func validate(attempt: Int) async {
        lastAction = .validate
        let headers: [String: String]
        do {
            headers = try Self.headers(from: customHeaders)
        } catch {
            failure = error
            return
        }
        guard !ServerAddress.connectionCandidates(for: address).isEmpty else {
            failure = .invalidAddress
            return
        }
        let typed = address
        failure = nil
        phase = .validating
        do {
            let server = try await backend.validate(address: typed, customHeaders: headers)
            guard isCurrent(attempt) else { return }
            self.server = server
            password = ""
            phase = .login
        } catch {
            guard isCurrent(attempt) else { return }
            let failure = await failure(for: error, address: typed)
            guard isCurrent(attempt) else { return }
            self.failure = failure
            phase = .address
        }
    }

    private func signIn(_ method: SignInMethod, _ body: @MainActor () async throws -> Void) async {
        let attempt = next()
        failure = nil
        phase = .signingIn(method)
        do {
            try await body()
            guard isCurrent(attempt) else { return }
            finish()
        } catch {
            guard isCurrent(attempt) else { return }
            failure = ConnectFailure(error)
            phase = .login
        }
    }

    private func finish() {
        password = ""
        failure = nil
        phase = .done
    }

    /// Maps `error`, and for a local host that couldn't be reached, checks whether the local
    /// network permission is off (ADR 0002).
    private func failure(for error: any Error, address: String) async -> ConnectFailure? {
        let failure = ConnectFailure(error)
        guard failure == .cannotConnect, let server = ServerAddress(address), server.hostScope == .localNetwork,
            let host = server.url.host(percentEncoded: false)
        else { return failure }
        let port = server.url.port ?? (server.url.scheme == "https" ? 443 : 80)
        return await localNetwork.isDenied(host: host, port: port) ? .localNetworkDenied : failure
    }

    /// The custom headers to send: blank rows dropped, names and values trimmed, and a later row
    /// replacing an earlier one whose name differs only in case.
    static func headers(from rows: [CustomHeader]) throws(ConnectFailure) -> [String: String] {
        var headers: [String: String] = [:]
        for row in rows where !row.isBlank {
            if let problem = row.problem { throw problem }
            let name = row.trimmedName
            for existing in headers.keys where existing.caseInsensitiveCompare(name) == .orderedSame {
                headers[existing] = nil
            }
            headers[name] = row.trimmedValue
        }
        return headers
    }

    @discardableResult
    private func next() -> Int {
        attempt += 1
        return attempt
    }

    private func isCurrent(_ attempt: Int) -> Bool { attempt == self.attempt }

    private func ensureCurrent(_ attempt: Int) throws {
        guard isCurrent(attempt) else { throw CancellationError() }
    }

    private static func nonBlank(_ text: String?) -> String? {
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return text
    }
}
