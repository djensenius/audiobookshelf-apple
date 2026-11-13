import ABSCore
import Foundation

/// Restores an offline account's session once the connection banner is back online (#76).
///
/// Give it each ``ConnectionBannerState`` the banner shows (``observe(_:)``). When the state turns
/// ``ConnectionBannerState/online`` after being offline or unreachable, it reads ``Epoch``: `nil`
/// unless the account is offline and may restore now, so it does nothing while signed in, signed
/// out or switching. With an epoch it waits out the debounce, then restores once, if the banner is
/// still online, the epoch is the same and none of its restores is running. A sign-out, an account
/// switch or another session of the account during the wait changes the epoch, so nothing runs.
/// Any other change of state cancels the wait, so a network that flaps restores once, after it
/// last came back. A restore, once started, isn't cancelled by later changes.
@MainActor
public final class ReconnectRestorer {
    /// The current session's identity while its account is offline and a restore may run, such
    /// as its identity and the session's number; `nil` otherwise. Read when the banner comes
    /// online and again, in the same turn as the restore, after the debounce.
    public typealias Epoch = @MainActor () -> AnyHashable?
    /// Restores the session of the account the epoch it's given was read for, such as with
    /// ``AccountManager/reconnect(_:)``.
    public typealias Restore = @MainActor (AnyHashable) async -> Void

    /// How long the banner stays online before a restore.
    public static let debounce: Duration = .seconds(2)

    private let epoch: Epoch
    private let restore: Restore
    private let clock: any Clock<Duration>
    private let debounce: Duration
    private var state: ConnectionBannerState
    private var pending: Task<Void, Never>?
    private var isRestoring = false
    /// How many restores it started.
    private(set) var restores = 0

    /// - Parameters:
    ///   - state: what the banner shows now.
    ///   - debounce: how long the banner stays online before a restore.
    ///   - clock: waits out the debounce.
    public init(
        state: ConnectionBannerState = .online,
        debounce: Duration = ReconnectRestorer.debounce,
        clock: any Clock<Duration> = ContinuousClock(),
        epoch: @escaping Epoch,
        restore: @escaping Restore
    ) {
        self.state = state
        self.debounce = debounce
        self.clock = clock
        self.epoch = epoch
        self.restore = restore
    }

    isolated deinit {
        pending?.cancel()
    }

    /// Follows the banner's state.
    public func observe(_ state: ConnectionBannerState) {
        let previous = self.state
        self.state = state
        guard state != previous else { return }
        cancel()
        guard state == .online, !isRestoring, let expected = epoch() else { return }
        pending = Task { [weak self, clock, debounce] in
            do { try await clock.sleep(for: debounce) } catch { return }
            await self?.restoreIfCurrent(expected)
        }
    }

    /// Cancels a restore that is waiting out the debounce, such as when the banner stops.
    public func cancel() {
        pending?.cancel()
        pending = nil
    }

    /// The task waiting to restore, for tests to wait on.
    var waiting: Task<Void, Never>? { pending }

    private func restoreIfCurrent(_ expected: AnyHashable) async {
        guard !Task.isCancelled, state == .online, !isRestoring, epoch() == expected else { return }
        // Started: a later change of state no longer cancels it.
        pending = nil
        isRestoring = true
        restores += 1
        defer { isRestoring = false }
        await restore(expected)
    }
}

extension AccountManager {
    /// Reconnects the offline connection `id` as ``switch(to:)`` does, if it's still the active
    /// connection and offline; does nothing otherwise. Unlike ``restoreSession()``, which takes
    /// the most recently used connection, it never reconnects another account, such as one a
    /// cancelled sign-in marked used. Works without an `APIClient` too, such as after the
    /// Keychain was locked: it reads the saved session again.
    public func reconnect(_ id: UUID) async {
        guard case .offline(let user) = state, user.connectionID == id, activeConnection?.id == id else { return }
        do {
            try await self.switch(to: id)
        } catch {
            Log.auth.notice("Couldn't reconnect: \(String(describing: type(of: error)), privacy: .public)")
        }
    }
}
