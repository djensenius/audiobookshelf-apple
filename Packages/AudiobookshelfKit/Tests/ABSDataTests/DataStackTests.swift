import Foundation
import SwiftData
import Testing

@testable import ABSData

/// A schema from a newer build, used to simulate a downgrade.
private enum FutureSchema: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(99, 0, 0) }
    static var models: [any PersistentModel.Type] { [ServerConnectionRecord.self] }

    @Model final class ServerConnectionRecord {
        var id: UUID
        var nickname: String

        init(id: UUID, nickname: String) {
            self.id = id
            self.nickname = nickname
        }
    }
}

@Suite struct DataStackTests {
    @Test func migrationPlanStartsAtV1() {
        #expect(ABSMigrationPlan.schemas.count == 1)
        #expect(ABSMigrationPlan.schemas.first == SchemaV1.self)
        #expect(ABSMigrationPlan.stages.isEmpty)
        #expect(SchemaV1.versionIdentifier == Schema.Version(1, 0, 0))
        #expect(SchemaV1.models.count == 8)
    }

    @Test func opensInMemoryStore() throws {
        let stack = try DataStack(location: .inMemory)
        #expect(stack.resolvedLocation == .inMemory)
        #expect(stack.container.configurations.allSatisfy { $0.isStoredInMemoryOnly })
        #expect(stack.container.schema.entities.count == SchemaV1.models.count)

        let context = ModelContext(stack.container)
        context.insert(Fixtures.connection())
        try context.save()
        #expect(try context.fetchCount(FetchDescriptor<ServerConnectionRecord>()) == 1)

        // Each in-memory stack is independent.
        let other = ModelContext(try DataStack(location: .inMemory).container)
        #expect(try other.fetchCount(FetchDescriptor<ServerConnectionRecord>()) == 0)
    }

    @Test func opensAndReopensV1StoreOnDisk() throws {
        let directory = Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "nested/Audiobookshelf.store")
        let id = UUID()

        do {
            let stack = try DataStack(location: .url(url))
            #expect(stack.resolvedLocation == .url(url))
            #expect(stack.container.configurations.map(\.url) == [url])
            let context = ModelContext(stack.container)
            context.insert(Fixtures.connection(id: id))
            context.insert(Fixtures.session(id: "session-1"))
            context.insert(Fixtures.historyEvent())
            try context.save()
        }
        #expect(FileManager.default.fileExists(atPath: url.path(percentEncoded: false)))

        let context = ModelContext(try DataStack(location: .url(url)).container)
        #expect(try context.fetch(FetchDescriptor<ServerConnectionRecord>()).map(\.id) == [id])
        #expect(try context.fetchCount(FetchDescriptor<PendingLocalSession>()) == 1)
        #expect(try context.fetchCount(FetchDescriptor<PlaybackHistoryEvent>()) == 1)
    }

    @Test func readOnlyStackCannotSave() throws {
        let directory = Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "Audiobookshelf.store")
        do {
            let context = ModelContext(try DataStack(location: .url(url)).container)
            context.insert(Fixtures.connection())
            try context.save()
        }

        let reader = try DataStack(location: .url(url), allowsSave: false)
        #expect(reader.container.configurations.allSatisfy { !$0.allowsSave })
        let context = ModelContext(reader.container)
        #expect(try context.fetchCount(FetchDescriptor<ServerConnectionRecord>()) == 1)
    }

    @Test func appGroupFallsBackWhenGroupContainerIsUnavailable() throws {
        let directory = Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let stack = try DataStack(
            location: .appGroup,
            allowsSave: true,
            groupContainerURL: { nil },
            fallbackDirectory: directory
        )
        let expected = directory.appending(path: "Audiobookshelf.store")
        #expect(stack.resolvedLocation == .url(expected))

        let context = ModelContext(stack.container)
        context.insert(Fixtures.connection())
        try context.save()
        #expect(FileManager.default.fileExists(atPath: expected.path(percentEncoded: false)))
    }

    @Test func storeFromNewerSchemaIsMovedAsideAndRecreated() throws {
        let directory = Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "Audiobookshelf.store")

        do {
            let schema = Schema(versionedSchema: FutureSchema.self)
            let container = try ModelContainer(
                for: schema,
                configurations: [ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)]
            )
            let context = ModelContext(container)
            context.insert(FutureSchema.ServerConnectionRecord(id: UUID(), nickname: "future"))
            try context.save()
        }

        let now = Date(timeIntervalSince1970: 1_900_000_000)
        let stack = try DataStack(
            location: .url(url),
            allowsSave: true,
            groupContainerURL: { nil },
            fallbackDirectory: directory,
            now: now
        )
        let context = ModelContext(stack.container)
        #expect(try context.fetchCount(FetchDescriptor<ServerConnectionRecord>()) == 0)
        context.insert(Fixtures.connection())
        try context.save()

        let movedAside = directory.appending(path: "Audiobookshelf.store.broken-1900000000")
        #expect(FileManager.default.fileExists(atPath: movedAside.path(percentEncoded: false)))
    }

    @Test func corruptStoreIsMovedAsideAndRecreated() throws {
        let directory = Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "Audiobookshelf.store")
        try Data(repeating: 0x5A, count: 8192).write(to: url)

        let stack = try DataStack(
            location: .url(url),
            allowsSave: true,
            groupContainerURL: { nil },
            fallbackDirectory: directory,
            now: Date(timeIntervalSince1970: 1_900_000_000)
        )
        let context = ModelContext(stack.container)
        context.insert(Fixtures.connection())
        try context.save()

        let movedAside = directory.appending(path: "Audiobookshelf.store.broken-1900000000")
        #expect(try Data(contentsOf: movedAside) == Data(repeating: 0x5A, count: 8192))
    }

    @Test func validV1StoreIsNotTreatedAsIncompatible() throws {
        let directory = Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "Audiobookshelf.store")
        do {
            let context = ModelContext(try DataStack(location: .url(url)).container)
            context.insert(Fixtures.progress())
            try context.save()
        }

        #expect(!DataStack.isIncompatibleStore(at: url))
        #expect(!DataStack.isIncompatibleStore(at: directory.appending(path: "Missing.store")))
    }
}
