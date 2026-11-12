import Network

/// The kind of interface a network path uses.
public enum NetworkInterface: String, CaseIterable, Sendable {
    case wifi
    case cellular
    case wired
    case other
}

/// A value snapshot of the device's current network path.
public struct NetworkPath: Sendable, Hashable {
    /// Whether the system reports the path as usable. Only an unsatisfied path is offline;
    /// a path that needs a connection to be established first (such as VPN on demand)
    /// counts as online. The system decides whether a network without internet access is
    /// satisfied, so this is for display (an offline banner), not for gating requests: a
    /// server on the LAN may still be reachable. ``NetworkPolicy`` doesn't deny offline
    /// paths.
    public var isOnline: Bool
    /// Whether the path uses an interface the system considers expensive, such as
    /// cellular or a personal hotspot.
    public var isExpensive: Bool
    /// Whether the path is in Low Data Mode.
    public var isConstrained: Bool
    /// The primary interface, or `nil` when offline.
    public var interface: NetworkInterface?
    /// How many times the source's path came back online after being offline. Path streams
    /// keep only the newest unread path, so a consumer may never see the offline path between
    /// two online ones; this still changes. `SystemNetworkPathSource` counts per stream, from 0,
    /// so compare epochs only within one stream; other paths leave it at 0.
    public var onlineEpoch: UInt64 = 0

    public init(isOnline: Bool, isExpensive: Bool = false, isConstrained: Bool = false, interface: NetworkInterface?) {
        self.isOnline = isOnline
        self.isExpensive = isExpensive
        self.isConstrained = isConstrained
        self.interface = isOnline ? interface : nil
    }

    public static let offline = NetworkPath(isOnline: false, interface: nil)
    public static let wifi = NetworkPath(isOnline: true, interface: .wifi)
    public static let wired = NetworkPath(isOnline: true, interface: .wired)
    public static let cellular = NetworkPath(isOnline: true, isExpensive: true, interface: .cellular)
}

extension NetworkPath {
    /// Creates a snapshot of a Network framework path.
    public init(_ path: NWPath) {
        self.init(
            status: path.status,
            isExpensive: path.isExpensive,
            isConstrained: path.isConstrained,
            usesInterfaceType: path.usesInterfaceType
        )
    }

    init(
        status: NWPath.Status, isExpensive: Bool, isConstrained: Bool,
        usesInterfaceType: (NWInterface.InterfaceType) -> Bool
    ) {
        let isOnline = status != .unsatisfied
        let interface: NetworkInterface =
            if usesInterfaceType(.wifi) {
                .wifi
            } else if usesInterfaceType(.wiredEthernet) {
                .wired
            } else if usesInterfaceType(.cellular) {
                .cellular
            } else {
                .other
            }
        self.init(isOnline: isOnline, isExpensive: isExpensive, isConstrained: isConstrained, interface: interface)
    }
}
