import ABSCore
import CryptoKit
import Foundation
import Security
import Synchronization

/// Seals URLSession resume data, which embeds the original request with its `Authorization`
/// and custom headers, so those secrets never reach disk in the clear (ADR 0003).
///
/// Each blob is AES-GCM sealed with one per-install key from a ``ResumeDataKeyStore`` and
/// written to `ResumeData/<part id>.bin` with `completeUntilFirstUserAuthentication`
/// protection, excluded from backup. The part ID and a tag of the request's credentials and
/// network access are authenticated with it, so resume data only opens for the part and
/// request it was created with. A blob that can never open (other credentials or network
/// access, a lost key, corruption) is deleted, and the caller falls back to a fresh request.
public struct ResumeDataVault: Sendable {
    private let directory: URL
    private let keyStore: any ResumeDataKeyStore

    public init(directory: URL, keyStore: any ResumeDataKeyStore = KeychainResumeDataKeyStore()) {
        self.directory = directory
        self.keyStore = keyStore
    }

    /// A digest of the request's URL, headers (including `Authorization` and the custom
    /// headers) and network access flags. A token refresh, a custom-header change or a change
    /// of the cellular policy gives a different tag.
    public static func credentialTag(for request: URLRequest?) -> Data {
        var text = request?.url?.absoluteString ?? ""
        let headers = (request?.allHTTPHeaderFields ?? [:]).map { ($0.key.lowercased(), $0.value) }.sorted { $0 < $1 }
        for (name, value) in headers {
            text += "\n\(name):\(value)"
        }
        if let request {
            text += "\n\(request.allowsCellularAccess) \(request.allowsExpensiveNetworkAccess)"
            text += " \(request.allowsConstrainedNetworkAccess)"
        }
        return Data(SHA256.hash(data: Data(text.utf8)))
    }

    func fileURL(partID: UUID) -> URL {
        directory.appending(path: "\(partID.uuidString).bin", directoryHint: .notDirectory)
    }

    /// Seals and stores `resumeData` for `partID`, replacing any earlier blob.
    public func seal(_ resumeData: Data, partID: UUID, credentialTag: Data) throws {
        let key = try keyStore.loadKey() ?? keyStore.createKey()
        let box = try AES.GCM.seal(resumeData, using: key, authenticating: Self.additionalData(partID, credentialTag))
        guard let combined = box.combined else { throw CryptoKitError.incorrectParameterSize }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var directory = directory
        try directory.setResourceValues(values)
        try combined.write(
            to: fileURL(partID: partID), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    /// The resume data for `partID` if it was sealed with `credentialTag`. Returns `nil` when
    /// there is none or it can never open (sealed for other credentials, the key is gone, or
    /// it is corrupt); such a blob is deleted.
    ///
    /// - Throws: when the blob or the key can't be read now (for example the Keychain or the
    ///   file is unavailable); the blob is kept for a later attempt.
    public func open(partID: UUID, credentialTag: Data) throws -> Data? {
        let url = fileURL(partID: partID)
        let combined: Data
        do {
            combined = try Data(contentsOf: url)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return nil
        }
        guard let key = try keyStore.loadKey() else {
            delete(partID: partID)
            return nil
        }
        do {
            let box = try AES.GCM.SealedBox(combined: combined)
            return try AES.GCM.open(box, using: key, authenticating: Self.additionalData(partID, credentialTag))
        } catch {
            Log.downloads.info(
                "Discarding resume data that doesn't open: \(Log.redact(String(describing: error)), privacy: .public)")
            delete(partID: partID)
            return nil
        }
    }

    /// Deletes the blob for `partID`, if any.
    ///
    /// - Returns: `false` when the blob is still there (the file couldn't be removed).
    @discardableResult
    public func delete(partID: UUID) -> Bool {
        do {
            try FileManager.default.removeItem(at: fileURL(partID: partID))
        } catch let error as CocoaError where error.code == .fileNoSuchFile {
        } catch {
            return false
        }
        return true
    }

    /// Deletes every blob whose part isn't in `kept`: those left when a record went although its
    /// blob's delete failed (#515). A failure is logged and the blob kept for the next sweep; a
    /// file that isn't named `<part id>.bin` is left alone.
    ///
    /// - Returns: `false` when the folder couldn't be listed or a blob couldn't be deleted.
    @discardableResult
    public func deleteBlobs(except kept: Set<UUID>) -> Bool {
        let names: [String]
        do {
            names = try FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false))
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return true
        } catch {
            Log.downloads.error(
                "Couldn't list resume data to sweep: \(Log.redact(String(describing: error)), privacy: .public)")
            return false
        }
        var deleted = true
        for name in names where name.hasSuffix(".bin") {
            guard let partID = UUID(uuidString: String(name.dropLast(4))), !kept.contains(partID) else { continue }
            if !delete(partID: partID) {
                Log.downloads.error("Couldn't delete resume data no download uses; the next activation tries again")
                deleted = false
            }
        }
        return deleted
    }

    private static func additionalData(_ partID: UUID, _ credentialTag: Data) -> Data {
        Data(partID.uuidString.utf8) + credentialTag
    }
}

/// Stores the vault's key.
public protocol ResumeDataKeyStore: Sendable {
    /// The key, or `nil` when there is none yet (or it was lost).
    func loadKey() throws -> SymmetricKey?
    /// Creates and stores a key, or returns the stored one if another caller created it first.
    func createKey() throws -> SymmetricKey
}

/// Keeps the vault key in the data-protection Keychain: this device only, available after
/// first unlock, never synchronised.
///
/// A build without a Keychain access group (the ad hoc macOS build) gets
/// `errSecMissingEntitlement` (-34018): resume data is then not kept, and interrupted parts
/// start again from the beginning. That is logged once as a fault.
public struct KeychainResumeDataKeyStore: ResumeDataKeyStore {
    public struct KeychainError: Error, Equatable {
        public var status: OSStatus
    }

    private let service: String

    public init(service: String = "org.davidjensenius.Audiobookshelf.resume-data") {
        self.service = service
    }

    /// The attributes that identify the key.
    var query: [CFString: Any] {
        [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: "key",
            kSecAttrSynchronizable: false,
            kSecUseDataProtectionKeychain: true,
        ]
    }

    /// The attributes that add `keyData`.
    func addAttributes(keyData: Data) -> [CFString: Any] {
        var attributes = query
        attributes[kSecValueData] = keyData
        attributes[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return attributes
    }

    private static let reportedMissingEntitlement = Atomic(false)

    private func check(_ status: OSStatus) throws {
        guard status != errSecSuccess else { return }
        if status == errSecMissingEntitlement, !Self.reportedMissingEntitlement.exchange(true, ordering: .relaxed) {
            Log.downloads.fault(
                "The Keychain refused the resume-data key (-34018, missing entitlement); resume data won't be kept")
        }
        throw KeychainError(status: status)
    }

    public func loadKey() throws -> SymmetricKey? {
        var query = query
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        try check(status)
        guard let data = result as? Data else { throw KeychainError(status: errSecDecode) }
        return SymmetricKey(data: data)
    }

    public func createKey() throws -> SymmetricKey {
        let key = SymmetricKey(size: .bits256)
        let status = SecItemAdd(addAttributes(keyData: key.withUnsafeBytes { Data($0) }) as CFDictionary, nil)
        if status == errSecDuplicateItem, let existing = try loadKey() { return existing }
        try check(status)
        return key
    }
}
