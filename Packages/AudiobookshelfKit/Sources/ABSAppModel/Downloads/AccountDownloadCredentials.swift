import ABSAPI
import ABSDownloads
import Foundation

/// Download credentials from the account layer: each connection's ``APIClient``, found through an
/// injected lookup, supplies its configuration and access token. Refreshes go through the client's
/// single refresh (``APIClient/accessToken(replacing:)``), so download parts and the app's own API
/// calls share it.
public struct AccountDownloadCredentials: DownloadCredentialProviding {
    private let client: @Sendable (UUID) async -> APIClient?

    /// - Parameter client: the ``APIClient`` of a connection, or `nil` when the connection is
    ///   signed out or removed.
    public init(client: @escaping @Sendable (UUID) async -> APIClient?) {
        self.client = client
    }

    /// The client's configuration and stored access token, without any request; `nil` when there is
    /// no client for the connection or it is signed out.
    public func currentCredentials(for connectionID: UUID) async -> DownloadCredentials? {
        guard let client = await client(connectionID), let token = await client.currentAccessToken() else {
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
        guard let client = await client(connectionID) else { throw APIError.notAuthenticated }
        let token = try await client.accessToken(replacing: rejectedAccessToken)
        return DownloadCredentials(configuration: await client.configuration, accessToken: token)
    }
}
