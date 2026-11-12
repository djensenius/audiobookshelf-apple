import ABSAPI
import ABSDownloads
import Foundation

/// Download credentials from the account layer: each connection's ``APIClient``, found through an
/// injected lookup, supplies its configuration and access token. Refreshes go through the client's
/// single refresh (``APIClient/accessToken(replacing:)``), so download parts and the app's own API
/// calls share it.
public struct AccountDownloadCredentials: DownloadCredentialProviding {
    /// Reads an access token from a connection's client.
    public typealias TokenRead = @Sendable (APIClient) async throws -> String?

    private let access: @Sendable (UUID, TokenRead) async throws -> (client: APIClient, token: String)?

    /// - Parameter client: the ``APIClient`` of a connection, or `nil` when the connection is
    ///   signed out or removed.
    public init(client: @escaping @Sendable (UUID) async -> APIClient?) {
        self.init { connectionID, read in
            guard let client = await client(connectionID), let token = try await read(client) else { return nil }
            return (client, token)
        }
    }

    /// - Parameter access: runs the read on a connection's ``APIClient`` and returns the client
    ///   and token, or `nil` when the connection is signed out or removed, or the token may not
    ///   belong to the client's configuration (`AccountManager.downloadAccess(for:read:)`).
    public init(access: @escaping @Sendable (UUID, TokenRead) async throws -> (client: APIClient, token: String)?) {
        self.access = access
    }

    /// The client's configuration and stored access token, without any request; `nil` when there is
    /// no client for the connection or it is signed out.
    public func currentCredentials(for connectionID: UUID) async -> DownloadCredentials? {
        guard let (client, token) = try? await access(connectionID, { await $0.currentAccessToken() }) else {
            return nil
        }
        return DownloadCredentials(configuration: await client.configuration, accessToken: token)
    }

    /// The client's configuration and an access token from ``APIClient/accessToken(replacing:)``.
    ///
    /// - Throws: ``APIError/notAuthenticated`` when there is no client for the connection, otherwise
    ///   what ``APIClient/accessToken(replacing:)`` throws.
    public func credentials(for connectionID: UUID, replacing rejectedAccessToken: String?) async throws
        -> DownloadCredentials
    {
        guard
            let (client, token) = try await access(
                connectionID, { try await $0.accessToken(replacing: rejectedAccessToken) })
        else { throw APIError.notAuthenticated }
        return DownloadCredentials(configuration: await client.configuration, accessToken: token)
    }
}
