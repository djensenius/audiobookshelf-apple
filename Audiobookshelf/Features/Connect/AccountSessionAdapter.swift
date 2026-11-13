import ABSAPI
import ABSAppModel
import Foundation
import Observation

/// Bridges the process-wide accounts to the shell's session lifecycle. Computed properties
/// read observable account state, so the lifecycle follows sign-in, restore and expiry.
@MainActor @Observable
final class AccountSessionAdapter: AccountSessionSource {
    let accounts: AccountManager

    init(accounts: AccountManager) {
        self.accounts = accounts
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
    func logout(connectionID: UUID) async -> URL? { await accounts.logout(connectionID: connectionID) }
    func `switch`(to connectionID: UUID) async throws { try await accounts.switch(to: connectionID) }
    func remove(_ connectionID: UUID) async throws -> URL? { try await accounts.remove(connectionID) }
    func connectionID(for account: HandoffAccount) async -> UUID? { await accounts.connectionID(for: account) }
}
