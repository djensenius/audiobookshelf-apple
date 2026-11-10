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

    init(_ tokens: AuthTokens? = AuthTokens(accessToken: "access-1", refreshToken: "refresh-1")) {
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

    func update(_ tokens: AuthTokens) async {
        state.withLock {
            $0.current = tokens
            $0.updates.append(tokens)
        }
    }

    func sessionExpired() async {
        state.withLock {
            $0.current = nil
            $0.expiredCount += 1
        }
    }
}
