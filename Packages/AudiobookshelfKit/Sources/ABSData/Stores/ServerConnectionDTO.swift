import Foundation

/// A saved server connection (`ServerConnectionRecord`) as a `Sendable` value.
public struct ServerConnectionDTO: Sendable, Equatable, Identifiable {
    public var id: UUID
    /// The normalized base URL (`ServerAddress.description`).
    public var address: String
    public var userId: String
    public var username: String
    public var authMethod: ServerAuthMethod
    public var serverVersion: String?
    public var createdAt: Date
    public var lastUsedAt: Date?
    public var isDisconnected: Bool
    public var disconnectedAt: Date?
    /// When the user signed out; a session saved in the Keychain before then is stale.
    public var signedOutAt: Date?

    public init(
        id: UUID,
        address: String,
        userId: String,
        username: String,
        authMethod: ServerAuthMethod,
        serverVersion: String? = nil,
        createdAt: Date,
        lastUsedAt: Date? = nil,
        isDisconnected: Bool = false,
        disconnectedAt: Date? = nil,
        signedOutAt: Date? = nil
    ) {
        self.id = id
        self.address = address
        self.userId = userId
        self.username = username
        self.authMethod = authMethod
        self.serverVersion = serverVersion
        self.createdAt = createdAt
        self.lastUsedAt = lastUsedAt
        self.isDisconnected = isDisconnected
        self.disconnectedAt = disconnectedAt
        self.signedOutAt = signedOutAt
    }
}

extension ServerConnectionDTO {
    init(_ record: ServerConnectionRecord) {
        self.init(
            id: record.id,
            address: record.address,
            userId: record.userId,
            username: record.username,
            // Only `ServerConnectionStore` writes the raw value, always from a `ServerAuthMethod`.
            authMethod: record.authMethodValue ?? .local,
            serverVersion: record.serverVersion,
            createdAt: record.createdAt,
            lastUsedAt: record.lastUsedAt,
            isDisconnected: record.isDisconnected,
            disconnectedAt: record.disconnectedAt,
            signedOutAt: record.signedOutAt
        )
    }
}
