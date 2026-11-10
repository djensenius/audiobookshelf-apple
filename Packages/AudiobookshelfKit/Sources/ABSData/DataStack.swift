import ABSCore
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

    public enum LoadError: Error, Equatable {
        /// A read-only process (a widget) can't use the App Group container, so there is no
        /// store it could share with the app.
        case appGroupUnavailable
    }

    public static let storeName = "Audiobookshelf"

    public let container: ModelContainer
    /// Where the store was opened: `location`, or `.url` in the app container when the process has
    /// no App Group entitlement (for example the ad hoc signed macOS test host).
    public let resolvedLocation: Location

    /// The schema of the current version.
    public static var schema: Schema { Schema(versionedSchema: CurrentSchema.self) }

    /// Opens the store at `location`. Widgets pass `allowsSave: false`; only the app writes, and
    /// only a writing process ever recovers (moves aside) an incompatible store.
    public init(location: Location, allowsSave: Bool = true) throws {
        try self.init(
            location: location,
            allowsSave: allowsSave,
            groupContainerURL: Self.entitledGroupContainerURL,
            fallbackDirectory: URL.applicationSupportDirectory,
            onFallback: Self.reportFallback
        )
    }

    /// - Parameters:
    ///   - groupContainerURL: The App Group container, or `nil` when the process isn't entitled.
    ///   - fallbackDirectory: Where the store goes when the process isn't entitled.
    ///   - onFallback: Called when the App Group store is replaced by the fallback store.
    init(
        location: Location,
        allowsSave: Bool,
        groupContainerURL: () -> URL?,
        fallbackDirectory: URL,
        now: Date = .now,
        onFallback: () -> Void = {}
    ) throws {
        let schema = Self.schema
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
            if let groupURL = groupContainerURL() {
                // Load failures are rethrown, never answered with a private store: a store that is
                // locked, full or briefly unreadable would otherwise be split in two, and the
                // orphan sweep could delete downloads the private store doesn't know about.
                let url = groupURL.appending(path: "Library/Application Support/\(Self.storeName).store")
                container = try Self.openOnDisk(at: url, schema: schema, allowsSave: allowsSave, now: now)
                resolvedLocation = .appGroup
            } else {
                guard allowsSave else {
                    Self.logger.error("App Group container unavailable; a read-only store can't fall back")
                    throw LoadError.appGroupUnavailable
                }
                Self.logger.fault("App Group container unavailable (missing entitlement); using the app container")
                onFallback()
                let url = fallbackDirectory.appending(path: "\(Self.storeName).store")
                container = try Self.openOnDisk(at: url, schema: schema, allowsSave: allowsSave, now: now)
                resolvedLocation = .url(url)
            }
        }
    }

    private static let logger = Logger(subsystem: "org.davidjensenius.Audiobookshelf", category: "persistence")

    /// The App Group container when this process is entitled to it.
    private static func entitledGroupContainerURL() -> URL? {
        let identifier = AppSettings.appGroupIdentifier
        guard AppSettings.isAppGroupAvailable(identifier) else { return nil }
        return FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier)
    }

    /// A missing App Group entitlement is a build configuration error everywhere except the
    /// ad hoc signed macOS app test host (`mise run test:app`), which has no App Group.
    private static func reportFallback() {
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil {
            assertionFailure("App Group container unavailable; check the App Group entitlement")
        }
    }

    private static func makeContainer(schema: Schema, configuration: ModelConfiguration) throws -> ModelContainer {
        try ModelContainer(for: schema, migrationPlan: ABSMigrationPlan.self, configurations: [configuration])
    }

    private static func openOnDisk(at url: URL, schema: Schema, allowsSave: Bool, now: Date) throws -> ModelContainer {
        if allowsSave {
            prepareDirectory(url.deletingLastPathComponent())
        }
        let configuration = ModelConfiguration(
            storeName,
            schema: schema,
            url: url,
            allowsSave: allowsSave,
            cloudKitDatabase: .none
        )
        do {
            return try makeContainer(schema: schema, configuration: configuration)
        } catch let error as SwiftDataError {
            guard allowsSave, isIncompatible(error, storeURL: url) else { throw error }
            // A downgrade or a corrupt store: start empty. The server still holds synced progress,
            // and the orphan sweep removes downloads that are no longer referenced.
            logger.fault("Store is incompatible (\(String(describing: error), privacy: .public)); moving it aside")
            try moveStoreAside(at: url, now: now)
            return try makeContainer(schema: schema, configuration: configuration)
        }
    }

    private static func isIncompatible(_ error: SwiftDataError, storeURL: URL) -> Bool {
        if [.backwardMigration, .unknownSchema, .unknownDataStoreSchema].contains(error) { return true }
        return error == .loadIssueModelContainer && isIncompatibleStore(at: storeURL)
    }

    private static let sqliteHeader = Data("SQLite format 3\u{0}".utf8)

    /// Whether the store at `url` is corrupt, or was written by a schema missing from
    /// ``ABSMigrationPlan`` (a downgrade). SwiftData reports both as `loadIssueModelContainer`,
    /// which also covers transient failures, so anything else counts as compatible:
    /// - a file that can't be read, including one whose data protection keeps it unreadable
    ///   while the device is locked (a package can't ask `UIApplication` whether protected data
    ///   is available, so reading the header is the check);
    /// - a metadata error other than `SQLITE_CORRUPT` (11) or `SQLITE_NOTADB` (26).
    static func isIncompatibleStore(at url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let header = try? handle.read(upToCount: sqliteHeader.count) else { return false }
        guard header == sqliteHeader else { return true }

        let metadata: [String: Any]
        do {
            metadata = try NSPersistentStoreCoordinator.metadataForPersistentStore(type: .sqlite, at: url)
        } catch {
            let sqliteCode = (error as NSError).userInfo[NSSQLiteErrorDomain] as? Int
            return sqliteCode == 11 || sqliteCode == 26
        }
        return !ABSMigrationPlan.schemas.contains { version in
            let model = NSManagedObjectModel.makeManagedObjectModel(for: Schema(versionedSchema: version))
            return model?.isConfiguration(withName: nil, compatibleWithStoreMetadata: metadata) ?? true
        }
    }

    /// Moves the store and its SQLite side files into `Broken/<epoch>-<uuid>/` next to it, side
    /// files first, and deletes older broken copies so at most one is kept.
    static func moveStoreAside(at url: URL, now: Date) throws {
        let fileManager = FileManager.default
        let brokenRoot = url.deletingLastPathComponent().appending(path: "Broken", directoryHint: .isDirectory)
        let destination = brokenRoot.appending(
            path: "\(Int(now.timeIntervalSince1970))-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        let name = url.lastPathComponent
        for fileName in ["\(name)-wal", "\(name)-shm", name] {
            let source = url.deletingLastPathComponent().appending(path: fileName)
            guard fileManager.fileExists(atPath: source.path(percentEncoded: false)) else { continue }
            try fileManager.moveItem(at: source, to: destination.appending(path: fileName))
        }
        let older = (try? fileManager.contentsOfDirectory(at: brokenRoot, includingPropertiesForKeys: nil)) ?? []
        for copy in older where copy.lastPathComponent != destination.lastPathComponent {
            try? fileManager.removeItem(at: copy)
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
