import ABSAPI
import Synchronization

/// An in-memory ``TokenProvider`` that records refreshed tokens and session expiry.
///
/// State is behind a mutex so stub handlers can read or replace the tokens synchronously, for
/// example to simulate the user signing in again while a refresh is in flight.
final class InMemoryTokenProvider: TokenProvider {
    private struct State {
        var current: AuthTokens?
        var updates: [AuthTokens] = []
        var expiredCount = 0
    }

    private let state: Mutex<State>
    /// Runs at the start of ``expireSession(ifCurrent:)``, before the comparison, to simulate a
    /// sign-in racing the expiry.
    private let beforeExpire: (@Sendable (InMemoryTokenProvider) -> Void)?

    init(
        _ tokens: AuthTokens? = AuthTokens(accessToken: "access-1", refreshToken: "refresh-1"),
        beforeExpire: (@Sendable (InMemoryTokenProvider) -> Void)? = nil
    ) {
        state = Mutex(State(current: tokens))
        self.beforeExpire = beforeExpire
    }

    var current: AuthTokens? { state.withLock { $0.current } }
    var updates: [AuthTokens] { state.withLock { $0.updates } }
    var expiredCount: Int { state.withLock { $0.expiredCount } }

    /// Replaces the tokens without recording an update, as a new sign-in would.
    func signIn(_ tokens: AuthTokens) {
        state.withLock { $0.current = tokens }
    }

    func signOut() {
        state.withLock { $0.current = nil }
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
        beforeExpire?(self)
        return state.withLock {
            guard $0.current == rejected else { return false }
            $0.current = nil
            $0.expiredCount += 1
            return true
        }
    }
}
