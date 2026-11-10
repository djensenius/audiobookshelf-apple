import Foundation
import Security
import Synchronization
import Testing

@testable import ABSCore

/// An in-memory Keychain keyed by service and account.
private final class InMemoryKeychain: KeychainStoring {
    struct State {
        var items: [KeychainItem: Data] = [:]
        var accessibility: [KeychainItem: KeychainAccessibility] = [:]
        var reads = 0
        var adds = 0
        var deletes = 0
        var failure: KeychainError?
        /// Simulates another process adding the item between this process's read and add.
        var racingValue: Data?
    }

    let state = Mutex(State())

    func data(for item: KeychainItem) throws(KeychainError) -> Data? {
        let result: Result<Data?, KeychainError> = state.withLock {
            $0.reads += 1
            if let failure = $0.failure { return .failure(failure) }
            return .success($0.items[item])
        }
        return try result.get()
    }

    func add(_ data: Data, for item: KeychainItem, accessibility: KeychainAccessibility) throws(KeychainError) -> Bool {
        let result: Result<Bool, KeychainError> = state.withLock {
            $0.adds += 1
            if let failure = $0.failure { return .failure(failure) }
            if let racing = $0.racingValue { $0.items[item] = racing }
            guard $0.items[item] == nil else { return .success(false) }
            $0.items[item] = data
            $0.accessibility[item] = accessibility
            return .success(true)
        }
        return try result.get()
    }

    func delete(_ item: KeychainItem) throws(KeychainError) {
        state.withLock {
            $0.deletes += 1
            $0.items[item] = nil
        }
    }
}

private func counter(prefix: String) -> @Sendable () -> String {
    let next = Mutex(0)
    return {
        next.withLock {
            $0 += 1
            return "\(prefix)-\($0)"
        }
    }
}

@Suite struct DeviceIdentifierStoreTests {
    @Test func createsOnceThisDeviceOnlyAndIsStableAcrossCalls() async {
        let keychain = InMemoryKeychain()
        let store = DeviceIdentifierStore(keychain: keychain, makeIdentifier: counter(prefix: "id"))
        #expect(store.cachedDeviceIdentifier == nil)
        let first = await store.deviceIdentifier()
        #expect(first == "id-1")
        #expect(store.cachedDeviceIdentifier == first)
        #expect(await store.deviceIdentifier() == first)
        let state = keychain.state.withLock { $0 }
        #expect(state.adds == 1)
        #expect(state.reads == 1)
        #expect(state.items[DeviceIdentifierStore.item] == Data("id-1".utf8))
        #expect(state.accessibility[DeviceIdentifierStore.item] == .afterFirstUnlockThisDeviceOnly)
    }

    @Test func newStoreReadsThePersistedIdentifier() async {
        let keychain = InMemoryKeychain()
        let first = await DeviceIdentifierStore(keychain: keychain, makeIdentifier: counter(prefix: "a"))
            .deviceIdentifier()
        let second = DeviceIdentifierStore(keychain: keychain, makeIdentifier: counter(prefix: "b"))
        #expect(await second.deviceIdentifier() == first)
        #expect(keychain.state.withLock { $0.adds } == 1)
    }

    @Test func concurrentCallsAgree() async {
        let store = DeviceIdentifierStore(keychain: InMemoryKeychain())
        let ids = await withTaskGroup(of: String.self) { group in
            for _ in 0..<20 { group.addTask { await store.deviceIdentifier() } }
            return await group.reduce(into: Set<String>()) { $0.insert($1) }
        }
        #expect(ids.count == 1)
    }

    @Test func usesTheItemAnotherProcessAddedFirst() async {
        let keychain = InMemoryKeychain()
        keychain.state.withLock { $0.racingValue = Data("other".utf8) }
        let store = DeviceIdentifierStore(keychain: keychain, makeIdentifier: counter(prefix: "id"))
        #expect(await store.deviceIdentifier() == "other")
        #expect(await store.deviceIdentifier() == "other")
    }

    @Test func emptyStoredValueIsReplaced() async {
        let keychain = InMemoryKeychain()
        keychain.state.withLock { $0.items[DeviceIdentifierStore.item] = Data() }
        let store = DeviceIdentifierStore(keychain: keychain, makeIdentifier: counter(prefix: "id"))
        #expect(await store.deviceIdentifier() == "id-1")
        let state = keychain.state.withLock { $0 }
        #expect(state.deletes == 1)
        #expect(state.items[DeviceIdentifierStore.item] == Data("id-1".utf8))
    }

    @Test func keychainFailureFallsBackWithoutPersistingAndRetriesLater() async {
        let keychain = InMemoryKeychain()
        keychain.state.withLock { $0.failure = KeychainError(status: errSecInteractionNotAllowed) }
        let store = DeviceIdentifierStore(keychain: keychain, makeIdentifier: counter(prefix: "id"))
        let fallback = await store.deviceIdentifier()
        #expect(await store.deviceIdentifier() == fallback)
        #expect(store.cachedDeviceIdentifier == nil)
        #expect(keychain.state.withLock { $0.items.isEmpty })

        keychain.state.withLock { $0.failure = nil }
        let stored = await store.deviceIdentifier()
        #expect(stored != fallback)
        #expect(await store.deviceIdentifier() == stored)
        #expect(keychain.state.withLock { $0.items.count } == 1)
    }
}

@Suite struct KeychainStoreQueryTests {
    private let item = KeychainItem(service: "svc", account: "acct")

    @Test func queryIdentifiesANonSynchronizableDataProtectionItem() {
        let query = KeychainStore.query(for: item, accessGroup: nil)
        #expect(query[kSecClass as String] as? String == kSecClassGenericPassword as String)
        #expect(query[kSecAttrService as String] as? String == "svc")
        #expect(query[kSecAttrAccount as String] as? String == "acct")
        #expect(query[kSecAttrSynchronizable as String] as? Bool == false)
        #expect(query[kSecUseDataProtectionKeychain as String] as? Bool == true)
        #expect(query[kSecAttrAccessGroup as String] == nil)
        #expect(
            KeychainStore.query(for: item, accessGroup: KeychainStore.sharedAccessGroup)[
                kSecAttrAccessGroup as String] as? String == "group.org.davidjensenius.Audiobookshelf")
    }

    @Test(arguments: [
        (
            KeychainAccessibility.afterFirstUnlockThisDeviceOnly,
            kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String
        ),
        (.afterFirstUnlock, kSecAttrAccessibleAfterFirstUnlock as String),
    ])
    func addQuerySetsDataAndAccessibility(accessibility: KeychainAccessibility, expected: String) {
        let query = KeychainStore.addQuery(
            for: item, data: Data("v".utf8), accessibility: accessibility, accessGroup: nil)
        #expect(query[kSecAttrAccessible as String] as? String == expected)
        #expect(query[kSecValueData as String] as? Data == Data("v".utf8))
        #expect(query[kSecAttrSynchronizable as String] as? Bool == false)
    }
}

/// Whether this process can use the data-protection Keychain. Unsigned `swift test` binaries
/// usually can't (`errSecMissingEntitlement`), so the real-Keychain test is skipped there.
private let isKeychainAvailable: Bool = {
    let store = KeychainStore(accessGroup: nil)
    let item = KeychainItem(service: "org.davidjensenius.Audiobookshelf.tests", account: UUID().uuidString)
    do {
        _ = try store.add(Data("probe".utf8), for: item, accessibility: .afterFirstUnlockThisDeviceOnly)
        try store.delete(item)
        return true
    } catch {
        return false
    }
}()

@Suite struct KeychainStoreSystemTests {
    @Test(.enabled(if: isKeychainAvailable, "Needs a process with Keychain access"))
    func addReadDuplicateDelete() throws {
        let store = KeychainStore(accessGroup: nil)
        let item = KeychainItem(service: "org.davidjensenius.Audiobookshelf.tests", account: UUID().uuidString)
        defer { try? store.delete(item) }
        #expect(try store.data(for: item) == nil)
        #expect(try store.add(Data("one".utf8), for: item, accessibility: .afterFirstUnlockThisDeviceOnly))
        #expect(try !store.add(Data("two".utf8), for: item, accessibility: .afterFirstUnlockThisDeviceOnly))
        #expect(try store.data(for: item) == Data("one".utf8))
        try store.delete(item)
        #expect(try store.data(for: item) == nil)
    }
}
