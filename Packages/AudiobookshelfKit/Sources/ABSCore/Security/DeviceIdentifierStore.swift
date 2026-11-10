import Foundation
import OSLog
import Security
import Synchronization

/// Supplies the stable device ID sent as `deviceInfo.deviceId` when starting playback.
public protocol DeviceIdentifying: Sendable {
    func deviceIdentifier() async -> String
}

/// A stable per-device ID kept in the Keychain (ADR 0007). `identifierForVendor` doesn't exist
/// on macOS. The item survives reinstalling the app on this device and never migrates to
/// another device (`afterFirstUnlockThisDeviceOnly`): two devices sharing an ID would keep
/// closing each other's server sessions.
///
/// The first call reads or creates the ID off the caller's actor and caches it; later calls are
/// a cached read. An empty stored value is treated as corrupt and replaced. If the Keychain
/// fails (for example before first unlock), a per-process fallback ID is returned, the failure
/// is logged, and the Keychain is tried again on the next call; the fallback is never stored.
public final class DeviceIdentifierStore: DeviceIdentifying {
    public static let item = KeychainItem(
        service: "org.davidjensenius.Audiobookshelf.device", account: "deviceIdentifier")
    public static let accessibility = KeychainAccessibility.afterFirstUnlockThisDeviceOnly

    private static let logger = Logger(subsystem: "org.davidjensenius.Audiobookshelf", category: "DeviceIdentifier")

    private struct State {
        var stored: String?
        var fallback: String?
    }

    private let keychain: any KeychainStoring
    private let makeIdentifier: @Sendable () -> String
    private let state = Mutex(State())

    public init(
        keychain: any KeychainStoring = KeychainStore(accessGroup: KeychainStore.sharedAccessGroup),
        makeIdentifier: @escaping @Sendable () -> String = { UUID().uuidString }
    ) {
        self.keychain = keychain
        self.makeIdentifier = makeIdentifier
    }

    /// The ID if it has already been loaded from the Keychain.
    public var cachedDeviceIdentifier: String? {
        state.withLock { $0.stored }
    }

    @concurrent
    public func deviceIdentifier() async -> String {
        if let stored = cachedDeviceIdentifier { return stored }
        do {
            let loaded = try loadOrCreate()
            return state.withLock { state in
                if let stored = state.stored { return stored }
                state.stored = loaded
                return loaded
            }
        } catch {
            Self.logger.error(
                "Keychain unavailable (OSStatus \(error.status, privacy: .public)); using a per-process device ID")
            return state.withLock { state in
                if let fallback = state.fallback { return fallback }
                let fallback = makeIdentifier()
                state.fallback = fallback
                return fallback
            }
        }
    }

    /// Concurrent first loads converge: only one add succeeds, and the others read its value.
    private func loadOrCreate() throws(KeychainError) -> String {
        if let data = try keychain.data(for: Self.item) {
            let value = String(decoding: data, as: UTF8.self)
            if !value.isEmpty { return value }
            try keychain.delete(Self.item)
        }
        let identifier = makeIdentifier()
        if try keychain.add(Data(identifier.utf8), for: Self.item, accessibility: Self.accessibility) {
            return identifier
        }
        guard let data = try keychain.data(for: Self.item), !data.isEmpty else {
            throw KeychainError(status: errSecItemNotFound)
        }
        return String(decoding: data, as: UTF8.self)
    }
}
