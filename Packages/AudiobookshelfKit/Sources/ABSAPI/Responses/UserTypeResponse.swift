import ABSCore
import Foundation

/// `GET /api/me` reduced to the account type; every other field is ignored. A missing or
/// malformed `type` reads as ``UserType/user``, the least privileged type that sees the stats.
public struct UserTypeResponse: Decodable, Sendable, Hashable {
    public var type: UserType

    public init(type: UserType) {
        self.type = type
    }

    /// Admin or root, as the server's `isAdminOrUp`.
    public var isAdminOrUp: Bool { type == .admin || type == .root }

    enum CodingKeys: String, CodingKey {
        case type
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = (try? container.decodeIfPresent(UserType.self, forKey: .type)) ?? .user
    }
}
