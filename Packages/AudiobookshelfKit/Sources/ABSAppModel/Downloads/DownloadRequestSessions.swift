import Foundation
import Observation

/// The account session a download request was made in (``DownloadRequestSessions``).
public struct DownloadRequestSession: Sendable, Hashable {
    public let connectionID: UUID
    /// The session's ``SessionContext/sessionID``: a later session of the same connection, after
    /// a sign-out or a switch away and back, has another.
    public let sessionID: UInt64
    /// Whether the session's user may download (`permissions.download`, legacy `userCanDownload`).
    public let canDownload: Bool

    public init(connectionID: UUID, sessionID: UInt64, canDownload: Bool) {
        self.connectionID = connectionID
        self.sessionID = sessionID
        self.canDownload = canDownload
    }
}

/// The session a download request began in and the manager's quiesce generation then
/// (``DownloadManager/quiesceGeneration()``). A metered confirmation carries the ticket of the
/// request that asked for it, so it is refused once that session has ended, even if another
/// session of the connection is running by then.
public struct DownloadRequestTicket: Sendable, Hashable {
    public let connectionID: UUID
    let sessionID: UInt64
    let generation: Int
}

/// Why ``DownloadsController`` refused a request before queueing anything.
public enum DownloadRequestError: Error, Sendable, Hashable {
    /// The user of the request's session may not download.
    case notPermitted
    /// No session of the request's connection is running, or the one the request began in ended
    /// (a sign-out, expiry, removal or switch). Callers drop the request without telling the
    /// user: the account it was for is gone.
    case sessionEnded
}

/// The running account session, for the download requests the user makes
/// (``DownloadsController``): which connection, which session of it, and whether its user may
/// download. Register it as a ``SessionParticipant`` at ``SessionStage/connect``, after the
/// ``DownloadsLifecycle``: sessions end in reverse order, so it forgets an ending session before
/// that session's downloads stop.
///
/// Observable, so a view that asks whether a connection can download
/// (``DownloadRequesting/canRequest(connectionID:)``) follows sessions starting and ending, and
/// whatever `userCanDownload` reads.
@MainActor
@Observable
public final class DownloadRequestSessions: SessionParticipant {
    private struct Running: Hashable {
        let connectionID: UUID
        let sessionID: UInt64
    }

    private var running: Running?
    @ObservationIgnored private let userCanDownload: @MainActor (UUID) -> Bool

    /// - Parameter userCanDownload: whether the signed-in user of a connection may download, read
    ///   at every request; ``init(accounts:)`` reads the account's authorization.
    public init(userCanDownload: @escaping @MainActor (UUID) -> Bool) {
        self.userCanDownload = userCanDownload
    }

    /// Reads `permissions.download` of the active connection's latest authorization: `false` for
    /// another connection, and offline (there is no authorization).
    public convenience init(accounts: AccountManager) {
        self.init { [weak accounts] connectionID in
            guard let accounts, accounts.activeConnection?.id == connectionID else { return false }
            return accounts.authorization?.user.permissions.download ?? false
        }
    }

    /// The running session, if it is `connectionID`'s; `nil` otherwise.
    public func session(for connectionID: UUID) -> DownloadRequestSession? {
        guard let running, running.connectionID == connectionID else { return nil }
        return DownloadRequestSession(
            connectionID: connectionID, sessionID: running.sessionID, canDownload: userCanDownload(connectionID))
    }

    public func sessionDidStart(_ context: SessionContext) async {
        running = Running(connectionID: context.identity.connectionID, sessionID: context.sessionID)
    }

    public func sessionWillEnd(_ reason: SessionEndReason) async {
        running = nil
    }
}
