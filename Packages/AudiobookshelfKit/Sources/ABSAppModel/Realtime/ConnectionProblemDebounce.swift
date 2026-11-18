import Observation

/// Whether the connection indicator's problem has lasted (#691): the shell raises the indicator's toolbar priority
/// only then, so a crowded compact bar doesn't reflow for the brief connecting and unreachable states every session
/// start, reconnect, token refresh and network change go through.
///
/// Feed it every state with ``update(_:)``. A problem (``ConnectionIndicatorState/isProblem``) sets
/// ``hasPersisted`` once it has lasted ``delay``, however it changes in between (connecting, then unreachable, say);
/// anything else clears it at once.
@MainActor
@Observable
public final class ConnectionProblemDebounce {
    /// Whether the current problem has lasted ``delay``.
    public private(set) var hasPersisted = false
    /// How long a problem lasts before ``hasPersisted``.
    @ObservationIgnored public let delay: Duration
    /// The wait for the current problem's ``delay``. Tests await it.
    @ObservationIgnored private(set) var timer: Task<Void, Never>?
    @ObservationIgnored private let clock: any Clock<Duration>

    /// - Parameter clock: Times the delay; tests pass a manual clock.
    public init(delay: Duration = .seconds(3), clock: any Clock<Duration> = ContinuousClock()) {
        self.delay = delay
        self.clock = clock
    }

    isolated deinit {
        timer?.cancel()
    }

    /// Follows the indicator's state, or `nil` while it's hidden.
    public func update(_ state: ConnectionIndicatorState?) {
        guard state?.isProblem == true else {
            timer?.cancel()
            timer = nil
            if hasPersisted { hasPersisted = false }
            return
        }
        guard timer == nil, !hasPersisted else { return }
        timer = Task { [weak self, clock, delay] in
            do { try await clock.sleep(for: delay) } catch { return }
            guard !Task.isCancelled, let self else { return }
            self.hasPersisted = true
            self.timer = nil
        }
    }
}

extension ConnectionIndicatorState {
    /// Whether this is a problem: connecting, offline or the server unreachable, not a working connection.
    public var isProblem: Bool {
        if case .connected = self { return false }
        return true
    }
}
