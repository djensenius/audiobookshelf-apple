import ABSCore
import Foundation
import Synchronization
import Testing

/// An in-memory Keychain keyed by service and account.
private final class InMemoryKeychain: KeychainPasswordStoring {
    struct State {
        var items: [String: Data] = [:]
        var reads = 0
        var adds = 0
        var failure: KeychainError?
        /// Simulates another process adding the item between this process's read and add.
        var racingValue: Data?
    }

    let state = Mutex(State())

    func password(service: String, account: String) throws(KeychainError) -> Data? {
        let result: Result<Data?, KeychainError> = state.withLock {
            $0.reads += 1
            if let failure = $0.failure { return .failure(failure) }
            return .success($0.items["\(service)/\(account)"])
        }
        return try result.get()
    }

    func addPassword(_ data: Data, service: String, account: String) throws(KeychainError) -> Bool {
        let result: Result<Bool, KeychainError> = state.withLock {
            $0.adds += 1
            if let failure = $0.failure { return .failure(failure) }
            let key = "\(service)/\(account)"
            if let racing = $0.racingValue { $0.items[key] = racing }
            guard $0.items[key] == nil else { return .success(false) }
            $0.items[key] = data
            return .success(true)
        }
        return try result.get()
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
    @Test func createsOnceAndIsStableAcrossCalls() {
        let keychain = InMemoryKeychain()
        let store = DeviceIdentifierStore(keychain: keychain, makeIdentifier: counter(prefix: "id"))
        let first = store.deviceIdentifier()
        #expect(first == "id-1")
        #expect(store.deviceIdentifier() == first)
        #expect(store.deviceIdentifier() == first)
        let state = keychain.state.withLock { $0 }
        #expect(state.adds == 1)
        #expect(state.reads == 1)
        #expect(
            state.items["\(DeviceIdentifierStore.service)/\(DeviceIdentifierStore.account)"] == Data("id-1".utf8))
    }

    @Test func newStoreReadsThePersistedIdentifier() {
        let keychain = InMemoryKeychain()
        let first = DeviceIdentifierStore(keychain: keychain, makeIdentifier: counter(prefix: "a")).deviceIdentifier()
        let second = DeviceIdentifierStore(keychain: keychain, makeIdentifier: counter(prefix: "b"))
        #expect(second.deviceIdentifier() == first)
        #expect(keychain.state.withLock { $0.adds } == 1)
    }

    @Test func concurrentCallsAgree() async {
        let store = DeviceIdentifierStore(keychain: InMemoryKeychain())
        let ids = await withTaskGroup(of: String.self) { group in
            for _ in 0..<20 { group.addTask { store.deviceIdentifier() } }
            return await group.reduce(into: Set<String>()) { $0.insert($1) }
        }
        #expect(ids.count == 1)
    }

    @Test func usesTheItemAnotherProcessAddedFirst() {
        let keychain = InMemoryKeychain()
        keychain.state.withLock { $0.racingValue = Data("other".utf8) }
        let store = DeviceIdentifierStore(keychain: keychain, makeIdentifier: counter(prefix: "id"))
        #expect(store.deviceIdentifier() == "other")
        #expect(store.deviceIdentifier() == "other")
    }

    @Test func keychainFailureFallsBackWithoutPersistingAndRetriesLater() {
        let keychain = InMemoryKeychain()
        keychain.state.withLock { $0.failure = KeychainError(status: -25308) }
        let store = DeviceIdentifierStore(keychain: keychain, makeIdentifier: counter(prefix: "id"))
        let fallback = store.deviceIdentifier()
        #expect(store.deviceIdentifier() == fallback)
        #expect(keychain.state.withLock { $0.items.isEmpty })

        keychain.state.withLock { $0.failure = nil }
        let stored = store.deviceIdentifier()
        #expect(stored != fallback)
        #expect(store.deviceIdentifier() == stored)
        #expect(keychain.state.withLock { $0.items.count } == 1)
    }
}
