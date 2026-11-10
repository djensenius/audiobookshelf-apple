import CryptoKit
import Synchronization

@testable import ABSDownloads

/// Keeps the resume-data key in memory, like a Keychain that always works.
final class MemoryKeyStore: ResumeDataKeyStore {
    private let key = Mutex<SymmetricKey?>(nil)

    func loadKey() throws -> SymmetricKey? { key.withLock { $0 } }

    func createKey() throws -> SymmetricKey {
        key.withLock { stored in
            let created = stored ?? SymmetricKey(size: .bits256)
            stored = created
            return created
        }
    }
}
