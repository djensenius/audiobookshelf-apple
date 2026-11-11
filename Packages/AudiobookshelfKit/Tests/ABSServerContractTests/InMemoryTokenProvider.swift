import ABSAPI
import Synchronization

/// An in-memory ``TokenProvider`` that records refreshed tokens and session expiry. A copy of the
/// one in ABSAPITests, which test targets can't share.
final class InMemoryTokenProvider: TokenProvider {
    private struct State {
        var current: AuthTokens?
        var updates: [AuthTokens] = []
        var expiredCount = 0
    }

    private let state: Mutex<State>

    init(_ tokens: AuthTokens?) {
        state = Mutex(State(current: tokens))
    }

    var current: AuthTokens? { state.withLock { $0.current } }
    var updates: [AuthTokens] { state.withLock { $0.updates } }
    var expiredCount: Int { state.withLock { $0.expiredCount } }

    /// Replaces the tokens without recording an update, as a new sign-in would.
    func signIn(_ tokens: AuthTokens) {
        state.withLock { $0.current = tokens }
    }

    func tokens() async -> AuthTokens? {
        current
    }

    func replaceTokens(expected: AuthTokens, with new: AuthTokens) async -> Bool {
        state.withLock {
            guard $0.current == expected else { return false }
            $0.current = new
            $0.updates.append(new)
            return true
        }
    }

    func expireSession(ifCurrent rejected: AuthTokens) async -> Bool {
        state.withLock {
            guard $0.current == rejected else { return false }
            $0.current = nil
            $0.expiredCount += 1
            return true
        }
    }
}
