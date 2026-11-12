import CoreData
import Foundation
import SwiftData
import Testing

@testable import ABSData

/// An unrelated schema from some other build, used to simulate a store this build can't read.
private enum UnrelatedSchema: VersionedSchema {
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

/// A plausible next version: SchemaV1 plus one optional attribute, used to simulate a downgrade.
private enum SupersetSchemaV2: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(2, 0, 0) }
    static var models: [any PersistentModel.Type] {
        [
            ServerConnectionRecord.self, SchemaV1.LocalLibraryItem.self, SchemaV1.LocalFile.self,
            SchemaV1.LocalMediaProgress.self, SchemaV1.DownloadRecord.self, SchemaV1.DownloadPart.self,
            SchemaV1.PendingLocalSession.self, SchemaV1.PlaybackHistoryEvent.self, SchemaV1.PendingSessionClose.self,
        ]
    }

    @Model final class ServerConnectionRecord {
        #Unique<ServerConnectionRecord>([\.id], [\.address, \.userId])
        #Index<ServerConnectionRecord>([\.lastUsedAt])

        var id: UUID
        var address: String
        var userId: String
        var username: String
        var authMethod: String
        var serverVersion: String?
        var createdAt: Date
        var lastUsedAt: Date?
        var isDisconnected: Bool
        var disconnectedAt: Date?
        var signedOutAt: Date?
        var nickname: String?

        init(id: UUID) {
            self.id = id
            address = "https://abs.example.com"
            userId = "usr_1"
            username = "reader"
            authMethod = "local"
            createdAt = Fixtures.date
            isDisconnected = false
            nickname = "Home"
        }
    }
}

@Suite struct DataStackTests {
    private let fileManager = FileManager.default

    private func exists(_ url: URL) -> Bool {
        fileManager.fileExists(atPath: url.path(percentEncoded: false))
    }

    /// The `Broken/Audiobookshelf.store/<epoch>-<uuid>/` directories next to a store.
    private func brokenCopies(in directory: URL) -> [URL] {
        let root = directory.appending(path: "Broken/Audiobookshelf.store")
        return (try? fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
    }

    /// Writes a store with `schema` (no migration plan), as another build would.
    private func writeStore(schema: Schema, at url: URL, insert: (ModelContext) -> Void) throws {
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)]
        )
        let context = ModelContext(container)
        insert(context)
        try context.save()
    }

    private func openURL(_ url: URL, allowsSave: Bool = true) throws -> DataStack {
        try DataStack(
            location: .url(url),
            allowsSave: allowsSave,
            groupContainerURL: { nil },
            fallbackDirectory: url.deletingLastPathComponent(),
            now: Date(timeIntervalSince1970: 1_900_000_000)
        )
    }

    // MARK: - Locations

    @Test func migrationPlanStartsAtV1() {
        #expect(ABSMigrationPlan.schemas.count == 1)
        #expect(ABSMigrationPlan.schemas.first == SchemaV1.self)
        #expect(ABSMigrationPlan.stages.isEmpty)
        #expect(SchemaV1.versionIdentifier == Schema.Version(1, 0, 0))
        #expect(SchemaV1.models.count == 9)
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
        defer { try? fileManager.removeItem(at: directory) }
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
        #expect(exists(url))

        let context = ModelContext(try DataStack(location: .url(url)).container)
        #expect(try context.fetch(FetchDescriptor<ServerConnectionRecord>()).map(\.id) == [id])
        #expect(try context.fetchCount(FetchDescriptor<PendingLocalSession>()) == 1)
        #expect(try context.fetchCount(FetchDescriptor<PlaybackHistoryEvent>()) == 1)
    }

    @Test func readOnlyStackDoesNotPersistWrites() throws {
        let directory = Fixtures.temporaryDirectory()
        defer { try? fileManager.removeItem(at: directory) }
        let url = directory.appending(path: "Audiobookshelf.store")
        do {
            let context = ModelContext(try DataStack(location: .url(url)).container)
            context.insert(Fixtures.connection())
            try context.save()
        }

        do {
            let reader = try DataStack(location: .url(url), allowsSave: false)
            #expect(reader.container.configurations.allSatisfy { !$0.allowsSave })
            let context = ModelContext(reader.container)
            #expect(try context.fetchCount(FetchDescriptor<ServerConnectionRecord>()) == 1)
            context.insert(Fixtures.connection(address: "https://other.example.com"))
            #expect(throws: (any Error).self) { try context.save() }
        }

        let context = ModelContext(try DataStack(location: .url(url)).container)
        #expect(try context.fetchCount(FetchDescriptor<ServerConnectionRecord>()) == 1)
    }

    // MARK: - App Group

    @Test func appGroupStoreLivesInGroupContainer() throws {
        let group = Fixtures.temporaryDirectory()
        let fallback = Fixtures.temporaryDirectory()
        defer {
            try? fileManager.removeItem(at: group)
            try? fileManager.removeItem(at: fallback)
        }
        var fallbacks = 0

        let stack = try DataStack(
            location: .appGroup,
            allowsSave: true,
            groupContainerURL: { group },
            fallbackDirectory: fallback,
            onFallback: { fallbacks += 1 }
        )
        let context = ModelContext(stack.container)
        context.insert(Fixtures.connection())
        try context.save()

        #expect(stack.resolvedLocation == .appGroup)
        #expect(exists(group.appending(path: "Library/Application Support/Audiobookshelf.store")))
        #expect(!exists(fallback))
        #expect(fallbacks == 0)
    }

    @Test func appGroupLoadFailureIsRethrownWithoutFallback() throws {
        let group = Fixtures.temporaryDirectory()
        let fallback = Fixtures.temporaryDirectory()
        defer {
            try? fileManager.removeItem(at: group)
            try? fileManager.removeItem(at: fallback)
        }
        // A regular file where the store's directory should be makes every load fail.
        try fileManager.createDirectory(at: group.appending(path: "Library"), withIntermediateDirectories: true)
        try Data().write(to: group.appending(path: "Library/Application Support"))
        var fallbacks = 0

        #expect(throws: (any Error).self) {
            _ = try DataStack(
                location: .appGroup,
                allowsSave: true,
                groupContainerURL: { group },
                fallbackDirectory: fallback,
                onFallback: { fallbacks += 1 }
            )
        }
        #expect(!exists(fallback))
        #expect(fallbacks == 0)
    }

    @Test func appGroupFallsBackOnlyWithoutEntitlement() throws {
        let directory = Fixtures.temporaryDirectory()
        defer { try? fileManager.removeItem(at: directory) }
        var fallbacks = 0

        let stack = try DataStack(
            location: .appGroup,
            allowsSave: true,
            isAppGroupEntitled: { false },
            groupContainerURL: { nil },
            fallbackDirectory: directory,
            onFallback: { fallbacks += 1 }
        )
        let expected = directory.appending(path: "Audiobookshelf.store")
        #expect(stack.resolvedLocation == .url(expected))
        #expect(fallbacks == 1)

        let context = ModelContext(stack.container)
        context.insert(Fixtures.connection())
        try context.save()
        #expect(exists(expected))
    }

    @Test func readOnlyAppGroupNeverFallsBack() throws {
        let directory = Fixtures.temporaryDirectory()
        defer { try? fileManager.removeItem(at: directory) }

        #expect(throws: DataStack.LoadError.appGroupUnavailable) {
            _ = try DataStack(
                location: .appGroup,
                allowsSave: false,
                isAppGroupEntitled: { false },
                groupContainerURL: { nil },
                fallbackDirectory: directory
            )
        }
        #expect(!exists(directory))
    }

    /// An entitled process whose container can't be resolved must not fall back and split the data.
    @Test(arguments: [true, false]) func entitledButUnresolvedGroupContainerThrows(allowsSave: Bool) throws {
        let directory = Fixtures.temporaryDirectory()
        defer { try? fileManager.removeItem(at: directory) }
        var fallbacks = 0

        #expect(throws: DataStack.LoadError.appGroupContainerUnresolved) {
            _ = try DataStack(
                location: .appGroup,
                allowsSave: allowsSave,
                isAppGroupEntitled: { true },
                groupContainerURL: { nil },
                fallbackDirectory: directory,
                onFallback: { fallbacks += 1 }
            )
        }
        #expect(fallbacks == 0)
        #expect(!exists(directory))
    }

    // MARK: - Recovery

    @Test func storeFromUnrelatedSchemaIsMovedAsideAndRecreated() throws {
        let directory = Fixtures.temporaryDirectory()
        defer { try? fileManager.removeItem(at: directory) }
        let url = directory.appending(path: "Audiobookshelf.store")
        let schema = Schema(versionedSchema: UnrelatedSchema.self)
        try writeStore(schema: schema, at: url) {
            $0.insert(UnrelatedSchema.ServerConnectionRecord(id: UUID(), nickname: "other"))
        }

        let context = ModelContext(try openURL(url).container)
        #expect(try context.fetchCount(FetchDescriptor<ServerConnectionRecord>()) == 0)
        context.insert(Fixtures.connection())
        try context.save()
        #expect(brokenCopies(in: directory).count == 1)
    }

    /// Pins how SwiftData treats a downgrade from a version that only added an optional attribute:
    /// no `backwardMigration` error; Core Data's inferred migration opens the store, drops the new
    /// column and keeps every row, so no recovery happens.
    @Test func downgradeFromAdditiveSchemaKeepsRows() throws {
        let directory = Fixtures.temporaryDirectory()
        defer { try? fileManager.removeItem(at: directory) }
        let url = directory.appending(path: "Audiobookshelf.store")
        let id = UUID()
        try writeStore(schema: Schema(versionedSchema: SupersetSchemaV2.self), at: url) {
            $0.insert(SupersetSchemaV2.ServerConnectionRecord(id: id))
            $0.insert(Fixtures.progress())
        }

        let context = ModelContext(try openURL(url).container)
        #expect(try context.fetch(FetchDescriptor<ServerConnectionRecord>()).map(\.id) == [id])
        #expect(try context.fetchCount(FetchDescriptor<LocalMediaProgress>()) == 1)
        #expect(brokenCopies(in: directory).isEmpty)
    }

    @Test func corruptStoreAndSideFilesAreMovedAsideKeepingNewestCopy() throws {
        let directory = Fixtures.temporaryDirectory()
        defer { try? fileManager.removeItem(at: directory) }
        let older = directory.appending(path: "Broken/Audiobookshelf.store/1-OLDER")
        try fileManager.createDirectory(at: older, withIntermediateDirectories: true)
        let url = directory.appending(path: "Audiobookshelf.store")
        let garbage = Data(repeating: 0x5A, count: 8192)
        for suffix in ["", "-wal", "-shm"] {
            try garbage.write(to: directory.appending(path: "Audiobookshelf.store\(suffix)"))
        }

        let context = ModelContext(try openURL(url).container)
        context.insert(Fixtures.connection())
        try context.save()

        let copies = brokenCopies(in: directory)
        #expect(copies.count == 1)
        let copy = try #require(copies.first)
        #expect(copy.lastPathComponent.hasPrefix("1900000000-"))
        for suffix in ["", "-wal", "-shm"] {
            #expect(try Data(contentsOf: copy.appending(path: "Audiobookshelf.store\(suffix)")) == garbage)
        }
        #expect(!exists(older))
    }

    @Test func readOnlyStackNeverRecovers() throws {
        let directory = Fixtures.temporaryDirectory()
        defer { try? fileManager.removeItem(at: directory) }
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "Audiobookshelf.store")
        try Data(repeating: 0x5A, count: 8192).write(to: url)

        #expect(throws: (any Error).self) { _ = try openURL(url, allowsSave: false) }
        #expect(exists(url))
        #expect(brokenCopies(in: directory).isEmpty)
    }

    @Test func unreadableStoreIsTreatedAsTransient() throws {
        let directory = Fixtures.temporaryDirectory()
        defer { try? fileManager.removeItem(at: directory) }
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "Audiobookshelf.store")
        try Data(repeating: 0x5A, count: 8192).write(to: url)
        // Stands in for a protected file while the device is locked.
        try fileManager.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path(percentEncoded: false))
        defer {
            try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path(percentEncoded: false))
        }

        #expect(DataStack.sqliteHeaderMatches(at: url) == nil)
        #expect(throws: (any Error).self) { _ = try openURL(url) }
        #expect(exists(url))
        #expect(brokenCopies(in: directory).isEmpty)
    }

    @Test func validV1StoreIsNotTreatedAsIncompatible() throws {
        let directory = Fixtures.temporaryDirectory()
        defer { try? fileManager.removeItem(at: directory) }
        let url = directory.appending(path: "Audiobookshelf.store")
        do {
            let context = ModelContext(try DataStack(location: .url(url)).container)
            context.insert(Fixtures.progress())
            try context.save()
        }

        #expect(DataStack.sqliteHeaderMatches(at: url) == true)
        #expect(DataStack.sqliteHeaderMatches(at: directory.appending(path: "Missing.store")) == nil)
    }

    @Test func onlyConfirmedNonTransientErrorsAreIncompatible() {
        func cocoa(_ code: Int, _ userInfo: [String: Any] = [:]) -> NSError {
            NSError(domain: NSCocoaErrorDomain, code: code, userInfo: userInfo)
        }
        let full = cocoa(134_110, [NSSQLiteErrorDomain: 13])
        #expect(!DataStack.isConfirmedIncompatibility(cocoa(134_110, [NSUnderlyingErrorKey: full])))
        #expect(!DataStack.isConfirmedIncompatibility(cocoa(134_110, [NSUnderlyingErrorKey: cocoa(640)])))
        #expect(!DataStack.isConfirmedIncompatibility(cocoa(134_100, [NSDetailedErrorsKey: [cocoa(513)]])))
        let ioError = NSError(domain: NSSQLiteErrorDomain, code: 10 | (3 << 8))  // SQLITE_IOERR_WRITE
        #expect(!DataStack.isConfirmedIncompatibility(cocoa(134_110, [NSUnderlyingErrorKey: ioError])))
        let posix = NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))
        #expect(!DataStack.isConfirmedIncompatibility(cocoa(134_110, [NSUnderlyingErrorKey: posix])))
        #expect(!DataStack.isConfirmedIncompatibility(cocoa(259)))
        for code in [7, 8, 264, 520, 776, 1032, 1288, 1544] {  // SQLITE_NOMEM, SQLITE_READONLY_*
            #expect(!DataStack.isConfirmedIncompatibility(cocoa(134_110, [NSSQLiteErrorDomain: code])))
        }
        // Timeouts, busy/locked (incl. extended codes), I/O, full, protocol, can't open, auth.
        for code in [5, 261, 517, 6, 262, 10, 13, 14, 15, 23] {
            let sqlite = NSError(domain: NSSQLiteErrorDomain, code: code)
            #expect(!DataStack.isConfirmedIncompatibility(cocoa(134_110, [NSUnderlyingErrorKey: sqlite])))
            #expect(!DataStack.isConfirmedIncompatibility(cocoa(134_100, [NSSQLiteErrorDomain: code])))
        }
        // NSPersistentStoreTimeoutError, NSPersistentStoreSaveConflictsError, NSFileReadUnknownError.
        for code in [NSPersistentStoreTimeoutError, NSPersistentStoreSaveConflictsError, NSFileReadUnknownError] {
            #expect(!DataStack.isConfirmedIncompatibility(cocoa(code)))
            #expect(!DataStack.isConfirmedIncompatibility(cocoa(134_110, [NSUnderlyingErrorKey: cocoa(code)])))
            #expect(!DataStack.isConfirmedIncompatibility(cocoa(134_100, [NSDetailedErrorsKey: [cocoa(code)]])))
        }
        for code in [EINTR, EAGAIN, EBUSY] {
            let posix = NSError(domain: NSPOSIXErrorDomain, code: Int(code))
            #expect(!DataStack.isConfirmedIncompatibility(cocoa(134_110, [NSUnderlyingErrorKey: posix])))
        }
        #expect(!DataStack.isConfirmedIncompatibility(cocoa(134_110, [NSUnderlyingErrorKey: cocoa(259)])))
        #expect(!DataStack.isConfirmedIncompatibility(nil))

        #expect(DataStack.isConfirmedIncompatibility(cocoa(134_110, [NSUnderlyingErrorKey: cocoa(134_110)])))
        #expect(DataStack.isConfirmedIncompatibility(cocoa(134_100)))
        #expect(
            DataStack.isConfirmedIncompatibility(
                cocoa(134_110, [NSDetailedErrorsKey: [cocoa(134_130), cocoa(134_140)]])))
        #expect(DataStack.isConfirmedIncompatibility(cocoa(259, [NSSQLiteErrorDomain: 26])))
        #expect(
            DataStack.isConfirmedIncompatibility(
                cocoa(259, [NSUnderlyingErrorKey: cocoa(1, [NSSQLiteErrorDomain: 11])])))
    }

    @Test func errorChainBeyondInspectionLimitIsNeverConfirmed() {
        /// A linear chain of `count` migration errors whose innermost error is `innermost`.
        func chain(count: Int, innermost: NSError) -> NSError {
            (1..<count).reduce(innermost) { inner, _ in
                NSError(domain: NSCocoaErrorDomain, code: 134_110, userInfo: [NSUnderlyingErrorKey: inner])
            }
        }
        let migration = NSError(domain: NSCocoaErrorDomain, code: 134_110)
        let full = NSError(domain: NSCocoaErrorDomain, code: 134_110, userInfo: [NSSQLiteErrorDomain: 13])
        let limit = DataStack.maxInspectedErrors

        #expect(DataStack.isConfirmedIncompatibility(chain(count: limit, innermost: migration)))
        #expect(!DataStack.isConfirmedIncompatibility(chain(count: limit, innermost: full)))
        #expect(!DataStack.isConfirmedIncompatibility(chain(count: limit + 1, innermost: full)))
        #expect(!DataStack.isConfirmedIncompatibility(chain(count: limit + 1, innermost: migration)))
    }

    /// A crash after the main store moved leaves the marker and the side files; the next open
    /// finishes the move before creating a fresh store.
    @Test func interruptedMoveAsideIsCompletedBeforeOpening() throws {
        let directory = Fixtures.temporaryDirectory()
        defer { try? fileManager.removeItem(at: directory) }
        let url = directory.appending(path: "Audiobookshelf.store")
        let other = directory.appending(path: "Other.store")
        for store in [url, other] {
            let context = ModelContext(try DataStack(location: .url(store)).container)
            context.insert(Fixtures.connection())
            try context.save()
        }
        let older = directory.appending(path: "Broken/Audiobookshelf.store/1-OLDER")
        try fileManager.createDirectory(at: older, withIntermediateDirectories: true)
        let copy = directory.appending(path: "Broken/Audiobookshelf.store/5-CRASHED")
        try fileManager.createDirectory(at: copy, withIntermediateDirectories: true)
        let names = ["Audiobookshelf.store", "Audiobookshelf.store-wal", "Audiobookshelf.store-shm"]
        // An undecodable marker still resumes: its contents are never trusted.
        try Data([0xFF, 0xFE, 0x00]).write(to: copy.appending(path: DataStack.incompleteMarker))
        try fileManager.moveItem(at: url, to: copy.appending(path: names[0]))
        for name in names.dropFirst() where !exists(directory.appending(path: name)) {
            try Data("stale".utf8).write(to: directory.appending(path: name))
        }

        // Another store in the same directory opens intact and leaves this store's archive alone.
        let otherContext = ModelContext(try openURL(other).container)
        #expect(try otherContext.fetchCount(FetchDescriptor<ServerConnectionRecord>()) == 1)
        #expect(exists(copy.appending(path: DataStack.incompleteMarker)))
        #expect(exists(older))
        for name in names.dropFirst() {
            #expect(exists(directory.appending(path: name)))
        }

        let context = ModelContext(try openURL(url).container)
        #expect(try context.fetchCount(FetchDescriptor<ServerConnectionRecord>()) == 0)
        #expect(!exists(copy.appending(path: DataStack.incompleteMarker)))
        for name in names {
            #expect(exists(copy.appending(path: name)))
        }
        #expect(!exists(older))  // Retention applies after a resumed move too.
    }

    /// An unreadable `Broken/` might hide an interrupted move, so the store isn't opened.
    @Test func unreadableBrokenDirectoryPreventsOpening() throws {
        let directory = Fixtures.temporaryDirectory()
        defer { try? fileManager.removeItem(at: directory) }
        let broken = directory.appending(path: "Broken")
        try fileManager.createDirectory(at: broken, withIntermediateDirectories: true)
        try fileManager.setAttributes([.posixPermissions: 0o000], ofItemAtPath: broken.path(percentEncoded: false))
        defer {
            try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: broken.path(percentEncoded: false))
        }

        let url = directory.appending(path: "Audiobookshelf.store")
        #expect(throws: (any Error).self) { _ = try openURL(url) }
        #expect(!exists(url))
    }

    @Test func pruningIsSkippedWhileAnyCopyIsIncomplete() throws {
        let directory = Fixtures.temporaryDirectory()
        defer { try? fileManager.removeItem(at: directory) }
        let marked = directory.appending(path: "Broken/Audiobookshelf.store/1-MARKED")
        let unmarked = directory.appending(path: "Broken/Audiobookshelf.store/2-DONE")
        try fileManager.createDirectory(at: marked, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: unmarked, withIntermediateDirectories: true)
        try Data("Other.store".utf8).write(to: marked.appending(path: DataStack.incompleteMarker))
        let url = directory.appending(path: "Audiobookshelf.store")
        try Data(repeating: 0x5A, count: 64).write(to: url)

        try DataStack.moveStoreAside(at: url, now: Date(timeIntervalSince1970: 3))
        #expect(exists(marked.appending(path: DataStack.incompleteMarker)))
        #expect(exists(unmarked))
        #expect(brokenCopies(in: directory).count == 3)
        #expect(!exists(url))
    }

    /// A marker that can't be checked (no permission, I/O, locked) might hide a split store, so
    /// nothing is opened, moved or pruned.
    @Test func inaccessibleMarkerPreventsOpeningAndPruning() throws {
        let directory = Fixtures.temporaryDirectory()
        defer { try? fileManager.removeItem(at: directory) }
        let older = directory.appending(path: "Broken/Audiobookshelf.store/1-OLDER")
        let locked = directory.appending(path: "Broken/Audiobookshelf.store/5-LOCKED")
        try fileManager.createDirectory(at: older, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: locked, withIntermediateDirectories: true)
        try Data().write(to: locked.appending(path: DataStack.incompleteMarker))
        let wal = directory.appending(path: "Audiobookshelf.store-wal")
        try Data("stale".utf8).write(to: wal)
        let lockedPath = locked.path(percentEncoded: false)
        try fileManager.setAttributes([.posixPermissions: 0o000], ofItemAtPath: lockedPath)
        defer { try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: lockedPath) }

        #expect(throws: (any Error).self) { _ = try DataStack.itemExists(at: locked.appending(path: "INCOMPLETE")) }
        #expect(throws: (any Error).self) { _ = try openURL(directory.appending(path: "Audiobookshelf.store")) }
        #expect(!exists(directory.appending(path: "Audiobookshelf.store")))
        #expect(exists(wal))
        #expect(exists(older))
        #expect(try !DataStack.itemExists(at: directory.appending(path: "Missing")))
        #expect(try DataStack.itemExists(at: wal))
    }
}
