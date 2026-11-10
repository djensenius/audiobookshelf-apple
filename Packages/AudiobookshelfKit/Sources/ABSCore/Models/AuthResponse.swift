import Foundation

/// Credentials returned at sign-in. Printing, dumping, or mirroring redacts the token values.
public struct AuthTokens: Sendable, Hashable {
    public var accessToken: String
    /// `nil` when the request didn't send `x-return-tokens: true` (the server then sets a
    /// cookie instead).
    public var refreshToken: String?

    public init(accessToken: String, refreshToken: String? = nil) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
    }
}

extension AuthTokens: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String {
        "AuthTokens(accessToken: <redacted>, refreshToken: \(refreshToken == nil ? "nil" : "<redacted>"))"
    }

    public var debugDescription: String { description }

    public var customMirror: Mirror {
        Mirror(
            self,
            children: [
                "accessToken": "<redacted>",
                "refreshToken": refreshToken == nil ? "nil" : "<redacted>",
            ],
            displayStyle: .struct)
    }
}

/// Who may send books to an e-reader device.
public enum EReaderAvailability: Sendable, Hashable, Codable, RawRepresentable {
    case adminOrUp
    case userOrUp
    case guestOrUp
    /// Only the users in ``EReaderDevice/users``.
    case specificUsers
    /// An option this client doesn't know; the server's value is kept.
    case unknown(String)

    public init(rawValue: String) {
        switch rawValue {
        case "adminOrUp": self = .adminOrUp
        case "userOrUp": self = .userOrUp
        case "guestOrUp": self = .guestOrUp
        case "specificUsers": self = .specificUsers
        default: self = .unknown(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .adminOrUp: "adminOrUp"
        case .userOrUp: "userOrUp"
        case .guestOrUp: "guestOrUp"
        case .specificUsers: "specificUsers"
        case .unknown(let value): value
        }
    }
}

/// A send-to-e-reader device the user may use (server `EmailSettings.getEReaderDevices`).
public struct EReaderDevice: Sendable, Hashable, Codable {
    public var name: String
    public var email: String?
    public var availabilityOption: EReaderAvailability?
    /// User IDs, used with ``EReaderAvailability/specificUsers``.
    public var users: [String]

    public init(
        name: String, email: String? = nil, availabilityOption: EReaderAvailability? = nil, users: [String] = []
    ) {
        self.name = name
        self.email = email
        self.availabilityOption = availabilityOption
        self.users = users
    }

    enum CodingKeys: String, CodingKey {
        case name, email, availabilityOption, users
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        email = try container.decodeIfPresent(String.self, forKey: .email)
        availabilityOption = try container.decodeIfPresent(EReaderAvailability.self, forKey: .availabilityOption)
        users = (try? container.decodeIfPresent([String].self, forKey: .users)) ?? []
    }
}

/// The subset of server settings (server `ServerSettings.toJSONForBrowser`) the app uses.
/// Other keys are ignored.
public struct ServerSettings: Sendable, Hashable, Codable {
    public var version: String?
    public var buildNumber: Int?
    public var language: String?
    /// Sort titles ignoring ``sortingPrefixes`` such as "the".
    public var sortingIgnorePrefix: Bool?
    public var sortingPrefixes: [String]?
    /// A date-fns pattern such as `MM/dd/yyyy`.
    public var dateFormat: String?
    /// A date-fns pattern such as `HH:mm`.
    public var timeFormat: String?
    /// The server host's IANA time zone.
    public var timeZone: String?

    public init(
        version: String? = nil, buildNumber: Int? = nil, language: String? = nil, sortingIgnorePrefix: Bool? = nil,
        sortingPrefixes: [String]? = nil, dateFormat: String? = nil, timeFormat: String? = nil,
        timeZone: String? = nil
    ) {
        self.version = version
        self.buildNumber = buildNumber
        self.language = language
        self.sortingIgnorePrefix = sortingIgnorePrefix
        self.sortingPrefixes = sortingPrefixes
        self.dateFormat = dateFormat
        self.timeFormat = timeFormat
        self.timeZone = timeZone
    }
}

/// The `POST /login`, `POST /auth/refresh`, OpenID callback, and `POST /api/authorize` response
/// (server `Auth.getUserLoginResponsePayload`).
///
/// The tokens are inside the `user` object. Servers 2.26 and later add `accessToken` and
/// `refreshToken` there on login and refresh, and still send the old non-expiring `token`
/// (`null` for users created since), which this client ignores. `/api/authorize` adds neither
/// new field. Printing, dumping, or mirroring redacts the tokens.
public struct AuthResponse: Sendable, Hashable, Decodable {
    public var user: User
    /// The library to open first, or `nil` if the user can't access any.
    public var userDefaultLibraryId: String?
    public var serverSettings: ServerSettings?
    /// E-reader devices this user may send to; `nil` if the server omitted them. Malformed
    /// devices are skipped.
    public var ereaderDevices: [EReaderDevice]?
    private var accessToken: String?
    private var refreshToken: String?

    public init(
        user: User, userDefaultLibraryId: String? = nil, serverSettings: ServerSettings? = nil,
        ereaderDevices: [EReaderDevice]? = nil, tokens: AuthTokens? = nil
    ) {
        self.user = user
        self.userDefaultLibraryId = userDefaultLibraryId
        self.serverSettings = serverSettings
        self.ereaderDevices = ereaderDevices
        accessToken = tokens?.accessToken
        refreshToken = tokens?.refreshToken
    }

    /// `accessToken`/`refreshToken`, or `nil` if the server sent no access token (as on
    /// `/api/authorize`). The legacy `user.token` is intentionally ignored: the minimum supported
    /// server is 2.26.0 (ADR 0007), which always sends `accessToken` on login and refresh.
    public var tokens: AuthTokens? {
        guard let accessToken, !accessToken.isEmpty else { return nil }
        let refreshToken = refreshToken.flatMap { $0.isEmpty ? nil : $0 }
        return AuthTokens(accessToken: accessToken, refreshToken: refreshToken)
    }

    enum CodingKeys: String, CodingKey {
        case user, userDefaultLibraryId, serverSettings, ereaderDevices
    }

    private enum TokenKeys: String, CodingKey {
        case accessToken, refreshToken
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        user = try container.decode(User.self, forKey: .user)
        userDefaultLibraryId = try container.decodeIfPresent(String.self, forKey: .userDefaultLibraryId)
        serverSettings = try container.decodeIfPresent(ServerSettings.self, forKey: .serverSettings)
        ereaderDevices = try? container.decodeLossyArrayIfPresent(EReaderDevice.self, forKey: .ereaderDevices)
        let tokens = try container.nestedContainer(keyedBy: TokenKeys.self, forKey: .user)
        accessToken = try tokens.decodeIfPresent(String.self, forKey: .accessToken)
        refreshToken = try tokens.decodeIfPresent(String.self, forKey: .refreshToken)
    }
}

extension AuthResponse: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String {
        "AuthResponse(user: \(user.id), userDefaultLibraryId: \(userDefaultLibraryId ?? "nil"), "
            + "tokens: \(tokens.map(String.init(describing:)) ?? "nil"))"
    }

    public var debugDescription: String { description }

    public var customMirror: Mirror {
        Mirror(
            self,
            children: [
                "user": user,
                "userDefaultLibraryId": userDefaultLibraryId as Any,
                "serverSettings": serverSettings as Any,
                "ereaderDevices": ereaderDevices as Any,
                "tokens": tokens as Any,
            ],
            displayStyle: .struct)
    }
}
