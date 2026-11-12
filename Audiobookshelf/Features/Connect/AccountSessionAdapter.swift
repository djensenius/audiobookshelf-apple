import ABSAPI
import ABSAppModel
import Foundation
import Observation

/// Bridges the process-wide accounts to the shell's session lifecycle. Computed properties
/// read observable account state, so the lifecycle follows sign-in, restore and expiry.
@MainActor @Observable
final class AccountSessionAdapter: AccountSessionSource {
    let accounts: AccountManager
    /// Called after a connection was removed, whether or not it was active, for state kept
    /// outside the session (downloads).
    private let onRemoved: (@MainActor (UUID) async -> Void)?

    init(accounts: AccountManager, onRemoved: (@MainActor (UUID) async -> Void)? = nil) {
        self.accounts = accounts
        self.onRemoved = onRemoved
    }

    var phase: AccountSessionPhase {
        switch accounts.state {
        case .signedOut: .signedOut
        case .restoring: .restoring
        case .signedIn(let user):
            .active(SessionIdentity(connectionID: user.connectionID, userID: user.userId), isOffline: false)
        case .offline(let user):
            .active(SessionIdentity(connectionID: user.connectionID, userID: user.userId), isOffline: true)
        }
    }

    var client: APIClient? { accounts.client }

    func restore() async throws { await accounts.restoreSession() }
    func logout() async -> URL? { await accounts.logout() }
    func `switch`(to connectionID: UUID) async throws { try await accounts.switch(to: connectionID) }
    func remove(_ connectionID: UUID) async throws -> URL? {
        let endSessionURL = try await accounts.remove(connectionID)
        await onRemoved?(connectionID)
        return endSessionURL
    }
}
