import ABSAPI
import ABSAppModel
import ABSCore
import Foundation
import Observation

/// Bridges the process-wide accounts to the shell's session lifecycle. Computed properties
/// read observable account state, so the lifecycle follows sign-in, restore and expiry.
@MainActor @Observable
final class AccountSessionAdapter: AccountSessionSource {
    let accounts: AccountManager
    /// Called after a connection was removed, whether or not it was active, for state kept
    /// outside the session. `AppEnvironment` composes every removal effect (downloads, and more
    /// to come) in this one closure; extend it there rather than adding another.
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
        do {
            let endSessionURL = try await accounts.remove(connectionID)
            await onRemoved?(connectionID)
            return endSessionURL
        } catch AccountError.connectionNotFound {
            throw AccountError.connectionNotFound
        } catch let error as KeychainError {
            // Nothing was deleted.
            throw error
        } catch {
            // The session was deleted, but the store kept the connection (`AccountManager.remove`).
            // Rarely, the store's first read failed instead, and nothing was deleted; stopping its
            // downloads then is the safe side.
            await onRemoved?(connectionID)
            throw error
        }
    }
}
