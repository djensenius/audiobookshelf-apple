import Foundation
import Observation

/// One window scene's ``Router`` and the rules for when the scene may open a link and save its
/// state (ADR 0004). The scene's host view owns one and keeps only the SwiftUI plumbing.
///
/// A scene starts unrestored. Until ``restoreOnce(from:window:isCompact:opening:)`` has applied the
/// saved snapshot it shows no tabs, opens no link and saves nothing, because saving earlier
/// would replace the saved snapshot with the defaults.
@MainActor
@Observable
public final class SceneNavigation {
    public let router: Router
    /// Whether the scene has applied its saved snapshot.
    public private(set) var isRestored = false

    public init(identity: SessionIdentity) {
        router = Router(identity: identity)
    }

    /// Starts the scene with ``Router/restoreScene(from:window:isCompact:opening:)``, the first
    /// time only.
    /// - Returns: `true` if this call restored the scene, and opened `link`; `false` if the
    ///   scene was restored already, and nothing changed.
    @discardableResult
    public func restoreOnce(
        from data: Data?, window: WindowRoute? = nil, isCompact: Bool, opening link: DeepLink?
    ) -> Bool {
        guard !isRestored else { return false }
        router.restoreScene(from: data, window: window, isCompact: isCompact, opening: link)
        isRestored = true
        return true
    }

    /// Opens `link` in the restored scene.
    /// - Returns: `false`, with nothing opened, if the scene isn't restored yet; the caller
    ///   keeps the link.
    public func open(_ link: DeepLink) -> Bool {
        guard isRestored else { return false }
        router.open(link)
        return true
    }

    /// The snapshot to store for the scene, or `nil` before it has been restored.
    public var snapshotToSave: Data? {
        isRestored ? router.snapshotData : nil
    }
}

/// What a window scene's root view shows for the session gate, and whether it keeps a link.
public enum SceneContent: Equatable, Sendable {
    /// Starting up. The root shows a splash and keeps a link that launched the app.
    case loading
    /// The session is ending. The root shows the same splash, but keeps no link: a sign-out can
    /// end at another account without the gate passing through ``connect`` long enough for a
    /// view to see it, so a link that arrives here is dropped. One already waiting is dropped by
    /// ``SessionLifecycle/linkEpoch``, which this gate advances.
    case signingOut
    /// Signed out: the connect flow.
    case connect
    case storeUnavailable
    /// The signed-in shell of `identity`. A switch maps to this case too, with the outgoing
    /// identity, so the root keeps the same shell, router and scene storage until the next
    /// session has started. `opensLinks` is `false` during the switch, which leaves a link for
    /// the incoming account's shell.
    case shell(SessionIdentity, opensLinks: Bool)

    public init(_ gate: AuthGate) {
        switch gate {
        case .launching: self = .loading
        case .signingOut: self = .signingOut
        case .connect: self = .connect
        case .ready(let identity, _): self = .shell(identity, opensLinks: true)
        case .switching(from: let identity): self = .shell(identity, opensLinks: false)
        case .storeUnavailable: self = .storeUnavailable
        }
    }

    /// Whether a link that arrives now may wait for a scene to open it. It may not when signed
    /// out, signing out, or without a store: a link kept through a sign-in would open later, for
    /// whichever account signed in. A link that is already waiting is a different case, handled
    /// by ``PendingLink`` and ``SessionLifecycle/linkEpoch``.
    public var holdsLinks: Bool {
        switch self {
        case .loading, .shell: true
        case .signingOut, .connect, .storeUnavailable: false
        }
    }
}
