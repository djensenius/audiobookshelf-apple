import CoreData
import Foundation
import OSLog
import SwiftData

/// Builds the process's one `ModelContainer` for the on-device store (ADR 0003).
///
/// `ModelContainer` is `Sendable`, so the stack can be shared; `ModelContext`s are created by
/// the store actors that own them and never cross isolation boundaries.
public struct DataStack: Sendable {
    /// Where the store lives.
    public enum Location: Sendable, Hashable {
        /// Production: `<group container>/Library/Application Support/Audiobookshelf.store`.
        case appGroup
        /// An on-disk store at a specific file URL (tests).
        case url(URL)
        /// A store that is never written to disk (unit tests and previews).
        case inMemory
    }

    public static let appGroupIdentifier = "group.org.davidjensenius.Audiobookshelf"
    public static let storeName = "Audiobookshelf"

    public let container: ModelContainer
    /// Where the store was opened: `location`, or `.url` in the app container when the App Group
    /// container is unavailable (for example an unsigned test host).
    public let resolvedLocation: Location

    /// The schema of the current version.
    public static var schema: Schema { Schema(versionedSchema: CurrentSchema.self) }

    /// Opens the store at `location`. Widgets pass `allowsSave: false`; only the app writes.
    public init(location: Location, allowsSave: Bool = true) throws {
        try self.init(
            location: location,
            allowsSave: allowsSave,
            groupContainerURL: {
                FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: Self.appGroupIdentifier)
            },
            fallbackDirectory: URL.applicationSupportDirectory
        )
    }

    /// - Parameters:
    ///   - groupContainerURL: Resolves the App Group container; `nil` means it is unavailable.
    ///   - fallbackDirectory: Where the store goes when the App Group can't be used.
    init(
        location: Location,
        allowsSave: Bool,
        groupContainerURL: () -> URL?,
        fallbackDirectory: URL,
        now: Date = .now
    ) throws {
        let schema = Self.schema
        let fallbackURL = fallbackDirectory.appending(path: "\(Self.storeName).store")
        switch location {
        case .inMemory:
            let configuration = ModelConfiguration(
                Self.storeName,
                schema: schema,
                isStoredInMemoryOnly: true,
                allowsSave: allowsSave,
                groupContainer: .none,
                cloudKitDatabase: .none
            )
            container = try Self.makeContainer(schema: schema, configuration: configuration)
            resolvedLocation = .inMemory
        case .url(let url):
            container = try Self.openOnDisk(at: url, schema: schema, allowsSave: allowsSave, now: now)
            resolvedLocation = .url(url)
        case .appGroup:
            guard let groupURL = groupContainerURL() else {
                Self.logger.error("App Group container unavailable; using the app container store")
                container = try Self.openOnDisk(at: fallbackURL, schema: schema, allowsSave: allowsSave, now: now)
                resolvedLocation = .url(fallbackURL)
                return
            }
            Self.prepareDirectory(groupURL.appending(path: "Library/Application Support", directoryHint: .isDirectory))
            let configuration = ModelConfiguration(
                Self.storeName,
                schema: schema,
                allowsSave: allowsSave,
                groupContainer: .identifier(Self.appGroupIdentifier),
                cloudKitDatabase: .none
            )
            do {
                container = try Self.openRecovering(configuration: configuration, schema: schema, now: now)
                resolvedLocation = .appGroup
            } catch let error as SwiftDataError where error == .loadIssueModelContainer {
                // An unsigned host resolves the group path but can't open it.
                Self.logger.error("App Group store failed to load; using the app container store")
                container = try Self.openOnDisk(at: fallbackURL, schema: schema, allowsSave: allowsSave, now: now)
                resolvedLocation = .url(fallbackURL)
            }
        }
    }

    private static let logger = Logger(subsystem: "org.davidjensenius.Audiobookshelf", category: "persistence")

    private static func makeContainer(schema: Schema, configuration: ModelConfiguration) throws -> ModelContainer {
        try ModelContainer(for: schema, migrationPlan: ABSMigrationPlan.self, configurations: [configuration])
    }

    private static func openOnDisk(at url: URL, schema: Schema, allowsSave: Bool, now: Date) throws -> ModelContainer {
        prepareDirectory(url.deletingLastPathComponent())
        let configuration = ModelConfiguration(
            storeName,
            schema: schema,
            url: url,
            allowsSave: allowsSave,
            cloudKitDatabase: .none
        )
        return try openRecovering(configuration: configuration, schema: schema, now: now)
    }

    /// Opens the store; when it was written by a newer or unknown schema (a downgrade or a
    /// corrupt store), moves its files aside and creates an empty store. The server still holds
    /// synced progress, and unreferenced downloads are removed by the orphan sweep.
    private static func openRecovering(
        configuration: ModelConfiguration,
        schema: Schema,
        now: Date
    ) throws -> ModelContainer {
        do {
            return try makeContainer(schema: schema, configuration: configuration)
        } catch let error as SwiftDataError {
            guard
                incompatibleStoreErrors.contains(error)
                    || (error == .loadIssueModelContainer && isIncompatibleStore(at: configuration.url))
            else { throw error }
            logger.fault("Store is incompatible (\(String(describing: error), privacy: .public)); moving it aside")
            try moveStoreAside(at: configuration.url, now: now)
            return try makeContainer(schema: schema, configuration: configuration)
        }
    }

    private static let incompatibleStoreErrors: Set<SwiftDataError> = [
        .backwardMigration, .unknownSchema, .unknownDataStoreSchema,
    ]

    /// Whether the store at `url` is corrupt or was written by a schema missing from
    /// ``ABSMigrationPlan``. SwiftData reports both as `loadIssueModelContainer`, which also
    /// covers transient failures (for example a protected file before first unlock), so only
    /// these two cases are treated as incompatible.
    static func isIncompatibleStore(at url: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else { return false }
        let metadata: [String: Any]
        do {
            metadata = try NSPersistentStoreCoordinator.metadataForPersistentStore(type: .sqlite, at: url)
        } catch let error as CocoaError where error.code == .fileReadCorruptFile {
            return true
        } catch {
            return false
        }
        return !ABSMigrationPlan.schemas.contains { version in
            let model = NSManagedObjectModel.makeManagedObjectModel(for: Schema(versionedSchema: version))
            return model?.isConfiguration(withName: nil, compatibleWithStoreMetadata: metadata) ?? true
        }
    }

    /// Renames the store and its SQLite side files with a timestamp suffix.
    static func moveStoreAside(at url: URL, now: Date) throws {
        let fileManager = FileManager.default
        let suffix = "broken-\(Int(now.timeIntervalSince1970))"
        let directory = url.deletingLastPathComponent()
        let name = url.lastPathComponent
        for fileName in [name, "\(name)-shm", "\(name)-wal"] {
            let source = directory.appending(path: fileName)
            guard fileManager.fileExists(atPath: source.path(percentEncoded: false)) else { continue }
            try fileManager.moveItem(at: source, to: directory.appending(path: "\(fileName).\(suffix)"))
        }
    }

    /// Creates the store directory. On iOS the directory gets
    /// `completeUntilFirstUserAuthentication` protection, so new store files inherit a class
    /// that background playback, downloads and widgets can still open while the device is locked.
    private static func prepareDirectory(_ directory: URL) {
        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            #if os(iOS)
                try fileManager.setAttributes(
                    [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                    ofItemAtPath: directory.path(percentEncoded: false)
                )
            #endif
        } catch {
            logger.error("Couldn't prepare the store directory: \(String(describing: error), privacy: .public)")
        }
    }
}
