import ABSAPI
import ABSCore
import ABSData
import ABSDownloads
import CryptoKit
import Foundation

/// Fetches an ebook file from the server onto disk.
public protocol EbookFileFetching: Sendable {
    /// Writes the body of `GET /api/items/:itemID/ebook[/:fileIno]` (the primary ebook when
    /// `fileIno` is `nil`) to a new file at `destination`, streaming it so the book is never held
    /// in memory. Throws ``EbookFileLoadError/tooLarge`` once the body passes `maxBytes`.
    func downloadEbook(itemID: String, fileIno: String?, to destination: URL, maxBytes: Int) async throws
}

/// Why ``EbookFileLoader`` didn't load a file.
public enum EbookFileLoadError: Error, Sendable, Equatable {
    /// The file is larger than the loader keeps.
    case tooLarge
}

/// Streams ebooks with an account's `APIClient` credentials (ADR 0008 §1).
///
/// `APIClient` buffers whole responses, so this sends the request itself, like a download
/// (``DownloadRequests``): the connection's custom headers and the client's access token, a
/// refreshed token after one 401, no cookies, and no redirect off the server's origin.
public final class APIEbookFileFetcher: EbookFileFetching {
    private let client: APIClient
    private let session: URLSession

    /// - Parameter sessionConfiguration: Tests pass a configuration with stub protocol classes.
    public init(client: APIClient, sessionConfiguration: URLSessionConfiguration = .absConnection()) {
        self.client = client
        let configuration = sessionConfiguration.copy() as? URLSessionConfiguration ?? .absConnection()
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = EbookFileLoader.fetchTimeout
        session = URLSession(configuration: configuration)
    }

    deinit {
        session.finishTasksAndInvalidate()
    }

    public func downloadEbook(itemID: String, fileIno: String?, to destination: URL, maxBytes: Int) async throws {
        let path = EbookFileLoader.endpoint(itemID: itemID, fileIno: fileIno).path
        var token = try await client.accessToken(replacing: nil)
        var retried = false
        while true {
            let request = try DownloadRequests.request(
                path: path, configuration: await client.configuration, accessToken: token)
            let bytes: URLSession.AsyncBytes
            let response: URLResponse
            do {
                (bytes, response) = try await session.bytes(for: request, delegate: SameOriginRedirects())
            } catch let error as URLError {
                throw error.code == .cancelled ? CancellationError() : APIError.network(error.code)
            }
            guard let http = response as? HTTPURLResponse else { throw APIError.invalidResponse }
            if http.statusCode == 401, !retried {
                retried = true
                token = try await client.accessToken(replacing: token)
                continue
            }
            guard (200..<300).contains(http.statusCode) else { throw Self.error(status: http.statusCode) }
            if http.expectedContentLength > Int64(maxBytes) { throw EbookFileLoadError.tooLarge }
            try await EbookFileLoader.write(bytes, to: destination, maxBytes: maxBytes)
            return
        }
    }

    private static func error(status: Int) -> APIError {
        switch status {
        case 401: .unauthorized(message: nil)
        case 403: .forbidden(message: nil)
        case 404: .notFound
        case 300..<400: .redirectRefused(status: status)
        default: .http(status: status, message: nil)
        }
    }
}

/// Follows a redirect only on the server's origin, with the request's headers again.
private final class SameOriginRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        DownloadRequests.redirect(following: response, to: request, original: task.originalRequest)
    }
}

/// The ebook file a reader opens, on one connection.
public struct EbookFileRequest: Sendable, Hashable, Codable {
    public var connectionID: UUID
    public var itemID: String
    /// The file's `ino`; `nil` (or blank, as some servers send) asks for the primary ebook.
    public var fileIno: String?
    /// The file's extension, lowercased, without the dot; the cached copy keeps it.
    public var fileExtension: String
    /// Changes when the server's file does (its size and modification time), so a cached copy
    /// of an older file isn't opened.
    public var version: String

    public init(connectionID: UUID, itemID: String, fileIno: String?, fileExtension: String, version: String) {
        self.connectionID = connectionID
        self.itemID = itemID
        let ino = fileIno?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.fileIno = ino?.isEmpty == false ? ino : nil
        self.fileExtension = fileExtension
        self.version = version
    }

    /// The request for a book's ebook file.
    public init(connectionID: UUID, itemID: String, file: EbookFile) {
        let metadata = file.metadata
        let ext = metadata?.ext ?? metadata.map { ($0.filename as NSString).pathExtension } ?? ""
        let modified = Self.wholeMilliseconds(metadata?.mtimeMs) ?? file.updatedAt.map(Int64.init)
        let version = "\(metadata?.size ?? -1)-\(modified ?? -1)"
        self.init(
            connectionID: connectionID, itemID: itemID, fileIno: file.ino, fileExtension: ext, version: version)
    }

    /// `value` truncated to whole milliseconds, or `nil` when that isn't an `Int64`: the server
    /// sends `mtimeMs` as a JSON number, which may be fractional, huge or not finite.
    static func wholeMilliseconds(_ value: Double?) -> Int64? {
        value.flatMap { $0.isFinite ? Int64(exactly: $0.rounded(.towardZero)) : nil }
    }

    /// ``fileExtension`` as a safe file name extension: lowercase letters and digits only, else `bin`.
    var safeExtension: String {
        let ext = fileExtension.lowercased().drop { $0 == "." }
        let isSafe = !ext.isEmpty && ext.count <= 8 && ext.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
        return isSafe ? String(ext) : "bin"
    }
}

/// Where a loaded ebook came from.
public enum EbookFileOrigin: Sendable, Hashable {
    /// The item's download (ADR 0007).
    case downloaded
    /// A copy this loader fetched earlier.
    case cached
    /// Fetched from the server now.
    case fetched
}

/// Gets an ebook file onto disk for a reader (#101, ADR 0008): the item's downloaded file when
/// there is one, else a cached copy, else the server's bytes, cached for next time.
///
/// The bytes come with the account's credentials (``APIEbookFileFetcher``), which go only to
/// the server's origin; the request doesn't follow a redirect off it. The reader gets a file URL, never a
/// server URL or token (ADR 0008 §1).
///
/// Each connection has a folder named by its UUID, and each file is named by a SHA-256 of its
/// item, `ino` and ``EbookFileRequest/version``, so server IDs never become path components. After
/// each fetch, the least recently opened copies are deleted until the folder totals at most
/// `maxTotalBytes`.
public actor EbookFileLoader {
    public static let defaultMaxTotalBytes = 512 << 20
    /// The largest ebook fetched: 512 MiB, matching `MAX_BOOK_BYTES` in the EPUB host's
    /// `reader.js`, so a book the reader would refuse is stopped before it's all on disk.
    public static let maxBookBytes = 512 * 1024 * 1024
    /// Ebooks can be large: allow more than the client's default request timeout.
    static let fetchTimeout: TimeInterval = 300

    public nonisolated let directory: URL
    public nonisolated let maxTotalBytes: Int
    private let fetcher: any EbookFileFetching
    private let downloadedFile: @Sendable (EbookFileRequest) async -> URL?

    /// - Parameters:
    ///   - directory: Belongs to the loader, for example a folder in the caches directory.
    ///   - downloadedFile: The item's downloaded copy of the file, if any
    ///     (``downloadedFileLookup(items:locations:)``).
    public init(
        directory: URL, fetcher: any EbookFileFetching, maxTotalBytes: Int = defaultMaxTotalBytes,
        downloadedFile: @escaping @Sendable (EbookFileRequest) async -> URL? = { _ in nil }
    ) {
        self.directory = directory
        self.fetcher = fetcher
        self.maxTotalBytes = maxTotalBytes
        self.downloadedFile = downloadedFile
    }

    /// The ebook endpoint, held to the server's origin: a hop elsewhere would be stripped of
    /// credentials and fetch an unrelated body as the book.
    public static func endpoint(itemID: String, fileIno: String?) -> Endpoint<Data> {
        var endpoint = ItemEndpoints.ebook(itemID: itemID, fileID: fileIno)
        endpoint.staysOnOrigin = true
        endpoint.timeout = fetchTimeout
        return endpoint
    }

    /// A local file URL with the ebook's bytes.
    ///
    /// A fetch streams into a hidden partial folder and moves into the cache only once it's
    /// complete; a failed or rejected one is deleted. A file over ``maxBookBytes`` or
    /// `maxTotalBytes` is ``EbookFileLoadError/tooLarge``.
    public func load(_ request: EbookFileRequest) async throws -> (url: URL, origin: EbookFileOrigin) {
        if let url = await downloadedFile(request), FileManager.default.fileExists(atPath: url.path) {
            return (url, .downloaded)
        }
        let url = cacheURL(for: request)
        if FileManager.default.fileExists(atPath: url.path) {
            // Marks it recently used for pruning.
            try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
            return (url, .cached)
        }
        let partials = directory.appending(path: ".partial", directoryHint: .isDirectory)
        let partial = partials.appending(path: UUID().uuidString, directoryHint: .notDirectory)
        let cap = min(Self.maxBookBytes, maxTotalBytes)
        do {
            try FileManager.default.createDirectory(at: partials, withIntermediateDirectories: true)
            try await fetcher.downloadEbook(
                itemID: request.itemID, fileIno: request.fileIno, to: partial, maxBytes: cap)
            let size = try partial.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= cap else { throw EbookFileLoadError.tooLarge }
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: url.path) {
                _ = try FileManager.default.replaceItemAt(url, withItemAt: partial)
            } else {
                try FileManager.default.moveItem(at: partial, to: url)
            }
        } catch {
            try? FileManager.default.removeItem(at: partial)
            throw error
        }
        prune(keeping: url)
        return (url, .fetched)
    }

    /// Writes `bytes` to a new file at `destination`, failing with ``EbookFileLoadError/tooLarge``
    /// as soon as they pass `maxBytes`.
    static func write<Bytes: AsyncSequence<UInt8, any Error>>(
        _ bytes: Bytes, to destination: URL, maxBytes: Int
    ) async throws {
        guard FileManager.default.createFile(atPath: destination.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }
        let chunkSize = 64 << 10
        var chunk = Data(capacity: chunkSize)
        var total = 0
        for try await byte in bytes {
            total += 1
            guard total <= maxBytes else { throw EbookFileLoadError.tooLarge }
            chunk.append(byte)
            if chunk.count == chunkSize {
                try handle.write(contentsOf: chunk)
                chunk.removeAll(keepingCapacity: true)
            }
        }
        try handle.write(contentsOf: chunk)
    }

    /// Where the cached copy of `request` lives.
    public nonisolated func cacheURL(for request: EbookFileRequest) -> URL {
        let identity = [request.itemID, request.fileIno ?? "", request.version].joined(separator: "\u{0}")
        let hash = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appending(path: request.connectionID.uuidString, directoryHint: .isDirectory)
            .appending(path: "\(hash).\(request.safeExtension)", directoryHint: .notDirectory)
    }

    /// Deletes every cached copy for a connection, for example when it's removed.
    public func remove(itemsOf connectionID: UUID) {
        try? FileManager.default.removeItem(
            at: directory.appending(path: connectionID.uuidString, directoryHint: .isDirectory))
    }

    /// Deletes the least recently used copies, other than `kept`, until the cache fits.
    private func prune(keeping kept: URL) {
        let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
        // Skips the hidden partial folder, whose files are still being written.
        guard
            let enumerator = FileManager.default.enumerator(
                at: directory, includingPropertiesForKeys: Array(keys), options: .skipsHiddenFiles)
        else { return }
        var files: [(url: URL, size: Int, date: Date)] = []
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: keys), values.isRegularFile == true else { continue }
            files.append((url, values.fileSize ?? 0, values.contentModificationDate ?? .distantPast))
        }
        var total = files.reduce(0) { $0 + $1.size }
        for file in files.sorted(by: { $0.date < $1.date }) where total > maxTotalBytes {
            guard file.url.standardizedFileURL != kept.standardizedFileURL else { continue }
            try? FileManager.default.removeItem(at: file.url)
            total -= file.size
        }
    }

    // MARK: Downloads

    /// The downloaded copy of `fileIno` (or of the item's only ebook file when `nil`) in `item`,
    /// if its file is on disk.
    public static func downloadedFile(
        in item: LocalLibraryItemDTO?, fileIno: String?, locations: DownloadLocations
    ) -> URL? {
        let ebooks = item?.files.filter { $0.kind == .ebook } ?? []
        let file =
            fileIno.map { ino in ebooks.first { $0.serverIno == ino } } ?? (ebooks.count == 1 ? ebooks.first : nil)
        guard let file, let url = try? locations.fileURL(forRelativePath: file.relativePath),
            FileManager.default.fileExists(atPath: url.path)
        else { return nil }
        return url
    }

    /// Looks a request's file up among the connection's downloads.
    public static func downloadedFileLookup(
        items: LocalItemStore, locations: DownloadLocations
    ) -> @Sendable (EbookFileRequest) async -> URL? {
        { request in
            let item = try? await items.item(serverConnectionID: request.connectionID, libraryItemId: request.itemID)
            return downloadedFile(in: item, fileIno: request.fileIno, locations: locations)
        }
    }
}
