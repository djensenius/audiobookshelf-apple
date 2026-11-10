import Foundation
import Security
import Synchronization

/// A Keychain status code returned by a failed generic-password operation.
public struct KeychainError: Error, Sendable, Hashable {
    public let status: OSStatus

    public init(status: OSStatus) {
        self.status = status
    }
}

/// Reads and adds generic-password Keychain items. ``SystemKeychainPasswordStore`` is the real
/// implementation; tests inject an in-memory fake.
public protocol KeychainPasswordStoring: Sendable {
    /// The item's data, or `nil` when no item exists.
    func password(service: String, account: String) throws(KeychainError) -> Data?
    /// Adds an item. Returns `false`, without changing anything, when the item already exists.
    func addPassword(_ data: Data, service: String, account: String) throws(KeychainError) -> Bool
}

/// Generic passwords in the data-protection Keychain, readable after first unlock (so
/// background and CarPlay launches can read them) and never synchronised through iCloud.
///
/// Pass the shared keychain access group (ADR 0002) once the app and its extensions share
/// items; `nil` uses the app's default group.
public struct SystemKeychainPasswordStore: KeychainPasswordStoring {
    public let accessGroup: String?

    public init(accessGroup: String? = nil) {
        self.accessGroup = accessGroup
    }

    public func password(service: String, account: String) throws(KeychainError) -> Data? {
        var query = baseQuery(service: service, account: account)
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

    public func addPassword(_ data: Data, service: String, account: String) throws(KeychainError) -> Bool {
        var query = baseQuery(service: service, account: account)
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(query as CFDictionary, nil)
        switch status {
        case errSecSuccess: return true
        case errSecDuplicateItem: return false
        default: throw KeychainError(status: status)
        }
    }

    private func baseQuery(service: String, account: String) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false,
            kSecUseDataProtectionKeychain as String: true,
        ]
        if let accessGroup { query[kSecAttrAccessGroup as String] = accessGroup }
        return query
    }
}

/// Supplies the stable device ID sent as `deviceInfo.deviceId` when starting playback.
public protocol DeviceIdentifying: Sendable {
    func deviceIdentifier() -> String
}

/// A stable per-device ID kept in the Keychain (ADR 0007). `identifierForVendor` doesn't exist
/// on macOS, and a Keychain item survives reinstalling the app, so the server keeps seeing the
/// same device and closes this device's previous session when a new one starts.
///
/// The ID is created on first use and cached. If the Keychain can't be read (for example
/// before first unlock), a process-lifetime fallback ID is returned and the Keychain is tried
/// again on the next call; the fallback is never persisted.
public final class DeviceIdentifierStore: DeviceIdentifying {
    public static let service = "org.davidjensenius.Audiobookshelf.device"
    public static let account = "deviceIdentifier"

    private struct State {
        var stored: String?
        var fallback: String?
    }

    private let keychain: any KeychainPasswordStoring
    private let makeIdentifier: @Sendable () -> String
    private let state = Mutex(State())

    public init(
        keychain: any KeychainPasswordStoring = SystemKeychainPasswordStore(),
        makeIdentifier: @escaping @Sendable () -> String = { UUID().uuidString }
    ) {
        self.keychain = keychain
        self.makeIdentifier = makeIdentifier
    }

    public func deviceIdentifier() -> String {
        state.withLock { state in
            if let stored = state.stored { return stored }
            if let stored = loadOrCreate() {
                state.stored = stored
                return stored
            }
            let fallback = state.fallback ?? makeIdentifier()
            state.fallback = fallback
            return fallback
        }
    }

    private func loadOrCreate() -> String? {
        do {
            if let existing = try read() { return existing }
            let identifier = makeIdentifier()
            if try keychain.addPassword(Data(identifier.utf8), service: Self.service, account: Self.account) {
                return identifier
            }
            // Another process added it first.
            return try read()
        } catch {
            return nil
        }
    }

    private func read() throws(KeychainError) -> String? {
        guard let data = try keychain.password(service: Self.service, account: Self.account) else { return nil }
        let value = String(decoding: data, as: UTF8.self)
        return value.isEmpty ? nil : value
    }
}
