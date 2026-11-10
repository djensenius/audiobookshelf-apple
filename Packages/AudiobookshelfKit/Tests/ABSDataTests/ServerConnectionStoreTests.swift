import ABSCore
import Foundation
import SwiftData
import Testing

@testable import ABSData

@Suite struct ServerConnectionStoreTests {
    private let address = ServerAddress("https://abs.example.com/sub/")!
    private let now = Fixtures.date

    private func makeStore() throws -> (ServerConnectionStore, ModelContainer) {
        let container = try DataStack(location: .inMemory).container
        return (ServerConnectionStore(modelContainer: container), container)
    }

    @discardableResult
    private func login(
        _ store: ServerConnectionStore,
        userId: String = "usr_1",
        username: String = "reader",
        at date: Date? = nil
    ) async throws -> ServerConnectionDTO {
        try await store.upsertLogin(
            address: address,
            userId: userId,
            username: username,
            authMethod: .local,
            serverVersion: "2.26.0",
            now: date ?? now
        )
    }

    @Test func loginCreatesConnectionWithNormalizedAddress() async throws {
        let (store, _) = try makeStore()
        let created = try await login(store)
        #expect(created.address == "https://abs.example.com/sub")
        #expect(created.createdAt == now)
        #expect(created.lastUsedAt == now)
        #expect(created.authMethod == .local)
        #expect(try await store.connection(id: created.id) == created)
        #expect(try await store.connection(address: address, userId: "usr_1") == created)
    }

    @Test func repeatedLoginKeepsIDAndUpdatesInPlace() async throws {
        let (store, _) = try makeStore()
        let first = try await login(store)
        let later = now.addingTimeInterval(60)
        let second = try await store.upsertLogin(
            address: address, userId: "usr_1", username: "renamed", authMethod: .openid, serverVersion: "2.27.0",
            now: later)
        #expect(second.id == first.id)
        #expect(second.createdAt == first.createdAt)
        #expect(second.username == "renamed")
        #expect(second.authMethod == .openid)
        #expect(second.serverVersion == "2.27.0")
        #expect(second.lastUsedAt == later)
        #expect(try await store.allConnections().count == 1)
    }

    @Test func otherUsersGetSeparateConnections() async throws {
        let (store, _) = try makeStore()
        let first = try await login(store, userId: "usr_1", at: now)
        let second = try await login(store, userId: "usr_2", at: now.addingTimeInterval(10))
        #expect(first.id != second.id)
        #expect(try await store.allConnections().map(\.id) == [second.id, first.id])
    }

    @Test func connectionToRestoreIsLatestConnected() async throws {
        let (store, container) = try makeStore()
        let older = try await login(store, userId: "usr_1", at: now)
        let newer = try await login(store, userId: "usr_2", at: now.addingTimeInterval(10))
        #expect(try await store.connectionToRestore()?.id == newer.id)

        try await store.markUsed(id: older.id, at: now.addingTimeInterval(20))
        #expect(try await store.connectionToRestore()?.id == older.id)

        // A disconnected connection is never restored.
        let context = ModelContext(container)
        RetainedRecord.download.insert(connectionID: older.id, into: context)
        try context.save()
        #expect(try await store.remove(id: older.id) == .disconnected)
        #expect(try await store.connectionToRestore()?.id == newer.id)
    }

    @Test func updatesServerVersion() async throws {
        let (store, _) = try makeStore()
        let created = try await login(store)
        #expect(try await store.updateServerVersion(id: created.id, "2.30.0"))
        #expect(try await store.connection(id: created.id)?.serverVersion == "2.30.0")
        #expect(try await store.updateServerVersion(id: UUID(), "1") == false)
        #expect(try await store.markUsed(id: UUID()) == false)
    }

    @Test func removeWithoutRetainedRecordsDeletes() async throws {
        let (store, container) = try makeStore()
        let created = try await login(store)
        // History alone doesn't retain a connection, and synced progress doesn't either.
        let context = ModelContext(container)
        let history = Fixtures.historyEvent()
        history.serverConnectionID = created.id
        context.insert(history)
        let synced = Fixtures.progress(key: MediaKey(serverConnectionID: created.id, libraryItemId: "li_1").rawValue)
        synced.serverConnectionID = created.id
        context.insert(synced)
        try context.save()

        #expect(try await store.remove(id: created.id) == .deleted)
        #expect(try await store.connection(id: created.id) == nil)
        #expect(try await store.remove(id: created.id) == .notFound)
        // History rows keep the deleted connection's id for display.
        let events = try ModelContext(container).fetch(FetchDescriptor<PlaybackHistoryEvent>())
        #expect(events.map(\.id) == [history.id])
        #expect(events.map(\.serverConnectionID) == [created.id])
    }

    @Test func failedSaveIsRolledBackAndNotCommittedLater() async throws {
        let (store, _) = try makeStore()
        let created = try await login(store)
        await store.failNextCommit(with: CocoaError(.fileWriteNoPermission))
        await #expect(throws: CocoaError.self) { try await store.remove(id: created.id) }
        #expect(await store.hasUncommittedChanges == false)

        // A later, unrelated save doesn't commit the failed deletion.
        #expect(try await store.updateServerVersion(id: created.id, "2.30.0"))
        let other = ServerConnectionStore(modelContainer: store.modelContainer)
        #expect(try await other.connection(id: created.id)?.serverVersion == "2.30.0")
    }

    @Test(arguments: RetainedRecord.allCases)
    func removeWithRetainedRecordsDisconnectsAndLoginReusesID(_ retained: RetainedRecord) async throws {
        let (store, container) = try makeStore()
        let created = try await login(store)
        let context = ModelContext(container)
        retained.insert(connectionID: created.id, into: context)
        try context.save()

        let removedAt = now.addingTimeInterval(30)
        #expect(try await store.remove(id: created.id, now: removedAt) == .disconnected)
        let disconnected = try #require(try await store.connection(id: created.id))
        #expect(disconnected.isDisconnected)
        #expect(disconnected.disconnectedAt == removedAt)
        #expect(try await store.connectionToRestore() == nil)

        let again = try await login(store, at: now.addingTimeInterval(60))
        #expect(again.id == created.id)
        #expect(again.isDisconnected == false)
        #expect(again.disconnectedAt == nil)
        #expect(try await store.allConnections().count == 1)
    }

    enum RetainedRecord: CaseIterable, Sendable {
        case dirtyProgress, pendingSession, download, localItem

        func insert(connectionID: UUID, into context: ModelContext) {
            switch self {
            case .dirtyProgress:
                let progress = Fixtures.progress(
                    key: MediaKey(serverConnectionID: connectionID, libraryItemId: "li_1").rawValue)
                progress.serverConnectionID = connectionID
                progress.audioDirty = true
                progress.needsServerSync = true
                context.insert(progress)
            case .pendingSession:
                let session = Fixtures.session()
                session.serverConnectionID = connectionID
                context.insert(session)
            case .download:
                let record = Fixtures.download(
                    key: MediaKey(serverConnectionID: connectionID, libraryItemId: "li_2").rawValue)
                record.serverConnectionID = connectionID
                context.insert(record)
            case .localItem:
                let item = Fixtures.item()
                item.serverConnectionID = connectionID
                context.insert(item)
            }
        }
    }
}
