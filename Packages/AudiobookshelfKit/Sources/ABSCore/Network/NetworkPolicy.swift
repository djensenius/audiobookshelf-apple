/// Why a path counts as metered.
public enum MeteredReason: Sendable, Hashable {
    /// The path uses a cellular interface.
    case cellular
    /// The path is constrained (Low Data Mode).
    case lowDataMode
    /// The system marks the path as expensive (a personal hotspot, tethering).
    case expensive
}

/// Whether a network action may go ahead on the current path.
public enum NetworkDecision: Sendable, Hashable {
    case allowed
    /// The path is metered and the user's setting is ``CellularPolicy/ask``. The caller
    /// asks the user before going ahead.
    case askUser(MeteredReason)
    /// The path is metered and the user's setting is ``CellularPolicy/never``.
    case denied(MeteredReason)
}

/// Decides whether streaming and downloads may use the current path under the user's
/// ``CellularPolicy`` settings. Ports the legacy `mixins/cellularPermissionHelpers.js`
/// check, which only answers the metered-network question.
///
/// - A metered path follows the matching ``CellularPolicy``: `always` is allowed, `ask`
///   asks the user and `never` is denied, each with the ``MeteredReason``. A path is
///   metered when, in this order:
///   - it uses cellular (``MeteredReason/cellular``);
///   - it is constrained (``MeteredReason/lowDataMode``). This is a deliberate change from
///     the legacy app, which ignored Low Data Mode: the user turns it on for capped
///     networks such as a hotspot or metered Wi-Fi;
///   - it is expensive (``MeteredReason/expensive``) and either expensive paths count as
///     cellular (macOS, which has no cellular interface; tethering shows up as an
///     expensive path) or it isn't Wi-Fi. On iOS an expensive Wi-Fi path (a personal
///     hotspot) is not metered, as in the legacy app.
/// - Every other path is allowed, including an offline one: as in the legacy app, being
///   offline isn't a policy denial (a LAN server may still be reachable), so the request
///   goes ahead and the transport fails naturally. Use ``NetworkMonitor/isOnline`` for
///   an offline banner.
/// - An unknown path (before the monitor's first report) is allowed by the synchronous
///   ``canStream()`` and ``canDownload()``, as in the legacy app; ``CellularPolicy/never``
///   is still enforced by the transport through ``NetworkAccess``. Callers that act
///   without the user, such as auto-resume or CarPlay at a cold launch, use
///   ``canStream(waitingUpTo:)`` or ``canDownload(waitingUpTo:)`` to wait for the first
///   path.
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
        decision(for: monitor.path, cellularPolicy: settings.streamingUsingCellular)
    }

    /// Whether a download may start on the current path.
    public func canDownload() -> NetworkDecision {
        decision(for: monitor.path, cellularPolicy: settings.downloadUsingCellular)
    }

    /// ``canStream()`` after waiting up to `timeout` for the first path. Allowed if no
    /// path arrives in time.
    public func canStream(waitingUpTo timeout: Duration) async -> NetworkDecision {
        let path = await monitor.currentPath(timeout: timeout)
        return decision(for: path, cellularPolicy: settings.streamingUsingCellular)
    }

    /// ``canDownload()`` after waiting up to `timeout` for the first path. Allowed if no
    /// path arrives in time.
    public func canDownload(waitingUpTo timeout: Duration) async -> NetworkDecision {
        let path = await monitor.currentPath(timeout: timeout)
        return decision(for: path, cellularPolicy: settings.downloadUsingCellular)
    }

    private func decision(for path: NetworkPath?, cellularPolicy: CellularPolicy) -> NetworkDecision {
        Self.decision(for: path, cellularPolicy: cellularPolicy, treatsExpensiveAsCellular: treatsExpensiveAsCellular)
    }

    /// The decision for `path` under `cellularPolicy`. Usable off the main actor with a
    /// path from ``NetworkMonitor/paths()`` and an ``AppSettings/Snapshot``.
    public nonisolated static func decision(
        for path: NetworkPath?, cellularPolicy: CellularPolicy,
        treatsExpensiveAsCellular: Bool = NetworkPolicy.treatsExpensiveAsCellularByDefault
    ) -> NetworkDecision {
        guard let path, let reason = meteredReason(path, treatsExpensiveAsCellular: treatsExpensiveAsCellular)
        else { return .allowed }
        return switch cellularPolicy {
        case .always: .allowed
        case .ask: .askUser(reason)
        case .never: .denied(reason)
        }
    }

    /// Why `path` follows the cellular policy, or `nil` if it doesn't. Offline paths are
    /// never metered.
    public nonisolated static func meteredReason(
        _ path: NetworkPath, treatsExpensiveAsCellular: Bool = NetworkPolicy.treatsExpensiveAsCellularByDefault
    ) -> MeteredReason? {
        guard path.isOnline else { return nil }
        if path.interface == .cellular { return .cellular }
        if path.isConstrained { return .lowDataMode }
        if path.isExpensive && (treatsExpensiveAsCellular || path.interface != .wifi) { return .expensive }
        return nil
    }
}
