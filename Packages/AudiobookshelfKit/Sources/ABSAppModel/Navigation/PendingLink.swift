import Foundation

/// A link waiting for a scene to open it, tagged with the ``SessionLifecycle/linkEpoch`` it
/// arrived in.
///
/// A view can miss a gate that came and went between two renders (a sign-out that ends at
/// another account shows `.ready(B)` right after `.ready(A)`), so the rendered gate can't tell a
/// link meant for A from one meant for B. The epoch, which the lifecycle advances at every end
/// of an account, decides: the link is handed out only while the epoch is the one it arrived in.
public struct PendingLink: Equatable, Sendable {
    private let deepLink: DeepLink
    private let epoch: UInt64

    /// Returns `nil` when a link arriving at `gate` isn't kept (``SceneContent/holdsLinks``).
    public init?(_ link: DeepLink, arrivingAt gate: AuthGate, epoch: UInt64) {
        guard SceneContent(gate).holdsLinks else { return nil }
        self.deepLink = link
        self.epoch = epoch
    }

    /// The link, unless the epoch has moved on since it arrived.
    public func link(atEpoch current: UInt64) -> DeepLink? {
        current == epoch ? deepLink : nil
    }
}
