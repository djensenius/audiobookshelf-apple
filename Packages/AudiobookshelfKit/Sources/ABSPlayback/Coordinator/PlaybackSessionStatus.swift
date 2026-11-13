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

    /// The status `lookup` (the session request) shows.
    static func checking(_ lookup: () async throws -> PlaybackSession) async -> Self {
        do {
            _ = try await lookup()
            return .alive
        } catch let error as APIError {
            switch error {
            case .notFound: return .gone
            case .unauthorized, .sessionExpired: return .unauthorized
            case .network, .timedOut: return .unreachable
            default: return .unknown
            }
        } catch {
            return .unknown
        }
    }
}

extension PlaybackSessionService {
    public func sessionStatus(id: String) async -> PlaybackSessionStatus { .unknown }
}
