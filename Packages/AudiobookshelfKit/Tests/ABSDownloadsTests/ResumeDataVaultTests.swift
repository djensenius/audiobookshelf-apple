import CryptoKit
import Foundation
import Security
import Testing

@testable import ABSDownloads

@Suite struct ResumeDataVaultTests {
    private let directory = FileManager.default.temporaryDirectory.appending(path: "vault-\(UUID().uuidString)")
    private let partID = UUID()
    private let plaintext = Data("Authorization: Bearer secret-token; CF-Access-Client-Secret: proxy-secret".utf8)
    private let tag = Data("tag-1".utf8)

    private func sealedVault(keyStore: MemoryKeyStore = MemoryKeyStore()) throws -> ResumeDataVault {
        let vault = ResumeDataVault(directory: directory, keyStore: keyStore)
        try vault.seal(plaintext, partID: partID, credentialTag: tag)
        return vault
    }

    private var blobExists: Bool {
        FileManager.default.fileExists(
            atPath: directory.appending(path: "\(partID.uuidString).bin").path(percentEncoded: false))
    }

    @Test func roundTripsWithoutPlaintextOnDisk() throws {
        let vault = try sealedVault()
        let blob = try Data(contentsOf: vault.fileURL(partID: partID))
        #expect(blob.range(of: Data("secret-token".utf8)) == nil)
        #expect(blob.range(of: Data("proxy-secret".utf8)) == nil)
        #expect(try directory.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
        #expect(try vault.open(partID: partID, credentialTag: tag) == plaintext)
    }

    @Test func changedCredentialsDeleteBlob() throws {
        let vault = try sealedVault()
        #expect(try vault.open(partID: partID, credentialTag: Data("tag-2".utf8)) == nil)
        #expect(!blobExists)
    }

    @Test func missingKeyDeletesBlob() throws {
        let vault = try sealedVault()
        let reinstalled = ResumeDataVault(directory: directory, keyStore: MemoryKeyStore())
        #expect(try reinstalled.open(partID: partID, credentialTag: tag) == nil)
        #expect(!blobExists)
        #expect(try vault.open(partID: partID, credentialTag: tag) == nil)
    }

    @Test func corruptBlobIsDeleted() throws {
        let vault = try sealedVault()
        try Data("garbage".utf8).write(to: vault.fileURL(partID: partID))
        #expect(try vault.open(partID: partID, credentialTag: tag) == nil)
        #expect(!blobExists)
    }

    @Test func blobOnlyOpensForItsPart() throws {
        let vault = try sealedVault()
        let other = UUID()
        try FileManager.default.copyItem(at: vault.fileURL(partID: partID), to: vault.fileURL(partID: other))
        #expect(try vault.open(partID: other, credentialTag: tag) == nil)
        #expect(try vault.open(partID: partID, credentialTag: tag) == plaintext)
    }

    @Test func unreadableKeyKeepsBlob() throws {
        _ = try sealedVault()
        let locked = ResumeDataVault(directory: directory, keyStore: FailingKeyStore())
        #expect(throws: TestError.self) { try locked.open(partID: partID, credentialTag: tag) }
        #expect(blobExists)
    }

    @Test func credentialTagCoversNetworkAccess() {
        let request = URLRequest(url: URL(string: "https://abs.example.com/api/items/li_1/file/1/download")!)
        let tag = ResumeDataVault.credentialTag(for: request)
        var noCellular = request
        noCellular.allowsCellularAccess = false
        var noExpensive = request
        noExpensive.allowsExpensiveNetworkAccess = false
        var noConstrained = request
        noConstrained.allowsConstrainedNetworkAccess = false
        #expect(
            Set([tag] + [noCellular, noExpensive, noConstrained].map(ResumeDataVault.credentialTag(for:))).count == 4)
    }

    @Test func keychainKeyIsThisDeviceOnlyAndNeverSynchronised() {
        let store = KeychainResumeDataKeyStore(service: "test.service")
        let attributes = store.addAttributes(keyData: Data([1, 2, 3]))
        #expect(attributes[kSecAttrService] as? String == "test.service")
        #expect(attributes[kSecAttrAccount] as? String == "key")
        #expect(attributes[kSecAttrSynchronizable] as? Bool == false)
        #expect(attributes[kSecUseDataProtectionKeychain] as? Bool == true)
        #expect(attributes[kSecValueData] as? Data == Data([1, 2, 3]))
        #expect((attributes[kSecClass] as! CFString) == kSecClassGenericPassword)
        #expect((attributes[kSecAttrAccessible] as! CFString) == kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly)
        #expect(store.query[kSecAttrAccessible] == nil)
        #expect(store.query[kSecValueData] == nil)
    }

    @Test func credentialTagCoversTokenAndCustomHeaders() {
        var request = URLRequest(url: URL(string: "https://abs.example.com/api/items/li_1/file/1/download")!)
        request.setValue("Bearer token-1", forHTTPHeaderField: "Authorization")
        request.setValue("one", forHTTPHeaderField: "X-Proxy")
        let tag = ResumeDataVault.credentialTag(for: request)
        var refreshed = request
        refreshed.setValue("Bearer token-2", forHTTPHeaderField: "Authorization")
        var edited = request
        edited.setValue("two", forHTTPHeaderField: "X-Proxy")
        #expect(ResumeDataVault.credentialTag(for: request) == tag)
        #expect(ResumeDataVault.credentialTag(for: refreshed) != tag)
        #expect(ResumeDataVault.credentialTag(for: edited) != tag)
    }
}

private struct FailingKeyStore: ResumeDataKeyStore {
    func loadKey() throws -> SymmetricKey? { throw TestError() }
    func createKey() throws -> SymmetricKey { throw TestError() }
}
