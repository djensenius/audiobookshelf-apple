import ABSAPI
import ABSCore
import Foundation
import Security
import Synchronization
import Testing

@testable import ABSAppModel

extension ConnectionCredentials {
    /// For tests that don't look at whether the delete failed.
    fileprivate init(
        connectionID: UUID, vault: CredentialVault, onExpire: @escaping @MainActor @Sendable (UUID, Int) -> Void
    ) {
        self.init(connectionID: connectionID, vault: vault) { id, generation, _ in onExpire(id, generation) }
    }
}

/// Records the generations that `onExpire` reports.
private final class ExpiryRecorder: Sendable {
    private let generations = Mutex<[Int]>([])

    func record(_ generation: Int) {
        generations.withLock { $0.append(generation) }
    }

    var recorded: [Int] { generations.withLock { $0 } }
}

@Suite(.timeLimit(.minutes(1))) struct ConnectionCredentialsTests {
    private let first = AuthTokens(accessToken: "access-1", refreshToken: "refresh-1")
    private let second = AuthTokens(accessToken: "access-2", refreshToken: "refresh-2")

    @Test func refreshedTokensStayInMemoryUntilTheKeychainTakesThem() async throws {
        let keychain = InMemoryKeychain()
        let vault = CredentialVault(keychain: keychain)
        let id = UUID()
        let credentials = ConnectionCredentials(connectionID: id, vault: vault) { _, _ in }
        _ = try await credentials.signIn(StoredSession(tokens: first, openIDSession: nil), customHeaders: [:])

        keychain.failWrites(with: errSecInteractionNotAllowed)
        #expect(await credentials.replaceTokens(expected: first, with: second))
        #expect(await !credentials.replaceTokens(expected: first, with: first))
        #expect(await credentials.tokens() == second)
        #expect(try vault.session(for: id)?.tokens == first)

        keychain.failWrites(with: nil)
        #expect(await credentials.tokens() == second)
        #expect(try vault.session(for: id)?.tokens == second)
    }

    @Test func expiryComparesAndReportsItsGeneration() async throws {
        let recorder = ExpiryRecorder()
        let vault = CredentialVault(keychain: InMemoryKeychain())
        let credentials = ConnectionCredentials(connectionID: UUID(), vault: vault) { _, generation in
            recorder.record(generation)
        }
        let session = StoredSession(tokens: first, openIDSession: nil)
        let signedIn = try await credentials.signIn(session, customHeaders: [:]).generation

        #expect(await !credentials.expireSession(ifCurrent: second))
        #expect(await credentials.expireSession(ifCurrent: first))
        #expect(await credentials.tokens() == nil)
        #expect(recorder.recorded == [signedIn + 1])
        #expect(try await credentials.signIn(session, customHeaders: [:]).generation > signedIn + 1)
    }

    @Test func signOutKeepsASessionANewerCallStored() async throws {
        let vault = CredentialVault(keychain: InMemoryKeychain())
        let id = UUID()
        _ = try await ConnectionCredentials(connectionID: id, vault: vault) { _, _ in }
            .signIn(StoredSession(tokens: first, openIDSession: nil), customHeaders: [:])
        let credentials = ConnectionCredentials(connectionID: id, vault: vault) { _, _ in }
        #expect(try await credentials.loadSession().storedBySignIn == false)
        // Read from the Keychain, so any call signs out of it.
        #expect(await credentials.signOut(savedBefore: 1)?.ended?.tokens == first)

        let session = StoredSession(tokens: second, openIDSession: nil)
        _ = try await credentials.signIn(session, customHeaders: [:], operation: 3)
        #expect(try await credentials.loadSession().storedBySignIn)
        #expect(await credentials.holdsSignIn(after: 2))
        #expect(await !credentials.holdsSignIn(after: 3))
        #expect(await credentials.signOut(savedBefore: 3) == nil)
        #expect(try await credentials.load().session == session)
        #expect(try vault.session(for: id) == session)
        let signedOut = await credentials.signOut(savedBefore: 4)
        #expect(signedOut?.ended == session && signedOut?.deleteError == nil)
        #expect(try vault.session(for: id) == nil)
        #expect(try await credentials.loadSession().storedBySignIn == false)
        #expect(await !credentials.holdsSignIn(after: 0))
    }

    @Test func corruptItemsReadAsMissing() throws {
        let keychain = InMemoryKeychain()
        let id = UUID()
        let item = CredentialVault.item(id)
        _ = try keychain.add(Data("not json".utf8), for: item, accessibility: .afterFirstUnlock)
        #expect(try CredentialVault(keychain: keychain).session(for: id) == nil)
        let description = String(describing: StoredSession(tokens: first, openIDSession: nil))
        #expect(!description.contains("access-1") && !description.contains("refresh-1"))
    }

    @Test func aFailedSignInKeepsThePreviousCredentials() async throws {
        let keychain = InMemoryKeychain()
        let vault = CredentialVault(keychain: keychain)
        let id = UUID()
        let credentials = ConnectionCredentials(connectionID: id, vault: vault) { _, _ in }
        let headers = ["X-Proxy": "old"]
        _ = try await credentials.signIn(StoredSession(tokens: first, openIDSession: nil), customHeaders: headers)

        // Only the write carrying the new session fails, so new headers written alone would land.
        keychain.failWrites(with: errSecInteractionNotAllowed) { data in
            data.map { String(decoding: $0, as: UTF8.self).contains("refresh-2") } ?? false
        }
        await #expect(throws: KeychainError.self) {
            try await credentials.signIn(
                StoredSession(tokens: second, openIDSession: nil), customHeaders: ["X-Proxy": "new"])
        }
        keychain.failWrites(with: nil)

        let loaded = try await credentials.load()
        #expect(loaded.session?.tokens == first)
        #expect(loaded.customHeaders == headers)
        #expect(try vault.session(for: id)?.tokens == first)
        #expect(try vault.customHeaders(for: id) == headers)
        let relaunched = try await ConnectionCredentials(connectionID: id, vault: vault) { _, _ in }.load()
        #expect(relaunched.session?.tokens == first)
        #expect(relaunched.customHeaders == headers)
    }

    /// Fails the first delete, or lets one through and fails the next.
    @Test(arguments: [0, 1])
    func aFailedRemovalLeavesMemoryAndTheKeychainAgreeing(deletesAllowed: Int) async throws {
        let keychain = InMemoryKeychain()
        let vault = CredentialVault(keychain: keychain)
        let id = UUID()
        let credentials = ConnectionCredentials(connectionID: id, vault: vault) { _, _ in }
        let headers = ["X-Proxy": "secret"]
        _ = try await credentials.signIn(StoredSession(tokens: first, openIDSession: nil), customHeaders: headers)

        keychain.failWrites(with: errSecInteractionNotAllowed, allowing: deletesAllowed) { $0 == nil }
        let removed = (try? await credentials.removeAll()) != nil
        keychain.failWrites(with: nil)

        let inMemory = try await credentials.load()
        let relaunched = try await ConnectionCredentials(connectionID: id, vault: vault) { _, _ in }.load()
        #expect(inMemory.session?.tokens == (removed ? nil : first))
        #expect(inMemory.customHeaders == (removed ? [:] : headers))
        #expect(try vault.session(for: id) == inMemory.session)
        #expect(try vault.customHeaders(for: id) == inMemory.customHeaders)
        #expect(relaunched.session == inMemory.session)
        #expect(relaunched.customHeaders == inMemory.customHeaders)

        // Retrying finishes the removal.
        _ = try await credentials.removeAll()
        #expect(keychain.isEmpty)
    }
}
