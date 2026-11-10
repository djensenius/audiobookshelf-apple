import Foundation

/// Credentials returned at sign-in.
public struct AuthTokens: Sendable, Hashable {
    public var accessToken: String
    /// `nil` for the legacy non-expiring token, or when the request didn't send
    /// `x-return-tokens: true` (the server then sets a cookie instead).
    public var refreshToken: String?

    public init(accessToken: String, refreshToken: String? = nil) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
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
/// (`null` for users created since). `/api/authorize` adds neither new field.
public struct AuthResponse: Sendable, Hashable, Decodable {
    public var user: User
    /// The library to open first, or `nil` if the user can't access any.
    public var userDefaultLibraryId: String?
    public var serverSettings: ServerSettings?
    private var accessToken: String?
    private var refreshToken: String?
    private var legacyToken: String?

    public init(
        user: User, userDefaultLibraryId: String? = nil, serverSettings: ServerSettings? = nil,
        tokens: AuthTokens? = nil
    ) {
        self.user = user
        self.userDefaultLibraryId = userDefaultLibraryId
        self.serverSettings = serverSettings
        accessToken = tokens?.accessToken
        refreshToken = tokens?.refreshToken
    }

    /// `accessToken`/`refreshToken` when the server sent them, otherwise the legacy `token` with
    /// no refresh token; `nil` if neither is present.
    public var tokens: AuthTokens? {
        if let accessToken, !accessToken.isEmpty {
            let refreshToken = refreshToken.flatMap { $0.isEmpty ? nil : $0 }
            return AuthTokens(accessToken: accessToken, refreshToken: refreshToken)
        }
        if let legacyToken, !legacyToken.isEmpty {
            return AuthTokens(accessToken: legacyToken)
        }
        return nil
    }

    enum CodingKeys: String, CodingKey {
        case user, userDefaultLibraryId, serverSettings
    }

    private enum TokenKeys: String, CodingKey {
        case accessToken, refreshToken, token
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        user = try container.decode(User.self, forKey: .user)
        userDefaultLibraryId = try container.decodeIfPresent(String.self, forKey: .userDefaultLibraryId)
        serverSettings = try container.decodeIfPresent(ServerSettings.self, forKey: .serverSettings)
        let tokens = try container.nestedContainer(keyedBy: TokenKeys.self, forKey: .user)
        accessToken = try tokens.decodeIfPresent(String.self, forKey: .accessToken)
        refreshToken = try tokens.decodeIfPresent(String.self, forKey: .refreshToken)
        legacyToken = try tokens.decodeIfPresent(String.self, forKey: .token)
    }
}
