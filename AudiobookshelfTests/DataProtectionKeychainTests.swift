import ABSCore
import Foundation
import Security
import Testing

/// The data-protection Keychain needs an `application-identifier` or `keychain-access-groups`
/// entitlement. `mise run test:app` signs the host app ad hoc without either, so there the probe
/// gets `errSecMissingEntitlement` and the test is skipped; see docs/testing/keychain.md.
private let dataProtectionKeychainStatus: OSStatus = {
    let store = KeychainStore()
    let probe = KeychainItem(service: "org.davidjensenius.Audiobookshelf.tests.probe", account: UUID().uuidString)
    do throws(KeychainError) {
        _ = try store.add(Data(), for: probe, accessibility: .afterFirstUnlockThisDeviceOnly)
        try store.delete(probe)
        return errSecSuccess
    } catch {
        return error.status
    }
}()

@Suite struct DataProtectionKeychainTests {
    @Test(
        .disabled(
            if: dataProtectionKeychainStatus == errSecMissingEntitlement,
            "The data-protection Keychain needs a host signed with a team (-34018); see docs/testing/keychain.md"))
    func roundTripStaysOnThisDevice() throws {
        let store = KeychainStore()
        let item = KeychainItem(service: "org.davidjensenius.Audiobookshelf.tests", account: UUID().uuidString)
        defer { try? store.delete(item) }

        #expect(try store.add(Data("one".utf8), for: item, accessibility: .afterFirstUnlock))
        #expect(try !store.add(Data("other".utf8), for: item, accessibility: .afterFirstUnlock))
        #expect(try store.data(for: item) == Data("one".utf8))
        try store.set(Data("two".utf8), for: item, accessibility: .afterFirstUnlock)
        #expect(try store.data(for: item) == Data("two".utf8))

        // Matches synchronizable items too, so an iCloud copy would show up here.
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: item.service,
            kSecAttrAccount as String: item.account,
            kSecUseDataProtectionKeychain as String: true,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var result: CFTypeRef?
        #expect(SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess)
        let items = try #require(result as? [[String: Any]])
        let attributes = try #require(items.first)
        #expect(items.count == 1)
        #expect(attributes[kSecAttrAccessible as String] as? String == kSecAttrAccessibleAfterFirstUnlock as String)
        #expect(attributes[kSecAttrSynchronizable as String] as? Bool != true)

        try store.delete(item)
        #expect(try store.data(for: item) == nil)
    }
}
