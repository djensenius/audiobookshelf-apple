import ABSAPI
import ABSCore
import Foundation

/// What `GET /api/session/{id}` says about a session, which decides between ADR 0007's "session
/// alive" and "session gone" recovery: a stream's HTTP status is only a hint.
public enum PlaybackSessionStatus: Sendable, Hashable {
    /// Still open: a readiness re-seek of the same item.
    case alive
    /// No longer open (404): a rebuild with a new session.
    case gone
    /// A 401: the token-refresh path.
    case unauthorized
    /// The lookup didn't reach the server: wait for the network.
    case unreachable
    /// No answer either way (no lookup, no session, or another error): the failure's own rule.
    case unknown

    /// The status a failed lookup (the session request) shows.
    static func status(for error: any Error) -> Self {
        if let error = error as? APIError {
            switch error {
            case .notFound: return .gone
            case .unauthorized, .sessionExpired: return .unauthorized
            case .network, .timedOut: return .unreachable
            default: return .unknown
            }
        }
        return .unknown
    }
}

/// A session lookup's ``PlaybackSessionStatus``, and whether its request refreshed the access
/// token on a 401: recovery charges that to its single refresh (#491).
public struct PlaybackSessionCheck: Sendable, Hashable {
    public var status: PlaybackSessionStatus
    public var refreshedToken: Bool

    public init(status: PlaybackSessionStatus, refreshedToken: Bool = false) {
        self.status = status
        self.refreshedToken = refreshedToken
    }

    /// `GET /api/session/{id}` through `client`, noting whether it refreshed the token.
    static func lookUp(id: String, on client: APIClient) async -> Self {
        let lookup = await client.sendTrackingRefresh(SessionEndpoints.openSession(id: id))
        switch lookup.result {
        case .success: return Self(status: .alive, refreshedToken: lookup.didRefresh)
        case .failure(let error):
            return Self(status: PlaybackSessionStatus.status(for: error), refreshedToken: lookup.didRefresh)
        }
    }
}

extension PlaybackSessionService {
    public func sessionStatus(id: String) async -> PlaybackSessionStatus { .unknown }

    /// The ``sessionStatus(id:)``, reporting no refresh.
    public func sessionCheck(id: String) async -> PlaybackSessionCheck {
        PlaybackSessionCheck(status: await sessionStatus(id: id))
    }
}
