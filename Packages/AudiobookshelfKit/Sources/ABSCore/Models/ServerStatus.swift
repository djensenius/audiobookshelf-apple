import Foundation

/// A sign-in method a server allows.
public enum AuthMethod: Sendable, Hashable, Codable, RawRepresentable {
    case local
    case openID
    /// A method this client doesn't know; the server's value is kept.
    case unknown(String)

    public init(rawValue: String) {
        switch rawValue {
        case "local": self = .local
        case "openid": self = .openID
        default: self = .unknown(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .local: "local"
        case .openID: "openid"
        case .unknown(let value): value
        }
    }
}

/// Sign-in form hints from `/status` (server `ServerSettings.authFormData`). The OpenID fields
/// are only sent when OpenID is enabled. The server doesn't expose its auto-register setting here.
public struct AuthFormData: Sendable, Hashable, Codable {
    /// Sanitised HTML set by the admin, shown on the sign-in screen.
    public var authLoginCustomMessage: String?
    public var authOpenIDButtonText: String?
    public var authOpenIDAutoLaunch: Bool?

    public init(
        authLoginCustomMessage: String? = nil, authOpenIDButtonText: String? = nil, authOpenIDAutoLaunch: Bool? = nil
    ) {
        self.authLoginCustomMessage = authLoginCustomMessage
        self.authOpenIDButtonText = authOpenIDButtonText
        self.authOpenIDAutoLaunch = authOpenIDAutoLaunch
    }
}

/// The unauthenticated `GET /status` response.
///
/// `isInit` is required: like the legacy connect form, a response without it is not treated as
/// an Audiobookshelf server. Uninitialised servers also send `ConfigPath` and `MetadataPath`,
/// which are ignored.
public struct ServerStatus: Sendable, Hashable, Codable {
    /// `"audiobookshelf"`.
    public var app: String?
    public var serverVersion: String?
    /// `false` until the root user has been created in the web client.
    public var isInit: Bool
    /// The server's UI language, for example `en-us`.
    public var language: String?
    public var authMethods: [AuthMethod]
    public var authFormData: AuthFormData?

    public init(
        app: String? = nil, serverVersion: String? = nil, isInit: Bool, language: String? = nil,
        authMethods: [AuthMethod] = [], authFormData: AuthFormData? = nil
    ) {
        self.app = app
        self.serverVersion = serverVersion
        self.isInit = isInit
        self.language = language
        self.authMethods = authMethods
        self.authFormData = authFormData
    }

    enum CodingKeys: String, CodingKey {
        case app, serverVersion, isInit, language, authMethods, authFormData
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        app = try container.decodeIfPresent(String.self, forKey: .app)
        serverVersion = try container.decodeIfPresent(String.self, forKey: .serverVersion)
        isInit = try container.decode(Bool.self, forKey: .isInit)
        language = try container.decodeIfPresent(String.self, forKey: .language)
        authMethods = try container.decodeIfPresent([AuthMethod].self, forKey: .authMethods) ?? []
        authFormData = try container.decodeIfPresent(AuthFormData.self, forKey: .authFormData)
    }

    /// Username and password sign-in. An empty method list means local only, as in the legacy app.
    public var supportsLocalLogin: Bool {
        authMethods.isEmpty || authMethods.contains(.local)
    }

    public var supportsOpenID: Bool {
        authMethods.contains(.openID)
    }
}
