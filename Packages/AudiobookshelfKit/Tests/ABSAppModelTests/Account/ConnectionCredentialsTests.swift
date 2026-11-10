import ABSAPI
import ABSCore
import Foundation
import Security
import Synchronization
import Testing

@testable import ABSAppModel

/// Records the generations that `onExpire` reports.
private final class ExpiryRecorder: Sendable {
    private let generations = Mutex<[Int]>([])

    func record(_ generation: Int) {
        generations.withLock { $0.append(generation) }
    }

    var recorded: [Int] { generations.withLock { $0 } }
}

@Suite struct ConnectionCredentialsTests {
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

    @Test func corruptItemsReadAsMissing() throws {
        let keychain = InMemoryKeychain()
        let id = UUID()
        let item = CredentialVault.item(CredentialVault.sessionService, id)
        _ = try keychain.add(Data("not json".utf8), for: item, accessibility: .afterFirstUnlock)
        #expect(try CredentialVault(keychain: keychain).session(for: id) == nil)
        let description = String(describing: StoredSession(tokens: first, openIDSession: nil))
        #expect(!description.contains("access-1") && !description.contains("refresh-1"))
    }
}
