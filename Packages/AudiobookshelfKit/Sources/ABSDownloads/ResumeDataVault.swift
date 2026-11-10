import CryptoKit
import Foundation
import OSLog
import Security

/// Seals URLSession resume data, which embeds the original request with its `Authorization`
/// and custom headers, so those secrets never reach disk in the clear (ADR 0003).
///
/// Each blob is AES-GCM sealed with one per-install key from a ``ResumeDataKeyStore`` and
/// written to `ResumeData/<part id>.bin` with `completeUntilFirstUserAuthentication`
/// protection, excluded from backup. The part ID and a tag of the request's credentials are
/// authenticated with it, so resume data only opens for the part and credentials it was
/// created with. A blob that doesn't open (wrong credentials, missing key, corruption) is
/// deleted, and the caller falls back to a fresh request.
public struct ResumeDataVault: Sendable {
    private let directory: URL
    private let keyStore: any ResumeDataKeyStore

    public init(directory: URL, keyStore: any ResumeDataKeyStore = KeychainResumeDataKeyStore()) {
        self.directory = directory
        self.keyStore = keyStore
    }

    private static let logger = Logger(subsystem: "org.davidjensenius.Audiobookshelf", category: "downloads")

    /// A digest of the request's URL and headers (including `Authorization` and the custom
    /// headers). A token refresh or a custom-header change gives a different tag.
    public static func credentialTag(for request: URLRequest?) -> Data {
        var text = request?.url?.absoluteString ?? ""
        let headers = (request?.allHTTPHeaderFields ?? [:]).map { ($0.key.lowercased(), $0.value) }.sorted { $0 < $1 }
        for (name, value) in headers {
            text += "\n\(name):\(value)"
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

    /// The resume data for `partID` if it was sealed with `credentialTag`; otherwise deletes
    /// the blob and returns `nil`.
    public func open(partID: UUID, credentialTag: Data) -> Data? {
        let url = fileURL(partID: partID)
        guard let combined = try? Data(contentsOf: url) else { return nil }
        do {
            guard let key = try keyStore.loadKey() else {
                delete(partID: partID)
                return nil
            }
            let box = try AES.GCM.SealedBox(combined: combined)
            return try AES.GCM.open(box, using: key, authenticating: Self.additionalData(partID, credentialTag))
        } catch {
            Self.logger.info("Discarding resume data that doesn't open: \(error, privacy: .public)")
            delete(partID: partID)
            return nil
        }
    }

    /// Deletes the blob for `partID`, if any.
    public func delete(partID: UUID) {
        try? FileManager.default.removeItem(at: fileURL(partID: partID))
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
public struct KeychainResumeDataKeyStore: ResumeDataKeyStore {
    public struct KeychainError: Error, Equatable {
        public var status: OSStatus
    }

    private let service: String

    public init(service: String = "org.davidjensenius.Audiobookshelf.resume-data") {
        self.service = service
    }

    private var query: [CFString: Any] {
        [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: "key",
            kSecAttrSynchronizable: false,
            kSecUseDataProtectionKeychain: true,
        ]
    }

    public func loadKey() throws -> SymmetricKey? {
        var query = query
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw KeychainError(status: status) }
        return SymmetricKey(data: data)
    }

    public func createKey() throws -> SymmetricKey {
        let key = SymmetricKey(size: .bits256)
        var attributes = query
        attributes[kSecValueData] = key.withUnsafeBytes { Data($0) }
        attributes[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(attributes as CFDictionary, nil)
        if status == errSecDuplicateItem, let existing = try loadKey() { return existing }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
        return key
    }
}
