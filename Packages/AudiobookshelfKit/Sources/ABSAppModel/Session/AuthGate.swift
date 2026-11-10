import Foundation

/// What the root view shows, decided by ``SessionLifecycle``.
public enum AuthGate: Sendable, Equatable {
    /// Restoring the saved session at launch. Show a splash.
    case launching
    /// Signed out. Show the connect flow.
    case connect
    /// A session is running. `isOffline` is `true` while the server can't be reached and the
    /// app runs from saved data.
    case ready(SessionIdentity, isOffline: Bool)
    /// The session of `from` is ending, or has ended, and another account is being made active.
    /// It stays until the next session has started.
    case switching(from: SessionIdentity)
    /// The session of `from` is flushing and ending before a sign-out or removal, or ending
    /// because the server rejected it. ``connect`` follows.
    case signingOut(from: SessionIdentity)
    /// The local store couldn't be opened, so nothing can be restored or saved.
    case storeUnavailable(SessionStoreError)

    /// The running session's identity, if any.
    public var identity: SessionIdentity? {
        if case .ready(let identity, _) = self { identity } else { nil }
    }
}

/// Wraps the error that made the local store unavailable, so ``AuthGate`` can be `Equatable`.
/// Two values are equal when their errors have the same type and description.
public struct SessionStoreError: Error, Sendable, Equatable, CustomStringConvertible {
    public let underlying: any Error

    public init(_ underlying: any Error) {
        self.underlying = underlying
    }

    public var description: String { String(describing: underlying) }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        ObjectIdentifier(type(of: lhs.underlying)) == ObjectIdentifier(type(of: rhs.underlying))
            && lhs.description == rhs.description
    }
}
