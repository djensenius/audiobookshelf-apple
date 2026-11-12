import ABSCore
import Foundation
import Synchronization

/// The network access flags for new download tasks, read from the stored download cellular policy
/// each time, so the engine's `networkAccess` closure is safe to call off the main actor.
///
/// It reads ``AppSettings/Snapshot`` from the same `UserDefaults` as ``AppSettings``, which writes
/// a change to the store before Observation reports it: once ``DownloadsController`` sees a
/// stricter policy, tasks created from then on get the new flags.
///
/// Build one per app, on ``AppSettings/defaults``, and pass it to both the engine (``provider``) and
/// ``DownloadsController``: copies share whether metered access was handed out, so the controller
/// knows when transfers under way may still use cellular or Low Data Mode.
///
/// `@unchecked Sendable`: its properties are immutable, `UserDefaults` is thread-safe though not
/// marked `Sendable`, and the shared state is behind a `Mutex`.
public struct DownloadNetworkAccess: @unchecked Sendable {
    /// Whether flags allowing cellular or constrained paths were handed out since the last
    /// ``takeHandedOutMetered()``.
    private final class MeteredLedger: Sendable {
        /// `true` at first: tasks from before this instance existed are unknown.
        let handedOut = Mutex(true)
    }

    private let defaults: UserDefaults
    /// Whether expensive paths count as cellular, as for ``NetworkAccess/init(policy:treatsExpensiveAsCellular:)``.
    public let treatsExpensiveAsCellular: Bool
    private let ledger = MeteredLedger()
    /// Runs in ``current()`` between reading the policy and recording the flags, for tests.
    private let afterPolicyRead: (@Sendable () -> Void)?

    /// - Parameters:
    ///   - defaults: the store ``AppSettings`` uses (``AppSettings/defaults``).
    ///   - treatsExpensiveAsCellular: as for ``NetworkAccess/init(policy:treatsExpensiveAsCellular:)``.
    public init(
        defaults: UserDefaults,
        treatsExpensiveAsCellular: Bool = NetworkPolicy.treatsExpensiveAsCellularByDefault
    ) {
        self.init(defaults: defaults, treatsExpensiveAsCellular: treatsExpensiveAsCellular, afterPolicyRead: nil)
    }

    init(defaults: UserDefaults, treatsExpensiveAsCellular: Bool, afterPolicyRead: (@Sendable () -> Void)?) {
        self.defaults = defaults
        self.treatsExpensiveAsCellular = treatsExpensiveAsCellular
        self.afterPolicyRead = afterPolicyRead
    }

    /// The flags for the stored ``AppSettings/downloadUsingCellular``. Flags allowing cellular or
    /// Low Data Mode are recorded as handed out.
    ///
    /// The policy is read and the flags recorded under the ledger's lock, as one step against
    /// ``takeHandedOutMetered()``: a take that finds nothing handed out comes before the read, so
    /// a policy stored before the take is the one read.
    public func current() -> NetworkAccess {
        ledger.handedOut.withLock { handedOut in
            let access = NetworkAccess(
                policy: AppSettings.snapshot(from: defaults).downloadUsingCellular,
                treatsExpensiveAsCellular: treatsExpensiveAsCellular)
            afterPolicyRead?()
            if access.allowsCellularAccess || access.allowsConstrainedNetworkAccess { handedOut = true }
            return access
        }
    }

    /// ``current()`` as the engine's `networkAccess` closure.
    public var provider: @Sendable () async -> NetworkAccess {
        { [self] in current() }
    }

    /// Whether metered access was handed out since the last call, and clears it.
    func takeHandedOutMetered() -> Bool {
        ledger.handedOut.withLock { handedOut in
            defer { handedOut = false }
            return handedOut
        }
    }

    /// ``takeHandedOutMetered()`` if no ``current()`` holds the ledger's lock; otherwise `nil`,
    /// without waiting. For tests.
    func takeHandedOutMeteredIfAvailable() -> Bool? {
        ledger.handedOut.withLockIfAvailable { handedOut in
            defer { handedOut = false }
            return handedOut
        }
    }

    /// Records metered access as handed out again, after a restart for a stricter policy failed.
    func markHandedOutMetered() {
        ledger.handedOut.withLock { $0 = true }
    }
}
