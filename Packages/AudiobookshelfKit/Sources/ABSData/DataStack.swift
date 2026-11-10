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
        /// The process has the App Group entitlement but its container couldn't be resolved.
        /// Falling back would split the data from the shared store, so this is an error.
        case appGroupContainerUnresolved
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
            isAppGroupEntitled: Self.isAppGroupEntitled,
            groupContainerURL: {
                FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: AppSettings.appGroupIdentifier)
            },
            fallbackDirectory: URL.applicationSupportDirectory,
            onFallback: Self.reportFallback
        )
    }

    /// - Parameters:
    ///   - isAppGroupEntitled: Whether the process has the App Group entitlement.
    ///   - groupContainerURL: The App Group container, or `nil` when it can't be resolved.
    ///   - fallbackDirectory: Where the store goes when the process isn't entitled.
    ///   - onFallback: Called when the App Group store is replaced by the fallback store.
    init(
        location: Location,
        allowsSave: Bool,
        isAppGroupEntitled: () -> Bool = { true },
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
            if isAppGroupEntitled() {
                guard let groupURL = groupContainerURL() else {
                    Self.logger.fault("App Group entitlement present but its container can't be resolved")
                    throw LoadError.appGroupContainerUnresolved
                }
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

    /// On macOS, the signed entitlement (the ad hoc signed test host has none). iOS can't read its
    /// entitlements, and `AppSettings.isAppGroupAvailable` there only checks that the container
    /// resolves, so iOS always counts as entitled and an unresolved container fails closed.
    private static func isAppGroupEntitled() -> Bool {
        #if os(macOS)
            AppSettings.isAppGroupAvailable(AppSettings.appGroupIdentifier)
        #else
            true
        #endif
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
            try finishInterruptedMoves(for: url)
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
            // A corrupt or unmigratable store: start empty. The server still holds synced progress,
            // and the orphan sweep removes downloads that are no longer referenced.
            logger.fault("Store is incompatible (\(String(describing: error), privacy: .public)); moving it aside")
            try moveStoreAside(at: url, now: now)
            return try makeContainer(schema: schema, configuration: configuration)
        }
    }

    /// Resets only on confirmed corruption or a confirmed, non-transient incompatibility; anything
    /// unsure is transient, so the error is rethrown and the store left alone.
    private static func isIncompatible(_ error: SwiftDataError, storeURL: URL) -> Bool {
        switch sqliteHeaderMatches(at: storeURL) {
        case nil: return false
        case false?: return true
        case true?: return isConfirmedIncompatibility(underlyingError(of: error))
        }
    }

    private static let sqliteHeader = Data("SQLite format 3\u{0}".utf8)

    /// Whether the store's first 16 bytes are the SQLite header, or `nil` when they can't be read
    /// (missing, no permission, or data protection keeping the file unreadable while the device is
    /// locked; a package can't ask `UIApplication` whether protected data is available).
    static func sqliteHeaderMatches(at url: URL) -> Bool? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let header = try? handle.read(upToCount: sqliteHeader.count) else { return nil }
        return header == sqliteHeader
    }

    /// SwiftData keeps the Core Data error in a private field; `nil` (treated as transient) if a
    /// later SDK moves it.
    private static func underlyingError(of error: SwiftDataError) -> NSError? {
        Mirror(reflecting: error).children.lazy.compactMap { $0.value as? any Error }.first.map { $0 as NSError }
    }

    /// Core Data incompatibility codes: 134100 incompatible version hash, 134110 migration
    /// failed, 134130 missing source model, 134140 missing mapping model.
    private static let incompatibilityCodes: Set<Int> = [134_100, 134_110, 134_130, 134_140]
    /// `SQLITE_CORRUPT`, `SQLITE_NOTADB`.
    private static let corruptSQLiteCodes: Set<Int> = [11, 26]

    /// Errors inspected in a load error chain; a longer chain is never confirmed.
    static let maxInspectedErrors = 32

    /// Whether a load error confirms the store can't be used. An allow-list: every error in the
    /// chain (`NSUnderlyingErrorKey`, `NSDetailedErrors`, `NSMultipleUnderlyingErrorsKey`) must be
    /// either one carrying SQLite `CORRUPT`/`NOTADB` or, carrying no SQLite code, a Core Data
    /// incompatibility code (or a top-level 259 wrapping one). Anything else (timeouts, busy, locked, I/O, full, permission, POSIX,
    /// unknown codes) means the store may be intact, so it isn't confirmed.
    static func isConfirmedIncompatibility(_ error: NSError?) -> Bool {
        var chain: [NSError] = []
        var pending = error.map { [$0] } ?? []
        while let next = pending.popLast() {
            // A chain too large to inspect fully might hide a transient error: not confirmed.
            guard chain.count < maxInspectedErrors else { return false }
            chain.append(next)
            pending += [next.userInfo[NSUnderlyingErrorKey] as? NSError].compactMap { $0 }
            pending += next.userInfo[NSDetailedErrorsKey] as? [NSError] ?? []
            pending += next.userInfo[NSMultipleUnderlyingErrorsKey] as? [NSError] ?? []
        }
        func sqliteCode(_ error: NSError) -> Int? {
            let code = error.domain == NSSQLiteErrorDomain ? error.code : error.userInfo[NSSQLiteErrorDomain] as? Int
            return code.map { $0 & 0xFF }  // Primary code of an extended result code.
        }
        func isConfirming(_ error: NSError) -> Bool {
            if let code = sqliteCode(error) { return corruptSQLiteCodes.contains(code) }
            return error.domain == NSCocoaErrorDomain && incompatibilityCodes.contains(error.code)
        }
        // A top-level `NSFileReadCorruptFileError` (259) may wrap a confirming error; it never
        // confirms alone, and nested anywhere else it isn't trusted.
        let root = chain.first.map { $0.domain == NSCocoaErrorDomain && $0.code == NSFileReadCorruptFileError }
        let rest = root == true && sqliteCode(chain[0]) == nil ? chain.dropFirst() : chain[...]
        return !rest.isEmpty && rest.allSatisfy(isConfirming)
    }

    static let incompleteMarker = "INCOMPLETE"

    /// Moves the store and its SQLite side files into `Broken/<epoch>-<uuid>/` next to it, then
    /// deletes older broken copies so at most one is kept. The move is journaled: an `INCOMPLETE`
    /// marker listing the files is written first and removed last, and the main store moves
    /// first, so a crash never leaves a stale WAL beside a missing or new store.
    static func moveStoreAside(at url: URL, now: Date) throws {
        let brokenRoot = url.deletingLastPathComponent().appending(path: "Broken", directoryHint: .isDirectory)
        let destination = brokenRoot.appending(
            path: "\(Int(now.timeIntervalSince1970))-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let name = url.lastPathComponent
        let names = [name, "\(name)-wal", "\(name)-shm"].joined(separator: "\n")
        try Data(names.utf8).write(to: destination.appending(path: incompleteMarker), options: .atomic)
        try finishMove(into: destination, from: url.deletingLastPathComponent())
        pruneBrokenCopies(in: brokenRoot, keeping: destination.lastPathComponent)
    }

    /// Deletes completed copies except `keeping` (default: the newest by epoch); incomplete copies
    /// are kept. Best effort.
    private static func pruneBrokenCopies(in root: URL, keeping: String? = nil) {
        let completed = ((try? brokenCopies(in: root)) ?? []).filter { !isIncomplete($0) }
        let epoch = { (copy: URL) in Int(copy.lastPathComponent.prefix { $0.isNumber }) ?? 0 }
        let kept = keeping ?? completed.max { epoch($0) < epoch($1) }?.lastPathComponent
        for copy in completed where copy.lastPathComponent != kept {
            try? FileManager.default.removeItem(at: copy)
        }
    }

    /// Completes a move-aside interrupted by a crash or an error, before the store is opened, then
    /// applies the retention policy. Throws if `Broken/` exists but can't be read.
    static func finishInterruptedMoves(for url: URL) throws {
        let directory = url.deletingLastPathComponent()
        let brokenRoot = directory.appending(path: "Broken", directoryHint: .isDirectory)
        let incomplete = try brokenCopies(in: brokenRoot).filter(isIncomplete)
        for copy in incomplete {
            try finishMove(into: copy, from: directory)
        }
        if !incomplete.isEmpty { pruneBrokenCopies(in: brokenRoot) }
    }

    private static func isIncomplete(_ copy: URL) -> Bool {
        FileManager.default.fileExists(atPath: copy.appending(path: incompleteMarker).path(percentEncoded: false))
    }

    /// The copies in `root`; a missing `root` has none, and any other error is thrown.
    private static func brokenCopies(in root: URL) throws -> [URL] {
        do {
            return try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        } catch let error as NSError
            where (error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError)
            || (error.domain == NSPOSIXErrorDomain && error.code == Int(ENOENT))
        {
            return []
        }
    }

    /// Moves each file listed in `destination`'s marker that is still in `directory`, in order,
    /// then deletes the marker.
    private static func finishMove(into destination: URL, from directory: URL) throws {
        let marker = destination.appending(path: incompleteMarker)
        for name in try String(contentsOf: marker, encoding: .utf8).split(separator: "\n").map(String.init) {
            let source = directory.appending(path: name)
            guard FileManager.default.fileExists(atPath: source.path(percentEncoded: false)) else { continue }
            try FileManager.default.moveItem(at: source, to: destination.appending(path: name))
        }
        try FileManager.default.removeItem(at: marker)
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
