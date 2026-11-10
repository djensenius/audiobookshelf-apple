import Foundation

/// A link waiting for a scene to open it.
public struct PendingLink: Equatable, Sendable {
    let link: DeepLink
    let epoch: UInt64

    public init?(_ link: DeepLink, arrivingAt gate: AuthGate, epoch: UInt64) {
        self.link = link
        self.epoch = epoch
    }

    public func link(atEpoch current: UInt64) -> DeepLink? {
        link
    }
}
