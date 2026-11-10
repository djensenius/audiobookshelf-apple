/// Whether a network action may go ahead.
public enum NetworkDecision: Sendable, Hashable {
    case allowed
    /// The path is metered and the user's setting is ``CellularPolicy/ask``. The caller
    /// asks the user before going ahead.
    case askUser
    case denied
}

/// Decides whether streaming and downloads may use the current network, from the path
/// and the user's ``CellularPolicy`` settings. Ports the legacy
/// `mixins/cellularPermissionHelpers.js` check.
///
/// - Offline paths are denied.
/// - Metered paths follow the matching ``CellularPolicy``: `always` is allowed, `ask`
///   asks the user and `never` is denied. A path is metered when it uses cellular, when
///   it is constrained (Low Data Mode, which the user turns on for metered networks such
///   as a capped Wi-Fi), or, on macOS, when it is expensive (a Mac has no cellular
///   interface; an iPhone hotspot or tethering shows up as an expensive path).
/// - Other paths (Wi-Fi, wired) are allowed.
/// - An unknown path (before the monitor's first update) is allowed, as in the legacy
///   app; ``CellularPolicy/never`` is still enforced by the transport through
///   ``NetworkAccess``.
@MainActor
public struct NetworkPolicy {
    /// Whether expensive paths count as cellular. `true` on macOS.
    public nonisolated static let treatsExpensiveAsCellularByDefault: Bool = {
        #if os(macOS)
            true
        #else
            false
        #endif
    }()

    private let monitor: NetworkMonitor
    private let settings: AppSettings
    private let treatsExpensiveAsCellular: Bool

    public init(
        monitor: NetworkMonitor, settings: AppSettings,
        treatsExpensiveAsCellular: Bool = NetworkPolicy.treatsExpensiveAsCellularByDefault
    ) {
        self.monitor = monitor
        self.settings = settings
        self.treatsExpensiveAsCellular = treatsExpensiveAsCellular
    }

    /// Whether audio or video may be streamed on the current path.
    public func canStream() -> NetworkDecision {
        Self.decision(
            for: monitor.path, cellularPolicy: settings.streamingUsingCellular,
            treatsExpensiveAsCellular: treatsExpensiveAsCellular)
    }

    /// Whether a download may start on the current path.
    public func canDownload() -> NetworkDecision {
        Self.decision(
            for: monitor.path, cellularPolicy: settings.downloadUsingCellular,
            treatsExpensiveAsCellular: treatsExpensiveAsCellular)
    }

    /// The decision for `path` under `cellularPolicy`. Usable off the main actor with a
    /// path from ``NetworkMonitor/paths()`` and an ``AppSettings/Snapshot``.
    public nonisolated static func decision(
        for path: NetworkPath?, cellularPolicy: CellularPolicy,
        treatsExpensiveAsCellular: Bool = NetworkPolicy.treatsExpensiveAsCellularByDefault
    ) -> NetworkDecision {
        guard let path else { return .allowed }
        guard path.isOnline else { return .denied }
        guard isMetered(path, treatsExpensiveAsCellular: treatsExpensiveAsCellular) else { return .allowed }
        return switch cellularPolicy {
        case .always: .allowed
        case .ask: .askUser
        case .never: .denied
        }
    }

    /// Whether `path` follows the cellular policy rather than being allowed outright.
    public nonisolated static func isMetered(
        _ path: NetworkPath, treatsExpensiveAsCellular: Bool = NetworkPolicy.treatsExpensiveAsCellularByDefault
    ) -> Bool {
        path.interface == .cellular || path.isConstrained || (treatsExpensiveAsCellular && path.isExpensive)
    }
}
