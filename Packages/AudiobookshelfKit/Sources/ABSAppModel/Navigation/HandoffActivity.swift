import ABSCore
import ABSData
import Foundation

/// The account a Handoff activity was published from: the server's normalized address and the
/// user's ID on it (ADR 0004, "Handoff"). Unlike a connection ID, both mean the same on every
/// device signed in to that account.
public struct HandoffAccount: Sendable, Hashable {
    /// The normalized server address (``ServerAddress/description``).
    public let serverAddress: String
    public let userID: String

    /// `nil` unless `serverAddress` is already normalized and `userID` is a valid ID.
    public init?(serverAddress: String, userID: String) {
        guard ServerAddress(serverAddress)?.description == serverAddress, DeepLink.isValidID(userID) else {
            return nil
        }
        self.serverAddress = serverAddress
        self.userID = userID
    }

    /// The `userInfo` entries a publisher adds, beside `item`, `episode` and `position`.
    public var userInfo: [String: String] { ["serverAddress": serverAddress, "userID": userID] }

    /// The first saved connection that ``matches(_:)`` this account. It doesn't check that the
    /// connection still has a saved session; ``AccountSessionSource/connectionID(for:)`` does.
    public func connectionID(in connections: [ServerConnectionDTO]) -> UUID? {
        connections.first(where: matches)?.id
    }

    /// Whether a saved connection is this account's: the same server and the same user, and
    /// neither signed out of nor disconnected.
    public func matches(_ connection: ServerConnectionDTO) -> Bool {
        connection.signedOutAt == nil && !connection.isDisconnected && connection.userId == userID
            && ServerAddress(connection.address)?.description == serverAddress
    }
}

/// A continued Handoff activity: the link it opens and, when the payload names one, the account
/// it belongs to.
public struct HandoffActivity: Sendable, Hashable {
    /// The link, naming no server. ``resolve(using:)`` names one when ``account`` is set.
    public let link: DeepLink
    /// `nil` for a payload without `serverAddress` and `userID`, which opens on the active account.
    public let account: HandoffAccount?

    /// `nil` when ``DeepLink/init(handoff:)`` is, which includes a `serverAddress` and `userID`
    /// pair that is half present or invalid.
    public init?(userInfo: [AnyHashable: Any]?) {
        guard let userInfo, let link = DeepLink(handoff: userInfo) else { return nil }
        switch DeepLink.handoffAccount(userInfo) {
        case .absent: self.init(link: link, account: nil)
        case .account(let account): self.init(link: link, account: account)
        case .invalid: return nil
        }
    }

    init(link: DeepLink, account: HandoffAccount?) {
        self.link = link
        self.account = account
    }

    /// Resolves the activity's account to a connection on this device, before
    /// ``Router/open(_:)``.
    ///
    /// Without an account the link opens on the active account, as before the payload named one.
    /// With one, the link names the matching connection, so the router opens it when that's the
    /// active connection and otherwise asks before switching (``Router/pendingServerSwitch``).
    /// With no matching connection, or only ones without a saved session (an expired session
    /// deletes its tokens but keeps the connection), the result is
    /// ``HandoffResolution/accountNotSignedIn(_:)``, and nothing should open.
    @MainActor public func resolve(using accounts: some AccountSessionSource) async -> HandoffResolution {
        guard let account else { return .open(link) }
        guard let connectionID = await accounts.connectionID(for: account) else { return .accountNotSignedIn(account) }
        return .open(DeepLink(link.target, serverID: connectionID.uuidString))
    }
}

/// What a continued Handoff activity does on this device.
public enum HandoffResolution: Sendable, Hashable {
    /// Hand the link to ``Router/open(_:)``.
    case open(DeepLink)
    /// The activity's account isn't signed in here. Don't navigate; tell the user instead.
    case accountNotSignedIn(HandoffAccount)
}

extension DeepLink {
    /// The `serverAddress` and `userID` entries of an activity.
    enum HandoffAccountEntry: Equatable {
        /// Neither entry is present, as in a payload from before they were added.
        case absent
        case account(HandoffAccount)
        /// Only one is present, or one is empty, not a string, not normalized or not a valid ID.
        case invalid
    }

    static func handoffAccount(_ userInfo: [AnyHashable: Any]) -> HandoffAccountEntry {
        let address = userInfo["serverAddress"]
        let userID = userInfo["userID"]
        if address == nil, userID == nil { return .absent }
        guard let address = address as? String, let userID = userID as? String,
            let account = HandoffAccount(serverAddress: address, userID: userID)
        else { return .invalid }
        return .account(account)
    }
}
