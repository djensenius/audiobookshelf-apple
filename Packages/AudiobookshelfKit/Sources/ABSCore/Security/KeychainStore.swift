import Foundation
import Security

// TODO(#38): finish the KeychainStore scope there: update in place, token and custom-header
// items (AfterFirstUnlock), resolving the shared access group in the app and extensions.

/// A Keychain status code returned by a failed generic-password operation.
public struct KeychainError: Error, Sendable, Hashable {
    public let status: OSStatus

    public init(status: OSStatus) {
        self.status = status
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
    /// Readable after first unlock; included in encrypted backups and device migration.
    case afterFirstUnlock
    /// Readable after first unlock; never leaves this device (no backup restore, Quick Start, or
    /// Migration Assistant).
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
    /// Deletes the item. Deleting a missing item succeeds.
    func delete(_ item: KeychainItem) throws(KeychainError)
}

/// Generic passwords in the data-protection Keychain (also on macOS), never synchronised through
/// iCloud (ADR 0002).
public struct KeychainStore: KeychainStoring {
    /// The App Group, also used as the keychain access group shared with extensions (ADR 0002).
    public static let sharedAccessGroup = AppSettings.appGroupIdentifier

    /// `nil` uses the app's default access group (tests and unsigned hosts).
    public let accessGroup: String?

    public init(accessGroup: String?) {
        self.accessGroup = accessGroup
    }

    public func data(for item: KeychainItem) throws(KeychainError) -> Data? {
        var query = Self.query(for: item, accessGroup: accessGroup)
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
        let status = SecItemAdd(
            Self.addQuery(for: item, data: data, accessibility: accessibility, accessGroup: accessGroup)
                as CFDictionary, nil)
        switch status {
        case errSecSuccess: return true
        case errSecDuplicateItem: return false
        default: throw KeychainError(status: status)
        }
    }

    public func delete(_ item: KeychainItem) throws(KeychainError) {
        let status = SecItemDelete(Self.query(for: item, accessGroup: accessGroup) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
    }

    /// The attributes identifying `item`.
    static func query(for item: KeychainItem, accessGroup: String?) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: item.service,
            kSecAttrAccount as String: item.account,
            kSecAttrSynchronizable as String: false,
            kSecUseDataProtectionKeychain as String: true,
        ]
        if let accessGroup { query[kSecAttrAccessGroup as String] = accessGroup }
        return query
    }

    /// The attributes for `SecItemAdd`.
    static func addQuery(
        for item: KeychainItem, data: Data, accessibility: KeychainAccessibility, accessGroup: String?
    ) -> [String: Any] {
        var query = query(for: item, accessGroup: accessGroup)
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = accessibility.attributeValue
        return query
    }
}
