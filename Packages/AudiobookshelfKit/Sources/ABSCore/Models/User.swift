import Foundation

/// A user's account type.
public enum UserType: Sendable, Hashable, Codable, RawRepresentable {
    case root
    case admin
    case user
    case guest
    /// A type this client doesn't know; the server's value is kept.
    case unknown(String)

    public init(rawValue: String) {
        switch rawValue {
        case "root": self = .root
        case "admin": self = .admin
        case "user": self = .user
        case "guest": self = .guest
        default: self = .unknown(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .root: "root"
        case .admin: "admin"
        case .user: "user"
        case .guest: "guest"
        case .unknown(let value): value
        }
    }
}

/// A user's permissions. Missing flags decode as `false`. The server moves the
/// `librariesAccessible` and `itemTagsSelected` lists out of this object onto ``User``.
public struct UserPermissions: Sendable, Hashable, Codable {
    public var download: Bool
    public var update: Bool
    public var delete: Bool
    public var upload: Bool
    public var createEreader: Bool
    public var accessAllLibraries: Bool
    public var accessAllTags: Bool
    public var accessExplicitContent: Bool
    /// When `true`, ``User/itemTagsSelected`` is a deny list rather than an allow list.
    public var selectedTagsNotAccessible: Bool

    public init(
        download: Bool = false, update: Bool = false, delete: Bool = false, upload: Bool = false,
        createEreader: Bool = false, accessAllLibraries: Bool = false, accessAllTags: Bool = false,
        accessExplicitContent: Bool = false, selectedTagsNotAccessible: Bool = false
    ) {
        self.download = download
        self.update = update
        self.delete = delete
        self.upload = upload
        self.createEreader = createEreader
        self.accessAllLibraries = accessAllLibraries
        self.accessAllTags = accessAllTags
        self.accessExplicitContent = accessExplicitContent
        self.selectedTagsNotAccessible = selectedTagsNotAccessible
    }

    enum CodingKeys: String, CodingKey {
        case download, update, delete, upload, createEreader, accessAllLibraries, accessAllTags
        case accessExplicitContent, selectedTagsNotAccessible
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func flag(_ key: CodingKeys) throws -> Bool {
            try container.decodeIfPresent(Bool.self, forKey: key) ?? false
        }
        download = try flag(.download)
        update = try flag(.update)
        delete = try flag(.delete)
        upload = try flag(.upload)
        createEreader = try flag(.createEreader)
        accessAllLibraries = try flag(.accessAllLibraries)
        accessAllTags = try flag(.accessAllTags)
        accessExplicitContent = try flag(.accessExplicitContent)
        selectedTagsNotAccessible = try flag(.selectedTagsNotAccessible)
    }
}

/// The signed-in user, from `user` in the login and `/api/authorize` responses and from
/// `GET /api/me` (server `User.toOldJSONForBrowser`).
///
/// Tokens in the same JSON object are deliberately not stored here; read them from
/// ``AuthResponse/tokens``. `mediaProgress` and `bookmarks` skip malformed entries so one bad
/// row doesn't fail sign-in.
public struct User: Sendable, Hashable, Codable, Identifiable {
    public let id: String
    public var username: String
    public var email: String?
    public var type: UserType
    public var mediaProgress: [MediaProgress]
    public var seriesHideFromContinueListening: [String]
    public var bookmarks: [AudioBookmark]
    public var isActive: Bool
    public var isLocked: Bool
    /// Epoch milliseconds.
    public var lastSeen: Int?
    /// Epoch milliseconds.
    public var createdAt: Int?
    public var permissions: UserPermissions
    /// Library IDs the user may open when `permissions.accessAllLibraries` is `false`.
    public var librariesAccessible: [String]
    /// Tags that allow (or, with `permissions.selectedTagsNotAccessible`, deny) access when
    /// `permissions.accessAllTags` is `false`.
    public var itemTagsSelected: [String]
    public var hasOpenIDLink: Bool?

    public init(
        id: String, username: String, email: String? = nil, type: UserType = .user,
        mediaProgress: [MediaProgress] = [], seriesHideFromContinueListening: [String] = [],
        bookmarks: [AudioBookmark] = [], isActive: Bool = true, isLocked: Bool = false, lastSeen: Int? = nil,
        createdAt: Int? = nil, permissions: UserPermissions = UserPermissions(), librariesAccessible: [String] = [],
        itemTagsSelected: [String] = [], hasOpenIDLink: Bool? = nil
    ) {
        self.id = id
        self.username = username
        self.email = email
        self.type = type
        self.mediaProgress = mediaProgress
        self.seriesHideFromContinueListening = seriesHideFromContinueListening
        self.bookmarks = bookmarks
        self.isActive = isActive
        self.isLocked = isLocked
        self.lastSeen = lastSeen
        self.createdAt = createdAt
        self.permissions = permissions
        self.librariesAccessible = librariesAccessible
        self.itemTagsSelected = itemTagsSelected
        self.hasOpenIDLink = hasOpenIDLink
    }

    enum CodingKeys: String, CodingKey {
        case id, username, email, type, mediaProgress, seriesHideFromContinueListening, bookmarks, isActive
        case isLocked, lastSeen, createdAt, permissions, librariesAccessible, itemTagsSelected, hasOpenIDLink
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        username = try container.decode(String.self, forKey: .username)
        email = try container.decodeIfPresent(String.self, forKey: .email)
        type = try container.decodeIfPresent(UserType.self, forKey: .type) ?? .user
        mediaProgress = try container.decodeLossyArrayIfPresent(MediaProgress.self, forKey: .mediaProgress) ?? []
        seriesHideFromContinueListening =
            try container.decodeIfPresent([String].self, forKey: .seriesHideFromContinueListening) ?? []
        bookmarks = try container.decodeLossyArrayIfPresent(AudioBookmark.self, forKey: .bookmarks) ?? []
        isActive = try container.decodeIfPresent(Bool.self, forKey: .isActive) ?? true
        isLocked = try container.decodeIfPresent(Bool.self, forKey: .isLocked) ?? false
        lastSeen = try container.decodeIfPresent(Int.self, forKey: .lastSeen)
        createdAt = try container.decodeIfPresent(Int.self, forKey: .createdAt)
        permissions = try container.decodeIfPresent(UserPermissions.self, forKey: .permissions) ?? UserPermissions()
        librariesAccessible = try container.decodeIfPresent([String].self, forKey: .librariesAccessible) ?? []
        itemTagsSelected = try container.decodeIfPresent([String].self, forKey: .itemTagsSelected) ?? []
        hasOpenIDLink = try container.decodeIfPresent(Bool.self, forKey: .hasOpenIDLink)
    }
}
