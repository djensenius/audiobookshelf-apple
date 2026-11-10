import Foundation
import Security

/// A Keychain status code returned by a failed generic-password operation.
public struct KeychainError: Error, Sendable, Hashable, CustomStringConvertible {
    public let status: OSStatus

    public init(status: OSStatus) {
        self.status = status
    }

    /// The Keychain can't be used by this process or right now (no entitlement, no keychain, or
    /// locked), rather than the item or the query being wrong.
    public var isUnavailable: Bool {
        [errSecMissingEntitlement, errSecNotAvailable, errSecInteractionNotAllowed, errSecNoDefaultKeychain]
            .contains(status)
    }

    public var description: String {
        let message = SecCopyErrorMessageString(status, nil) as String? ?? "unknown"
        return "KeychainError(\(status): \(message))"
    }
}

/// One generic-password item.
public struct KeychainItem: Sendable, Hashable {
    public let service: String
    public let account: String

    public init(service: String, account: String) {
        self.service = service
        self.account = account
    }
}

/// When an item is readable, and whether it may leave this device.
public enum KeychainAccessibility: Sendable, Hashable {
    /// Readable after first unlock; included in encrypted backups and device migration. Used for
    /// tokens and custom header values, so refreshes work while the device is locked.
    case afterFirstUnlock
    /// Readable after first unlock; never leaves this device (no backup restore, Quick Start, or
    /// Migration Assistant). Used for the device ID and per-install keys.
    case afterFirstUnlockThisDeviceOnly

    var attributeValue: CFString {
        switch self {
        case .afterFirstUnlock: kSecAttrAccessibleAfterFirstUnlock
        case .afterFirstUnlockThisDeviceOnly: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        }
    }
}

/// Generic-password Keychain access. ``KeychainStore`` is the real implementation; tests inject
/// an in-memory fake.
public protocol KeychainStoring: Sendable {
    /// The item's data, or `nil` when no item exists.
    func data(for item: KeychainItem) throws(KeychainError) -> Data?
    /// Adds an item. Returns `false`, without changing anything, when the item already exists.
    func add(_ data: Data, for item: KeychainItem, accessibility: KeychainAccessibility) throws(KeychainError) -> Bool
    /// Replaces the item's data and accessibility, or adds the item if it doesn't exist.
    func set(_ data: Data, for item: KeychainItem, accessibility: KeychainAccessibility) throws(KeychainError)
    /// Deletes the item. Deleting a missing item succeeds.
    func delete(_ item: KeychainItem) throws(KeychainError)
}

extension KeychainStoring {
    /// Deletes and adds again. For fakes; ``KeychainStore`` updates the item in place.
    public func set(_ data: Data, for item: KeychainItem, accessibility: KeychainAccessibility) throws(KeychainError) {
        try delete(item)
        _ = try add(data, for: item, accessibility: accessibility)
    }
}

/// Generic passwords in the data-protection Keychain (also on macOS), never synchronised through
/// iCloud (ADR 0002).
public struct KeychainStore: KeychainStoring {
    /// `nil` adds to the first `keychain-access-groups` entitlement,
    /// `$(AppIdentifierPrefix)org.davidjensenius.Audiobookshelf` (ADR 0002), and reads from every
    /// group the process can access. Pass a group only from a build signed with that entitlement;
    /// unsigned builds, the ad hoc test host and `swift test` use `nil`.
    public let accessGroup: String?
    /// `false` uses the macOS file-based login keychain instead, for tests only: an unsigned
    /// `swift test` binary gets `errSecMissingEntitlement` from the data-protection Keychain.
    /// iOS has only the data-protection Keychain.
    public let usesDataProtectionKeychain: Bool

    public init(accessGroup: String? = nil, usesDataProtectionKeychain: Bool = true) {
        self.accessGroup = accessGroup
        self.usesDataProtectionKeychain = usesDataProtectionKeychain
    }

    public func data(for item: KeychainItem) throws(KeychainError) -> Data? {
        var query = query(for: item)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess: return result as? Data
        case errSecItemNotFound: return nil
        default: throw KeychainError(status: status)
        }
    }

    public func add(
        _ data: Data, for item: KeychainItem, accessibility: KeychainAccessibility
    ) throws(KeychainError) -> Bool {
        let query = Self.addQuery(
            for: item, data: data, accessibility: accessibility, accessGroup: accessGroup,
            usesDataProtectionKeychain: usesDataProtectionKeychain)
        let status = SecItemAdd(query as CFDictionary, nil)
        switch status {
        case errSecSuccess: return true
        case errSecDuplicateItem: return false
        default: throw KeychainError(status: status)
        }
    }

    public func set(_ data: Data, for item: KeychainItem, accessibility: KeychainAccessibility) throws(KeychainError) {
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: accessibility.attributeValue,
        ]
        // Another process may add the item between a failed update and the add, so a duplicate
        // add is retried once as an update.
        for _ in 0..<2 {
            let status = SecItemUpdate(query(for: item) as CFDictionary, attributes as CFDictionary)
            switch status {
            case errSecSuccess:
                return
            case errSecItemNotFound:
                if try add(data, for: item, accessibility: accessibility) { return }
            default:
                throw KeychainError(status: status)
            }
        }
        throw KeychainError(status: errSecDuplicateItem)
    }

    public func delete(_ item: KeychainItem) throws(KeychainError) {
        let status = SecItemDelete(query(for: item) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
    }

    private func query(for item: KeychainItem) -> [String: Any] {
        Self.query(for: item, accessGroup: accessGroup, usesDataProtectionKeychain: usesDataProtectionKeychain)
    }

    /// The attributes identifying `item`.
    static func query(
        for item: KeychainItem, accessGroup: String?, usesDataProtectionKeychain: Bool = true
    ) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: item.service,
            kSecAttrAccount as String: item.account,
            kSecAttrSynchronizable as String: false,
        ]
        if usesDataProtectionKeychain { query[kSecUseDataProtectionKeychain as String] = true }
        if let accessGroup { query[kSecAttrAccessGroup as String] = accessGroup }
        return query
    }

    /// The attributes for `SecItemAdd`.
    static func addQuery(
        for item: KeychainItem, data: Data, accessibility: KeychainAccessibility, accessGroup: String?,
        usesDataProtectionKeychain: Bool = true
    ) -> [String: Any] {
        var query = query(for: item, accessGroup: accessGroup, usesDataProtectionKeychain: usesDataProtectionKeychain)
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = accessibility.attributeValue
        return query
    }
}
