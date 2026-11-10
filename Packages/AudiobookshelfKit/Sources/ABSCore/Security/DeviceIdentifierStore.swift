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
/// The first call reads or creates the ID in a detached task, off the caller's actor, and caches
/// it; concurrent first callers wait on that one load, and later calls are a cached read. If the
/// Keychain fails (for example before first unlock), a per-process fallback ID is returned, the
/// failure is logged, and the Keychain is tried again on the next call; the fallback is never
/// stored.
///
/// Repair is atomic across stores and processes: the ID lives in the first of a few slots
/// (``item``, then ``repairItems``) that holds a valid value. A missing slot is filled with
/// add-if-absent, and a store that loses that race reads the winner's value. A corrupt slot
/// (empty or not UTF-8) is never deleted or overwritten; every store skips it to the next slot,
/// so all of them converge on the same persisted ID.
public final class DeviceIdentifierStore: DeviceIdentifying {
    public static let item = KeychainItem(
        service: "org.davidjensenius.Audiobookshelf.device", account: "deviceIdentifier")
    /// Fallback slots, used only while every earlier slot holds a corrupt value.
    public static let repairItems = (1...3).map {
        KeychainItem(service: item.service, account: "\(item.account).\($0)")
    }
    public static let accessibility = KeychainAccessibility.afterFirstUnlockThisDeviceOnly

    private static let logger = Logger(subsystem: "org.davidjensenius.Audiobookshelf", category: "DeviceIdentifier")

    private typealias Load = Task<Result<String, KeychainError>, Never>

    private struct State {
        var stored: String?
        var fallback: String?
        /// The one Keychain load in flight; concurrent first callers wait on it.
        var loading: Load?
    }

    private enum Next {
        case cached(String)
        case wait(Load)
    }

    /// Points where tests can hold a caller to force an interleaving.
    enum TestEvent: Sendable {
        /// The caller is about to wait on the shared load.
        case joinedLoad
        /// The shared load finished; the caller hasn't handled the result yet.
        case loadFinished
    }

    private let keychain: any KeychainStoring
    private let makeIdentifier: @Sendable () -> String
    private let testHook: (@Sendable (TestEvent) async -> Void)?
    private let state = Mutex(State())

    public convenience init(
        keychain: any KeychainStoring = KeychainStore(),
        makeIdentifier: @escaping @Sendable () -> String = { UUID().uuidString }
    ) {
        self.init(keychain: keychain, makeIdentifier: makeIdentifier, testHook: nil)
    }

    init(
        keychain: any KeychainStoring, makeIdentifier: @escaping @Sendable () -> String,
        testHook: (@Sendable (TestEvent) async -> Void)?
    ) {
        self.keychain = keychain
        self.makeIdentifier = makeIdentifier
        self.testHook = testHook
    }

    /// The ID if it has already been loaded from the Keychain.
    public var cachedDeviceIdentifier: String? {
        state.withLock { $0.stored }
    }

    public func deviceIdentifier() async -> String {
        let next = state.withLock { state -> Next in
            if let stored = state.stored { return .cached(stored) }
            if let loading = state.loading { return .wait(loading) }
            let load = Load.detached { Result { () throws(KeychainError) in try self.loadOrCreate() } }
            state.loading = load
            return .wait(load)
        }
        let load: Load
        switch next {
        case .cached(let stored): return stored
        case .wait(let pending): load = pending
        }
        await testHook?(.joinedLoad)
        let result = await load.value
        await testHook?(.loadFinished)
        // Another caller may have handled this load and a retry may have stored the ID since, so
        // both paths prefer `state.stored` over this (possibly stale) result.
        switch result {
        case .success(let loaded):
            return state.withLock { state in
                if state.loading == load { state.loading = nil }
                let stored = state.stored ?? loaded
                state.stored = stored
                return stored
            }
        case .failure(let error):
            let (identifier, isFallback) = state.withLock { state in
                if state.loading == load { state.loading = nil }
                if let stored = state.stored { return (stored, false) }
                if let fallback = state.fallback { return (fallback, true) }
                let fallback = makeIdentifier()
                state.fallback = fallback
                return (fallback, true)
            }
            if isFallback {
                Self.logger.error(
                    "Keychain unavailable (OSStatus \(error.status, privacy: .public)); using a per-process device ID")
            }
            return identifier
        }
    }

    /// The persisted ID. Internal so tests can interleave two stores' repairs.
    func loadOrCreate() throws(KeychainError) -> String {
        for slot in [Self.item] + Self.repairItems {
            if let data = try keychain.data(for: slot) {
                if let value = Self.validIdentifier(data) { return value }
                continue  // Corrupt: leave it, so no other store's repair is undone.
            }
            _ = try keychain.add(Data(makeIdentifier().utf8), for: slot, accessibility: Self.accessibility)
            // Whether this add won or another store's did, cache what is persisted.
            guard let data = try keychain.data(for: slot) else { throw KeychainError(status: errSecItemNotFound) }
            if let value = Self.validIdentifier(data) { return value }
        }
        throw KeychainError(status: errSecDecode)
    }

    private static func validIdentifier(_ data: Data) -> String? {
        guard let value = String(data: data, encoding: .utf8), !value.isEmpty else { return nil }
        return value
    }
}
