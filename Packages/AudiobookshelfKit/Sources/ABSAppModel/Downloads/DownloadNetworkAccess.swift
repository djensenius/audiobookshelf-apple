import ABSCore
import Foundation

/// The network access flags for new download tasks, read from the stored download cellular policy
/// each time, so the engine's `networkAccess` closure is safe to call off the main actor.
///
/// It reads ``AppSettings/Snapshot`` from the same `UserDefaults` as ``AppSettings``, which writes
/// a change to the store before Observation reports it: once ``DownloadsController`` sees a
/// stricter policy, tasks created from then on get the new flags.
///
/// `@unchecked Sendable`: its properties are immutable, and `UserDefaults` is thread-safe though
/// not marked `Sendable`.
public struct DownloadNetworkAccess: @unchecked Sendable {
    private let defaults: UserDefaults
    private let treatsExpensiveAsCellular: Bool

    /// - Parameters:
    ///   - defaults: the store ``AppSettings`` uses (``AppSettings/defaults``).
    ///   - treatsExpensiveAsCellular: as for ``NetworkAccess/init(policy:treatsExpensiveAsCellular:)``.
    public init(
        defaults: UserDefaults,
        treatsExpensiveAsCellular: Bool = NetworkPolicy.treatsExpensiveAsCellularByDefault
    ) {
        self.defaults = defaults
        self.treatsExpensiveAsCellular = treatsExpensiveAsCellular
    }

    /// The flags for the stored ``AppSettings/downloadUsingCellular``.
    public func current() -> NetworkAccess {
        NetworkAccess(
            policy: AppSettings.snapshot(from: defaults).downloadUsingCellular,
            treatsExpensiveAsCellular: treatsExpensiveAsCellular)
    }

    /// ``current()`` as the engine's `networkAccess` closure.
    public var provider: @Sendable () async -> NetworkAccess {
        { [self] in current() }
    }
}
