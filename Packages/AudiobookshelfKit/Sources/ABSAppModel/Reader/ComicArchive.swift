import Foundation
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
    /// The page's entry couldn't be extracted, for example because it is damaged.
    case unreadablePage(Int)
}

/// A CBZ comic, read page by page (ADR 0008 §3).
///
/// The pages are the archive's images in the web client's order (``pageOrder(_:)``), numbered
/// from 1 like `ebookLocation`. ``page(_:)`` extracts one page on demand into ``cacheDirectory``
/// and returns its file. The cache keeps the ``maxCachedPages`` most recently requested pages: an
/// older page's file is deleted when a newer one is extracted, so callers read a page's file
/// before requesting many others. ``removeCache()`` deletes the directory, and so does `deinit`.
public actor ComicArchive {
    /// The entry paths of the pages; page `n` is `pagePaths[n - 1]`.
    public nonisolated let pagePaths: [String]
    /// The archive's `ComicInfo.xml`, if it has one that parses.
    public nonisolated let comicInfo: ComicInfo?
    /// The directory the pages are extracted into. It belongs to this archive.
    public nonisolated let cacheDirectory: URL
    /// How many extracted pages are kept.
    public nonisolated let maxCachedPages: Int

    public nonisolated var pageCount: Int { pagePaths.count }

    private let archive: Archive
    private let entries: [Entry]
    /// Cached pages, least recently requested first.
    private var cachedPages: [Int] = []
    /// How many entries were extracted, for tests.
    private(set) var extractionCount = 0

    /// The largest `ComicInfo.xml` read, so a hostile archive can't make the parser read gigabytes.
    static let maxComicInfoSize: UInt64 = 1 << 20

    /// Opens the archive at `url`. `cacheDirectory` is emptied: earlier contents may be pages of
    /// another file.
    public init(url: URL, cacheDirectory: URL, maxCachedPages: Int = 12) throws(ComicArchiveError) {
        if (try? ComicArchiveFormat(contentsOf: url)) == .rar { throw .unsupportedRAR }
        let archive: Archive
        do {
            archive = try Archive(url: url, accessMode: .read)
        } catch {
            throw .notAZip
        }
        let files = archive.filter { $0.type == .file }
        let pagePaths = Self.pageOrder(files.map(\.path))
        guard !pagePaths.isEmpty else { throw .noPages }
        let byPath = Dictionary(files.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })

        self.archive = archive
        self.entries = pagePaths.compactMap { byPath[$0] }
        self.pagePaths = pagePaths
        self.comicInfo = Self.comicInfoEntry(in: files).flatMap { Self.readComicInfo($0, from: archive) }
        self.cacheDirectory = cacheDirectory
        self.maxCachedPages = max(maxCachedPages, 1)
        try? FileManager.default.removeItem(at: cacheDirectory)
    }

    deinit {
        try? FileManager.default.removeItem(at: cacheDirectory)
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
            try? FileManager.default.removeItem(at: url)
            _ = try archive.extract(entries[number - 1], to: url)
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

    /// The page images among an archive's file `paths`, in the web client's order
    /// (`ComicReader.vue` `parseFilenames`): sorted by the last number in the basename, then the
    /// images without a number. Ties keep archive order.
    ///
    /// Images in a folder whose name starts with `_` (such as `__MACOSX`) are skipped, as the web
    /// client doesn't flatten those folders. So are dotfiles and dot folders, such as macOS `._`
    /// resource forks.
    static func pageOrder(_ paths: [String]) -> [String] {
        let pages = paths.filter(isPage).enumerated().map { offset, path in
            (path: path, number: lastNumber(inBasenameOf: path), offset: offset)
        }
        let numbered = pages.filter { $0.number != nil }.sorted { lhs, rhs in
            guard let left = lhs.number, let right = rhs.number else { return false }
            if left != right { return left.count != right.count ? left.count < right.count : left < right }
            return lhs.offset < rhs.offset
        }
        return (numbered + pages.filter { $0.number == nil }).map(\.path)
    }

    private static func isPage(_ path: String) -> Bool {
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard let name = components.last, !name.isEmpty, !name.hasPrefix("."),
            !components.dropLast().contains(where: { $0.hasPrefix("_") || $0.hasPrefix(".") })
        else { return false }
        return pageExtensions.contains((String(name) as NSString).pathExtension.lowercased())
    }

    /// The last run of ASCII digits in the file name without its extension, without leading zeros
    /// (`"0"` for zero), so numbers of any length compare by length and then digits.
    private static func lastNumber(inBasenameOf path: String) -> String? {
        let name = (path as NSString).lastPathComponent
        let basename = Substring((name as NSString).deletingPathExtension)
        guard let end = basename.lastIndex(where: \.isASCIIDigit) else { return nil }
        let start =
            basename[..<end].lastIndex(where: { !$0.isASCIIDigit }).map(basename.index(after:))
            ?? basename.startIndex
        let digits = basename[start...end].drop { $0 == "0" }
        return digits.isEmpty ? "0" : String(digits)
    }
}

extension Character {
    fileprivate var isASCIIDigit: Bool { isASCII && isWholeNumber }
}

// MARK: ComicInfo.xml

extension ComicArchive {
    /// `ComicInfo.xml` in any folder and case; otherwise the first XML file, which is what the
    /// legacy reader reads.
    private static func comicInfoEntry(in files: [Entry]) -> Entry? {
        let xml = files.filter { ($0.path as NSString).pathExtension.lowercased() == "xml" }
        return xml.first { ($0.path as NSString).lastPathComponent.lowercased() == "comicinfo.xml" } ?? xml.first
    }

    private static func readComicInfo(_ entry: Entry, from archive: Archive) -> ComicInfo? {
        guard entry.uncompressedSize <= maxComicInfoSize else { return nil }
        var data = Data()
        do {
            _ = try archive.extract(entry) { data.append($0) }
        } catch {
            return nil
        }
        return ComicInfo(xml: data)
    }
}
