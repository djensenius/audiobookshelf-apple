import Foundation
import Security
import Synchronization
import Testing

@testable import ABSCore

private let item = KeychainItem(service: "org.davidjensenius.Audiobookshelf.tests", account: "account")

@Suite struct KeychainStoreTests {
    @Test func queryUsesDataProtectionKeychainWithoutSync() {
        let query = KeychainStore.query(for: item, accessGroup: KeychainStore.sharedAccessGroup)
        #expect(query[kSecUseDataProtectionKeychain as String] as? Bool == true)
        #expect(query[kSecAttrSynchronizable as String] as? Bool == false)
        #expect(query[kSecAttrAccessGroup as String] as? String == "9JALHNGRBQ.org.davidjensenius.Audiobookshelf")
        #expect(query[kSecAttrService as String] as? String == item.service)
        #expect(query[kSecAttrAccount as String] as? String == item.account)
    }

    @Test func loginKeychainQueryHasNoDataProtectionOrGroup() {
        let query = KeychainStore.query(for: item, accessGroup: nil, usesDataProtectionKeychain: false)
        #expect(query[kSecUseDataProtectionKeychain as String] == nil)
        #expect(query[kSecAttrAccessGroup as String] == nil)
    }

    @Test func addQuerySetsAfterFirstUnlock() throws {
        let query = KeychainStore.addQuery(
            for: item, data: Data("v".utf8), accessibility: .afterFirstUnlock, accessGroup: nil)
        let accessible = try #require(query[kSecAttrAccessible as String] as? String)
        #expect(accessible == kSecAttrAccessibleAfterFirstUnlock as String)
        #expect(query[kSecValueData as String] as? Data == Data("v".utf8))
    }

    @Test func defaultSetReplacesThroughDeleteAndAdd() throws {
        let keychain = DictionaryKeychain()
        try keychain.set(Data("1".utf8), for: item, accessibility: .afterFirstUnlock)
        try keychain.set(Data("2".utf8), for: item, accessibility: .afterFirstUnlock)
        #expect(try keychain.data(for: item) == Data("2".utf8))
    }

    @Test func errorsDescribeTheStatus() {
        let error = KeychainError(status: errSecMissingEntitlement)
        #expect(error.isUnavailable)
        #expect(error.description.contains("-34018"))
        #expect(!KeychainError(status: errSecDuplicateItem).isUnavailable)
    }
}

/// The status of a probe add and delete in the login keychain, or `nil` when it succeeded.
private let loginKeychainProbeStatus: OSStatus? = {
    let store = KeychainStore(usesDataProtectionKeychain: false)
    let item = KeychainItem(service: "org.davidjensenius.Audiobookshelf.tests", account: UUID().uuidString)
    do throws(KeychainError) {
        _ = try store.add(Data("probe".utf8), for: item, accessibility: .afterFirstUnlock)
        try store.delete(item)
        return nil
    } catch {
        return error.status
    }
}()

/// The real Keychain. An unsigned `swift test` binary can't use the data-protection Keychain
/// (`errSecMissingEntitlement`), so this uses the macOS login keychain. It's skipped only if the
/// Keychain is unavailable (for example no unlocked default keychain on a CI runner); any other
/// probe error fails.
@Suite struct KeychainStoreRoundTripTests {
    @Test(
        .disabled(
            if: loginKeychainProbeStatus.map { KeychainError(status: $0).isUnavailable } ?? false,
            "Needs an unlocked login keychain"))
    func addSetReadDelete() throws {
        #expect(loginKeychainProbeStatus == nil)
        let store = KeychainStore(accessGroup: nil, usesDataProtectionKeychain: false)
        let item = KeychainItem(service: "org.davidjensenius.Audiobookshelf.tests", account: UUID().uuidString)
        defer { try? store.delete(item) }

        #expect(try store.data(for: item) == nil)
        #expect(try store.add(Data("first".utf8), for: item, accessibility: .afterFirstUnlock))
        #expect(try !store.add(Data("other".utf8), for: item, accessibility: .afterFirstUnlock))
        #expect(try store.data(for: item) == Data("first".utf8))

        try store.set(Data("second".utf8), for: item, accessibility: .afterFirstUnlock)
        #expect(try store.data(for: item) == Data("second".utf8))

        try store.delete(item)
        #expect(try store.data(for: item) == nil)
        try store.delete(item)

        try store.set(Data("added".utf8), for: item, accessibility: .afterFirstUnlock)
        #expect(try store.data(for: item) == Data("added".utf8))
    }
}

/// Implements only the required members, to exercise the protocol's default `set`.
private final class DictionaryKeychain: KeychainStoring {
    private let items = Mutex<[KeychainItem: Data]>([:])

    func data(for item: KeychainItem) throws(KeychainError) -> Data? {
        items.withLock { $0[item] }
    }

    func add(_ data: Data, for item: KeychainItem, accessibility: KeychainAccessibility) throws(KeychainError) -> Bool {
        items.withLock { items in
            guard items[item] == nil else { return false }
            items[item] = data
            return true
        }
    }

    func delete(_ item: KeychainItem) throws(KeychainError) {
        _ = items.withLock { $0.removeValue(forKey: item) }
    }
}
