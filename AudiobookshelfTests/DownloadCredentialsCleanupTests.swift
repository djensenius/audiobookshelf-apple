import ABSAPI
import ABSAppModel
import ABSCore
import ABSData
import ABSDownloads
import Foundation
import Testing

@testable import Audiobookshelf

/// The environment stops a connection's downloads when its session expires while another
/// connection is active, and when a sign-in replaces its saved session (#386).
@MainActor @Suite(.timeLimit(.minutes(1))) struct DownloadCredentialsCleanupTests {
    private let keychain = ConnectTestKeychain()
    private let suiteName = "DownloadCredentialsCleanupTests.\(UUID().uuidString)"
    private let downloads = TestDownloads()

    private func signIn(_ accounts: AccountManager, to host: String) async throws -> UUID {
        let model = ConnectViewModel(
            accounts: accounts, validator: ServerValidator(sessionConfiguration: ConnectTestProtocol.configuration),
            localNetwork: PreviewLocalNetworkAccess())
        model.addServer()
        model.address = "https://\(host)"
        await model.submitAddress()
        model.username = "reader"
        await model.signIn()
        try #require(model.phase == .done)
        return try #require(accounts.activeConnection).id
    }

    /// A downloading record of `connectionID` whose part has sealed resume data.
    private func addDownloading(
        _ connectionID: UUID, store: DownloadStore, locations: DownloadLocations
    ) async throws -> (record: UUID, blob: URL) {
        let part = DownloadPartDTO(
            kind: .audio, serverPath: "/api/items/li_1/file/1/download", filename: "1.mp3", mimeType: "audio/mpeg",
            expectedBytes: 11, destinationRelativePath: "li_1/1.mp3", hasResumeData: true)
        let record = DownloadRecordDTO(
            key: MediaKey(serverConnectionID: connectionID, libraryItemId: "li_1"), mediaType: .book,
            title: "The Book", state: .downloading, relativeDirectory: "li_1",
            media: LocalMediaSnapshot(metadata: .init(title: "The Book")), parts: [part])
        let saved = try await store.upsertRecord(record).record
        let blob = locations.resumeDataRoot.appending(path: "\(part.id.uuidString).bin")
        try Data("sealed".utf8).write(to: blob)
        return (saved.id, blob)
    }

    private func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
    }

    /// The expiry of a connection that isn't active ends no session, so only the account's
    /// expiry hook stops its downloads: paused, then their resume data deleted. The active
    /// connection's downloads keep running.
    @Test func anInactiveConnectionsExpiryPausesItsDownloadsAndDiscardsTheirResumeData() async throws {
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        let hosts = (0..<2).map { _ in "\(UUID().uuidString.lowercased()).connect-ui.test" }
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            downloads.cleanUp()
            hosts.forEach(ConnectTestProtocol.forget)
        }
        let environment = AppEnvironment(
            settings: AppSettings(defaults: defaults), storeLocation: .inMemory, keychain: keychain,
            sessionConfiguration: ConnectTestProtocol.configuration, downloadsRoot: downloads.root,
            makeDownloadSession: downloads.makeSession)
        let accounts = try #require(environment.accounts)
        try await #require(environment.downloads).lifecycle.launch().value
        let store = DownloadStore(modelContainer: try #require(environment.dataStack).container)
        let locations = DownloadLocations(root: downloads.root)
        let a = try await signIn(accounts, to: hosts[0])
        let aClient = try #require(accounts.client)
        let b = try await signIn(accounts, to: hosts[1])
        let downloadA = try await addDownloading(a, store: store, locations: locations)
        let downloadB = try await addDownloading(b, store: store, locations: locations)

        ConnectTestProtocol.revoke(hosts[0])
        await #expect(throws: APIError.sessionExpired) { try await aClient.send(AuthEndpoints.authorize()) }

        // The cleanup runs in its own task.
        var stateA = try await store.record(id: downloadA.record)?.state
        for _ in 0..<2_000 where stateA != .paused || exists(downloadA.blob) {
            try await Task.sleep(for: .milliseconds(5))
            stateA = try await store.record(id: downloadA.record)?.state
        }
        #expect(stateA == .paused)
        #expect(!exists(downloadA.blob))
        #expect(accounts.activeConnection?.id == b)
        #expect(try await store.record(id: downloadB.record)?.state == .downloading)
        #expect(exists(downloadB.blob))
    }
}
