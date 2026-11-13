import Foundation
import Synchronization
@preconcurrency import ZIPFoundation

/// Why a comic archive can't be read.
public enum ComicArchiveError: Error, Equatable, Sendable {
    /// The file isn't a ZIP archive, or it is damaged.
    case notAZip
    /// The file is a RAR archive (CBR), which the app doesn't open in v1 (ADR 0008 §4).
    case unsupportedRAR
    /// The archive has no page images.
    case noPages
    /// `page` isn't between 1 and `pageCount`.
    case pageOutOfRange(page: Int, pageCount: Int)
    /// The page's entry couldn't be extracted, or its checksum doesn't match.
    case unreadablePage(Int)
    /// The page decompresses to more than ``ComicArchive/maxPageBytes``.
    case pageTooLarge(Int)
    /// The entry paths make more than ``ComicArchive/maxFolders`` folders.
    case tooManyFolders
    /// The archive has more than ``ComicArchive/maxEntries`` entries, its paths are longer than
    /// ``ComicArchive/maxPathBytes`` in total, or its headers are larger than 16 MiB in total.
    case tooManyEntries
}

/// A CBZ comic, read page by page (ADR 0008 §3).
///
/// The pages are the archive's images in the web client's order (``pageOrder(_:)``), numbered
/// from 1 like `ebookLocation`. ``page(_:)`` extracts one page on demand into ``cacheDirectory``
/// and returns its file. The cache keeps the ``maxCachedPages`` most recently requested pages: an
/// older page's file is deleted when a newer one is extracted, so callers read a page's file
/// before requesting many others. ``removeCache()`` deletes the directory, and so does `deinit`.
///
/// Entry sizes in the ZIP headers aren't trusted: extraction stops at ``maxPageBytes`` of output
/// (64 MiB by default) and at 1 MiB for `ComicInfo.xml`, and each entry's CRC-32 is checked.
/// The ZIP's structure is checked before ZIPFoundation reads it (``ComicArchivePreflight``), which
/// also bounds the headers that the kept entries hold.
public actor ComicArchive {
    /// The entry paths of the pages; page `n` is `pagePaths[n - 1]`.
    public nonisolated let pagePaths: [String]
    /// The archive's `ComicInfo.xml`, if it has one that parses.
    public nonisolated let comicInfo: ComicInfo?
    /// The directory the pages are extracted into. It belongs to this archive.
    public nonisolated let cacheDirectory: URL
    /// How many extracted pages are kept.
    public nonisolated let maxCachedPages: Int
    /// The cache directories of open archives (standardized paths, with how many archives use
    /// each), which ``removeStaleCaches(in:)`` keeps.
    private static let openCaches = Mutex<[String: Int]>([:])
    /// The most bytes one page may decompress to, so a small entry can't fill the disk.
    public nonisolated let maxPageBytes: Int

    public nonisolated var pageCount: Int { pagePaths.count }

    private let archive: Archive
    /// The pages' entries, read once when opening.
    private let pageEntries: [Entry]
    /// Cached pages, least recently requested first.
    private var cachedPages: [Int] = []
    /// How many entries were extracted, for tests.
    private(set) var extractionCount = 0

    /// The largest `ComicInfo.xml` read, so a hostile archive can't make the parser read gigabytes.
    static let maxComicInfoSize = 1 << 20
    public static let defaultMaxPageBytes = 64 << 20
    /// The most folders the entry paths may make, so a small archive can't exhaust memory. A single
    /// path can make at most 32,768, as ZIP paths are under 64 KiB.
    public static let maxFolders = 1 << 16
    /// The most entries an archive may have; comics have a few hundred.
    public static let maxEntries = 10_000
    /// The most bytes of entry paths an archive may have in total.
    public static let maxPathBytes = 8 << 20

    /// Opens the archive at `url`. `cacheDirectory` is emptied: earlier contents may be pages of
    /// another file.
    public init(
        url: URL, cacheDirectory: URL, maxCachedPages: Int = 12, maxPageBytes: Int = defaultMaxPageBytes
    ) throws(ComicArchiveError) {
        if (try? ComicArchiveFormat(contentsOf: url)) == .rar { throw .unsupportedRAR }
        try ComicArchivePreflight.validate(url, maxEntries: Self.maxEntries)
        let archive: Archive
        do {
            archive = try Archive(url: url, accessMode: .read)
        } catch {
            throw .notAZip
        }
        // Other entries only create folders, which decide the web client's order.
        var paths: [String] = []
        // Byte-exact keys: `String` equality would merge canonically equivalent names.
        var files: [[UInt8]: Entry] = [:]
        var pathBytes = 0
        for (index, entry) in archive.enumerated() {
            let path = entry.path
            pathBytes += path.utf8.count
            guard index < Self.maxEntries, pathBytes <= Self.maxPathBytes else { throw .tooManyEntries }
            if entry.type == .file {
                paths.append(path)
                if files[Array(path.utf8)] == nil { files[Array(path.utf8)] = entry }
            } else {
                paths.append(path.hasSuffix("/") ? path : path + "/")
            }
        }
        guard let fileOrder = Self.webFileOrder(paths) else { throw .tooManyFolders }
        let pagePaths = Self.sortedPages(fileOrder)
        guard !pagePaths.isEmpty else { throw .noPages }

        self.archive = archive
        self.pageEntries = pagePaths.compactMap { files[Array($0.utf8)] }
        self.pagePaths = pagePaths
        self.comicInfo = Self.comicInfoPath(in: fileOrder).flatMap { files[Array($0.utf8)] }.flatMap {
            Self.readComicInfo($0, from: archive)
        }
        self.cacheDirectory = cacheDirectory
        self.maxCachedPages = max(maxCachedPages, 1)
        self.maxPageBytes = maxPageBytes
        Self.openCaches.withLock { $0[cacheDirectory.standardizedFileURL.path, default: 0] += 1 }
        try? FileManager.default.removeItem(at: cacheDirectory)
    }

    deinit {
        try? FileManager.default.removeItem(at: cacheDirectory)
        let key = cacheDirectory.standardizedFileURL.path
        Self.openCaches.withLock { caches in
            caches[key] = caches[key].flatMap { $0 > 1 ? $0 - 1 : nil }
        }
    }

    /// Deletes the folders in `root` that no open archive extracts into, such as the caches of
    /// readers open when the app was killed. Each one is checked and renamed in one step, so an
    /// archive opening meanwhile keeps its directory; the slow delete happens after.
    public static func removeStaleCaches(in root: URL) {
        let manager = FileManager.default
        guard let folders = try? manager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return }
        for folder in folders {
            let trash = root.appending(path: ".stale-\(UUID().uuidString)", directoryHint: .isDirectory)
            let isStale = openCaches.withLock { caches in
                caches[folder.standardizedFileURL.path] == nil && (try? manager.moveItem(at: folder, to: trash)) != nil
            }
            if isStale { try? manager.removeItem(at: trash) }
        }
    }

    /// The file of page `number` (1-based), extracted now unless it is cached.
    public func page(_ number: Int) throws(ComicArchiveError) -> URL {
        guard (1...pageCount).contains(number) else {
            throw .pageOutOfRange(page: number, pageCount: pageCount)
        }
        let url = fileURL(ofPage: number)
        if let index = cachedPages.firstIndex(of: number), FileManager.default.fileExists(atPath: url.path) {
            cachedPages.append(cachedPages.remove(at: index))
            return url
        }
        cachedPages.removeAll { $0 == number }
        do {
            try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
            try extract(pageEntries[number - 1], to: url)
        } catch ExtractionError.tooLarge {
            try? FileManager.default.removeItem(at: url)
            throw .pageTooLarge(number)
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw .unreadablePage(number)
        }
        extractionCount += 1
        cachedPages.append(number)
        while cachedPages.count > maxCachedPages {
            try? FileManager.default.removeItem(at: fileURL(ofPage: cachedPages.removeFirst()))
        }
        return url
    }

    /// Streams `entry` into a new file at `url`, stopping at ``maxPageBytes``.
    private func extract(_ entry: Entry, to url: URL) throws(ExtractionError) {
        try? FileManager.default.removeItem(at: url)
        guard FileManager.default.createFile(atPath: url.path, contents: nil),
            let handle = try? FileHandle(forWritingTo: url)
        else { throw .unreadable }
        defer { try? handle.close() }
        var written = 0
        let limit = maxPageBytes
        let checksum = try Self.extract(entry, from: archive) { chunk in
            written += chunk.count
            guard written <= limit else { throw ExtractionError.tooLarge }
            try handle.write(contentsOf: chunk)
        }
        guard checksum == entry.checksum else { throw .unreadable }
    }

    enum ExtractionError: Error {
        case unreadable
        case tooLarge
    }

    /// Extracts `entry` through `consumer` and returns its CRC-32. ZIPFoundation computes it but
    /// doesn't compare it with the entry's, so callers do.
    static func extract(
        _ entry: Entry, from archive: Archive, consumer: (Data) throws -> Void
    ) throws(ExtractionError) -> CRC32 {
        // ZIPFoundation 0.9.20 converts these sizes to `Int64` unchecked, which traps.
        let limit = UInt64(Int64.max)
        guard entry.compressedSize <= limit, entry.uncompressedSize <= limit else { throw .unreadable }
        // Past the end of a truncated entry, ZIPFoundation passes empty chunks until it has counted
        // the claimed size. A stored entry has at most one, when it's empty. A deflated one has one
        // per input chunk that inflates to nothing (such as empty blocks), plus one at the end.
        let maxEmptyChunks = entry.isCompressed ? entry.compressedSize / UInt64(defaultReadChunkSize) + 2 : 1
        var emptyChunks: UInt64 = 0
        do {
            return try archive.extract(entry, skipCRC32: false) { chunk in
                emptyChunks = chunk.isEmpty ? emptyChunks + 1 : 0
                guard emptyChunks <= maxEmptyChunks else { throw ExtractionError.unreadable }
                try consumer(chunk)
            }
        } catch ExtractionError.tooLarge {
            throw .tooLarge
        } catch {
            throw .unreadable
        }
    }

    /// Deletes the extracted pages and the cache directory. Later pages are extracted again.
    public func removeCache() {
        cachedPages.removeAll()
        try? FileManager.default.removeItem(at: cacheDirectory)
    }

    /// The cache file of page `number`. It is named by number, never by entry path, so no entry
    /// can write outside the cache directory.
    private func fileURL(ofPage number: Int) -> URL {
        let pathExtension = (pagePaths[number - 1] as NSString).pathExtension.lowercased()
        return cacheDirectory.appending(path: "page-\(number).\(pathExtension)", directoryHint: .notDirectory)
    }
}

// MARK: Page order

extension ComicArchive {
    /// The page images' extensions, compared case-insensitively.
    static let pageExtensions: Set<String> = ["jpeg", "jpg", "png", "webp"]

    /// The page images among an archive's entry `paths` (in archive order; folders end in `/`), in
    /// the web client's order (`ComicReader.vue` `parseFilenames`): sorted by the last number in
    /// the basename, then the images without a number. Ties keep the order of ``webFileOrder(_:)``,
    /// which groups each folder's contents. A path that appears twice is listed once.
    ///
    /// Images in a folder whose name starts with `_` (such as `__MACOSX`) are skipped, as the web
    /// client doesn't flatten those folders. So are dotfiles and dot folders, such as macOS `._`
    /// resource forks. `nil` if the paths make more than `maxFolders` folders.
    static func pageOrder(_ paths: [String], maxFolders: Int = ComicArchive.maxFolders) -> [String]? {
        webFileOrder(paths, maxFolders: maxFolders).map(sortedPages)
    }

    /// The page images among `files`, which are in ``webFileOrder(_:maxFolders:)``, sorted.
    private static func sortedPages(_ files: [String]) -> [String] {
        let pages = files.filter(isPage).enumerated().map { offset, path in
            (path: path, number: lastNumber(inBasenameOf: path), offset: offset)
        }
        let numbered = pages.filter { $0.number != nil }.sorted { lhs, rhs in
            guard let left = lhs.number, let right = rhs.number else { return false }
            // Equal numbers, including two infinities, keep their order, like JavaScript's `a - b`.
            if left != right { return left < right }
            return lhs.offset < rhs.offset
        }
        return (numbered + pages.filter { $0.number == nil }).map(\.path)
    }

    /// The file paths in the order the web client lists them before sorting. libarchive.js
    /// `getFilesObject` nests the entries into JavaScript objects by path component, in archive
    /// order, and `flattenFilesObject` walks them depth first. So a folder's contents stay
    /// together, at the position where the folder first appeared. JavaScript lists integer-like
    /// keys (folders named `1`, `2`, …) first, in numeric order. A repeated path keeps its first
    /// position, and the first entry is kept. Names are compared byte for byte, as in JavaScript,
    /// so canonically equivalent names (NFC and NFD) stay apart. `nil` once the paths have made
    /// more than `maxFolders` folders.
    static func webFileOrder(_ paths: [String], maxFolders: Int = ComicArchive.maxFolders) -> [String]? {
        let root = Folder()
        defer { root.dismantle() }
        var folderCount = 0
        // `nil` over the budget, `.some(nil)` where a file has the name.
        func child(_ name: String, of parent: Folder) -> Folder?? {
            guard let found = parent.folder(named: name) else { return .some(nil) }
            if found.isNew { folderCount += 1 }
            guard folderCount <= maxFolders else { return nil }
            return found.folder
        }
        entries: for path in paths {
            var parts = components(of: path)
            let isFolder = parts.count > 1 && parts.last == ""
            if isFolder { parts.removeLast() }
            guard let name = parts.popLast() else { continue }
            var folder = root
            for part in parts {
                guard let next = child(part, of: folder) else { return nil }
                // Below a file, libarchive.js sets properties that the walk never reads.
                guard let next else { continue entries }
                folder = next
            }
            if isFolder {
                guard child(name, of: folder) != nil else { return nil }
            } else {
                folder.setFile(named: name, path: path)
            }
        }
        return root.flatten()
    }

    /// A folder of the entry tree. A ZIP path can nest tens of thousands of folders, so the tree is
    /// walked and freed without recursion.
    private final class Folder {
        enum Node {
            case file(path: String)
            case folder(Folder)
        }

        private var names: [String] = []
        private var nodes: [[UInt8]: Node] = [:]

        /// The folder `name`, created if new; `nil` if a file has that name.
        func folder(named name: String) -> (folder: Folder, isNew: Bool)? {
            let key = Array(name.utf8)
            switch nodes[key] {
            case .folder(let folder): return (folder, false)
            case .file: return nil
            case nil:
                let folder = Folder()
                names.append(name)
                nodes[key] = .folder(folder)
                return (folder, true)
            }
        }

        /// Like libarchive.js, a file replaces a folder of the same name in place.
        func setFile(named name: String, path: String) {
            let key = Array(name.utf8)
            switch nodes[key] {
            case .file: return
            // Emptied first, so releasing a deep folder doesn't recurse.
            case .folder(let folder): folder.dismantle()
            case nil: names.append(name)
            }
            nodes[key] = .file(path: path)
        }

        /// The files, depth first.
        func flatten() -> [String] {
            var files: [String] = []
            var stack: [(folder: Folder, names: ArraySlice<String>)] = [(self, Self.javaScriptKeyOrder(names)[...])]
            while let top = stack.indices.last {
                guard let name = stack[top].names.popFirst() else {
                    stack.removeLast()
                    continue
                }
                switch stack[top].folder.nodes[Array(name.utf8)] {
                case .file(let path): files.append(path)
                case .folder(let folder) where name.unicodeScalars.first != "_":
                    stack.append((folder, Self.javaScriptKeyOrder(folder.names)[...]))
                case .folder, nil: break
                }
            }
            return files
        }

        /// Empties the tree, so releasing it doesn't recurse through every level.
        func dismantle() {
            var pending = [self]
            while let folder = pending.popLast() {
                for case .folder(let child) in folder.nodes.values { pending.append(child) }
                folder.nodes.removeAll()
            }
        }

        /// JavaScript's own-property order: array-index keys ascending, then the rest as inserted.
        private static func javaScriptKeyOrder(_ names: [String]) -> [String] {
            func index(_ name: String) -> UInt32? {
                guard let value = UInt32(name), value != .max, String(value) == name else { return nil }
                return value
            }
            let indexed = names.compactMap { name in index(name).map { (name, $0) } }.sorted { $0.1 < $1.1 }
            return indexed.map(\.0) + names.filter { index($0) == nil }
        }
    }

    private static func isPage(_ path: String) -> Bool {
        !isSkipped(path) && pageExtensions.contains((path as NSString).pathExtension.lowercased())
    }

    /// Whether `path` is a dotfile, such as a macOS `._` resource fork, or is in a folder starting
    /// with `_` or `.`, such as `__MACOSX`.
    private static func isSkipped(_ path: String) -> Bool {
        let initials = components(of: path).map(\.unicodeScalars.first)
        guard let name = initials.last, let initial = name, initial != "." else { return true }
        return initials.dropLast().contains { $0 == "_" || $0 == "." }
    }

    /// The path's components, split at each `/` scalar like JavaScript's `split("/")`. Splitting
    /// `String` would keep a `/` followed by a combining mark, which is one `Character`.
    private static func components(of path: String) -> [String] {
        path.unicodeScalars.split(separator: "/", omittingEmptySubsequences: false).map {
            String(String.UnicodeScalarView($0))
        }
    }

    /// The last run of ASCII digits in the file name without its extension, as a `Double` like
    /// JavaScript's `Number(...)`: long numbers round, and very long ones are infinite. Digits are
    /// found by scalar, like JavaScript's `/\d+/`, so the `1` of `1️⃣` counts.
    private static func lastNumber(inBasenameOf path: String) -> Double? {
        let name = (path as NSString).lastPathComponent
        let basename = Array((name as NSString).deletingPathExtension.unicodeScalars)
        func isDigit(_ scalar: Unicode.Scalar) -> Bool { ("0"..."9").contains(scalar) }
        guard let end = basename.lastIndex(where: isDigit) else { return nil }
        let start = basename[..<end].lastIndex { !isDigit($0) }.map { $0 + 1 } ?? 0
        return Double(String(String.UnicodeScalarView(basename[start...end])))
    }
}

// MARK: ComicInfo.xml

extension ComicArchive {
    /// `ComicInfo.xml` in any folder and case; otherwise the first XML file, which is what the
    /// legacy reader reads. `files` are in ``webFileOrder(_:maxFolders:)``, as the legacy reader
    /// looks for it among the flattened files. Files skipped as pages, such as
    /// `__MACOSX/._ComicInfo.xml`, aren't metadata.
    private static func comicInfoPath(in files: [String]) -> String? {
        let xml = files.filter { !isSkipped($0) && ($0 as NSString).pathExtension.lowercased() == "xml" }
        return xml.first { ($0 as NSString).lastPathComponent.lowercased() == "comicinfo.xml" } ?? xml.first
    }

    /// `nil` if the entry is over ``maxComicInfoSize`` once decompressed (whatever its header says)
    /// or its checksum doesn't match.
    private static func readComicInfo(_ entry: Entry, from archive: Archive) -> ComicInfo? {
        var data = Data()
        let checksum = try? extract(entry, from: archive) { chunk in
            guard data.count + chunk.count <= maxComicInfoSize else { throw ExtractionError.tooLarge }
            data.append(chunk)
        }
        guard checksum == entry.checksum else { return nil }
        return ComicInfo(xml: data)
    }
}
