import ABSAPI
import ABSCore
import ABSData
import ABSDownloads
import Foundation
import Synchronization
import Testing

@testable import ABSAppModel

/// Serves ebook bytes, ignoring the size limit, and records each request as `itemID|ino`.
final class FakeEbookFetcher: EbookFileFetching {
    struct Failure: Error {}

    let calls = Locked<[String]>([])
    let fails = Locked(false)
    let caps = Locked<[Int]>([])
    let body: Data

    init(body: Data = Data("book".utf8)) {
        self.body = body
    }

    func downloadEbook(itemID: String, fileIno: String?, to destination: URL, maxBytes: Int) async throws {
        calls.value.append("\(itemID)|\(fileIno ?? "-")")
        caps.value.append(maxBytes)
        try Data(body.prefix(2)).write(to: destination)
        if fails.value { throw Failure() }
        try body.write(to: destination)
    }
}

private struct FixedTokens: TokenProvider {
    func tokens() async -> AuthTokens? { AuthTokens(accessToken: "access", refreshToken: "refresh") }
    func replaceTokens(expected: AuthTokens, with new: AuthTokens) async -> Bool { false }
    func expireSession(ifCurrent rejected: AuthTokens) async -> Bool { false }
}

func readerTemporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory.appending(path: "EbookFileLoaderTests-\(UUID().uuidString)")
}

private let connection = UUID()

private func request(_ itemID: String = "li_1", ino: String? = "ino_1", version: String = "10-1") -> EbookFileRequest {
    EbookFileRequest(connectionID: connection, itemID: itemID, fileIno: ino, fileExtension: "epub", version: version)
}

@Suite struct EbookFileLoaderTests {
    @Test func fetchesOnceThenOpensTheCachedCopy() async throws {
        let fetcher = FakeEbookFetcher()
        let loader = EbookFileLoader(directory: readerTemporaryDirectory(), fetcher: fetcher)

        let first = try await loader.load(request())
        let second = try await loader.load(request())

        #expect(first.origin == .fetched)
        #expect(second.origin == .cached)
        #expect(second.url == first.url)
        #expect(try Data(contentsOf: second.url) == Data("book".utf8))
        #expect(fetcher.calls.value == ["li_1|ino_1"])
    }

    @Test func aChangedFileIsFetchedAgain() async throws {
        let fetcher = FakeEbookFetcher()
        let loader = EbookFileLoader(directory: readerTemporaryDirectory(), fetcher: fetcher)

        let old = try await loader.load(request(version: "10-1"))
        let new = try await loader.load(request(version: "12-2"))

        #expect(new.origin == .fetched)
        #expect(new.url != old.url)
        #expect(fetcher.calls.value.count == 2)
    }

    @Test func prefersTheDownloadedFile() async throws {
        let directory = readerTemporaryDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let downloaded = directory.appending(path: "book.epub")
        try Data("local".utf8).write(to: downloaded)
        let fetcher = FakeEbookFetcher()
        let loader = EbookFileLoader(directory: directory, fetcher: fetcher) { _ in downloaded }

        let loaded = try await loader.load(request())

        #expect(loaded == (downloaded, .downloaded))
        #expect(fetcher.calls.value.isEmpty)

        // A download whose file is gone falls back to the server.
        try FileManager.default.removeItem(at: downloaded)
        #expect(try await loader.load(request()).origin == .fetched)
    }

    @Test func aFailedFetchCachesNothing() async throws {
        let fetcher = FakeEbookFetcher()
        fetcher.fails.value = true
        let loader = EbookFileLoader(directory: readerTemporaryDirectory(), fetcher: fetcher)

        await #expect(throws: FakeEbookFetcher.Failure.self) { try await loader.load(request()) }
        #expect(!FileManager.default.fileExists(atPath: loader.cacheURL(for: request()).path))

        fetcher.fails.value = false
        #expect(try await loader.load(request()).origin == .fetched)
    }

    @Test func prunesTheLeastRecentlyUsedCopies() async throws {
        let loader = EbookFileLoader(
            directory: readerTemporaryDirectory(), fetcher: FakeEbookFetcher(), maxTotalBytes: 6)
        let first = try await loader.load(request("a"))
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1)], ofItemAtPath: first.url.path)
        let second = try await loader.load(request("b"))

        #expect(!FileManager.default.fileExists(atPath: first.url.path))
        #expect(FileManager.default.fileExists(atPath: second.url.path))
    }

    @Test func cachePathsHoldNoServerIDs() {
        let loader = EbookFileLoader(directory: URL(filePath: "/cache"), fetcher: FakeEbookFetcher())
        let hostile = EbookFileRequest(
            connectionID: connection, itemID: "../../etc", fileIno: "a/b", fileExtension: "p/df", version: "1")

        let url = loader.cacheURL(for: hostile)

        #expect(url.deletingLastPathComponent().path == "/cache/\(connection.uuidString)")
        #expect(!url.lastPathComponent.contains("etc"))
        #expect(url.pathExtension == "bin")
        #expect(loader.cacheURL(for: request()).pathExtension == "epub")
    }

    @Test func requestFromAnEbookFile() {
        let metadata = FileMetadata(
            filename: "Book.PDF", ext: ".PDF", path: "/b/Book.PDF", relPath: "Book.PDF", size: 42, mtimeMs: 1_234.5)
        let file = EbookFile(ino: "ino_9", metadata: metadata, ebookFormat: .pdf)

        let request = EbookFileRequest(connectionID: connection, itemID: "li_9", file: file)

        #expect(request.fileIno == "ino_9")
        #expect(request.fileExtension == ".PDF")
        #expect(request.safeExtension == "pdf")
        #expect(request.version == "42-1234")
        // A blank ino asks for the primary ebook.
        #expect(EbookFileRequest(connectionID: connection, itemID: "li_9", file: EbookFile(ino: " ")).fileIno == nil)
    }

    @Test func theEndpointStaysOnTheServersOrigin() {
        let endpoint = EbookFileLoader.endpoint(itemID: "li/1", fileIno: "ino_1")

        #expect(endpoint.method == .get)
        #expect(endpoint.path == "/api/items/li%2F1/ebook/ino_1")
        #expect(endpoint.requiresAuthentication)
        #expect(endpoint.followsRedirects)
        #expect(endpoint.staysOnOrigin)
        #expect(EbookFileLoader.endpoint(itemID: "li_1", fileIno: nil).path == "/api/items/li_1/ebook")
    }

    private func stubFetcher(
        host: String, handler: @escaping StubURLProtocol.Handler
    ) throws -> APIEbookFileFetcher {
        StubURLProtocol.register(host: host, handler: handler)
        let client = APIClient(
            configuration: try APIClientConfiguration(
                baseURL: try #require(URL(string: "https://\(host)")), customHeaders: ["X-Proxy": "secret"]),
            tokenProvider: FixedTokens(), sessionConfiguration: StubURLProtocol.sessionConfiguration())
        return APIEbookFileFetcher(client: client, sessionConfiguration: StubURLProtocol.sessionConfiguration())
    }

    @Test func theFetcherSendsCredentialsToTheServerAndRefusesARedirect() async throws {
        let host = "\(UUID().uuidString.lowercased()).stub.test"
        let fetcher = try stubFetcher(host: host) { request in
            switch request.url?.path() {
            case "/api/items/li_1/ebook/ino_1": StubResponse(status: 200, body: Data("bytes".utf8))
            default: StubResponse(status: 302, headers: ["Location": "https://elsewhere.test/book.epub"])
            }
        }
        let loader = EbookFileLoader(directory: readerTemporaryDirectory(), fetcher: fetcher)

        let loaded = try await loader.load(request())
        await #expect(throws: APIError.redirectRefused(status: 302)) { try await loader.load(request("li_2")) }

        #expect(try Data(contentsOf: loaded.url) == Data("bytes".utf8))
        #expect(!FileManager.default.fileExists(atPath: loader.cacheURL(for: request("li_2")).path))
        let sent = try #require(StubURLProtocol.requests(host: host).first)
        #expect(sent.value(forHTTPHeaderField: "Authorization") == "Bearer access")
        #expect(sent.value(forHTTPHeaderField: "X-Proxy") == "secret")
        #expect(sent.httpShouldHandleCookies == false)
    }

    @Test func theFetcherStopsAtTheSizeLimit() async throws {
        let host = "\(UUID().uuidString.lowercased()).stub.test"
        let fetcher = try stubFetcher(host: host) { _ in StubResponse(status: 200, body: Data(count: 10)) }
        let directory = readerTemporaryDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appending(path: "book")

        await #expect(throws: EbookFileLoadError.tooLarge) {
            try await fetcher.downloadEbook(itemID: "li_1", fileIno: nil, to: destination, maxBytes: 9)
        }
        try await fetcher.downloadEbook(itemID: "li_1", fileIno: nil, to: destination, maxBytes: 10)
        #expect(try Data(contentsOf: destination).count == 10)
    }

    @Test func writingStopsAtTheLimit() async throws {
        let directory = readerTemporaryDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appending(path: "book")
        let bytes = AsyncThrowingStream<UInt8, any Error> { continuation in
            for byte in 0..<200_000 { continuation.yield(UInt8(truncatingIfNeeded: byte)) }
            continuation.finish()
        }

        await #expect(throws: EbookFileLoadError.tooLarge) {
            try await EbookFileLoader.write(bytes, to: destination, maxBytes: 100_000)
        }
        // It stops writing at the limit rather than reading the whole body first.
        #expect(try Data(contentsOf: destination).count <= 100_000)
    }

    @Test func aFileOverTheLimitIsNotCached() async throws {
        let fetcher = FakeEbookFetcher(body: Data(count: 10))
        let directory = readerTemporaryDirectory()
        let loader = EbookFileLoader(directory: directory, fetcher: fetcher, maxTotalBytes: 9)

        await #expect(throws: EbookFileLoadError.tooLarge) { try await loader.load(request()) }

        #expect(!FileManager.default.fileExists(atPath: loader.cacheURL(for: request()).path))
        #expect(
            try FileManager.default.contentsOfDirectory(
                atPath: directory.appending(path: ".partial/\(EbookFileLoader.launchID)").path) == [])
    }

    @Test(arguments: [(Int.max, 512 * 1024 * 1024), (1000, 1000)])
    func aFetchIsCappedAtTheBookLimit(cacheBytes: Int, cap: Int) async throws {
        let fetcher = FakeEbookFetcher()
        let loader = EbookFileLoader(directory: readerTemporaryDirectory(), fetcher: fetcher, maxTotalBytes: cacheBytes)

        _ = try await loader.load(request())

        #expect(EbookFileLoader.maxBookBytes == 512 * 1024 * 1024)
        #expect(fetcher.caps.value == [cap])
    }

    @Test func aFailedFetchLeavesNoPartialFile() async throws {
        let fetcher = FakeEbookFetcher()
        fetcher.fails.value = true
        let directory = readerTemporaryDirectory()
        let loader = EbookFileLoader(directory: directory, fetcher: fetcher)

        await #expect(throws: FakeEbookFetcher.Failure.self) { try await loader.load(request()) }

        #expect(
            try FileManager.default.contentsOfDirectory(
                atPath: directory.appending(path: ".partial/\(EbookFileLoader.launchID)").path) == [])
    }

    @Test(arguments: [1e100, -1e100, .nan, .infinity, -.infinity])
    func anUnrepresentableModificationTimeFallsBack(mtimeMs: Double) {
        let metadata = FileMetadata(
            filename: "Book.epub", ext: ".epub", path: "/b/Book.epub", relPath: "Book.epub", size: 42,
            mtimeMs: mtimeMs)
        let file = EbookFile(ino: "ino_9", metadata: metadata, updatedAt: 77)

        #expect(EbookFileRequest(connectionID: connection, itemID: "li_9", file: file).version == "42-77")
        #expect(EbookFileRequest.wholeMilliseconds(mtimeMs) == nil)
        #expect(EbookFileRequest.wholeMilliseconds(-1_234.9) == -1_234)
    }

    @Test func findsTheDownloadedEbookFile() throws {
        let root = readerTemporaryDirectory()
        let locations = DownloadLocations(root: root)
        let path = "li_1/Book.epub"
        let url = try locations.fileURL(forRelativePath: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("local".utf8).write(to: url)
        func item(_ files: [LocalFileDTO]) -> LocalLibraryItemDTO {
            LocalLibraryItemDTO(
                id: UUID(), serverConnectionID: connection, serverAddress: "https://abs.test", serverUserId: "u",
                libraryItemId: "li_1", mediaType: .book, title: "Book", relativeDirectory: "li_1", addedAt: .now,
                updatedAt: .now, media: LocalMediaSnapshot(metadata: .init(title: "Book")), files: files)
        }
        let ebook = LocalFileDTO(
            kind: .ebook, relativePath: path, filename: "Book.epub", mimeType: "application/epub+zip", size: 5,
            serverIno: "ino_1")
        let audio = LocalFileDTO(
            kind: .audio, relativePath: path, filename: "Book.epub", mimeType: "audio/mpeg", size: 5, serverIno: "ino_2"
        )
        let escaping = LocalFileDTO(
            kind: .ebook, relativePath: "../Book.epub", filename: "Book.epub", mimeType: "", size: 5, serverIno: "ino_3"
        )

        #expect(EbookFileLoader.downloadedFile(in: item([ebook]), fileIno: "ino_1", locations: locations) == url)
        #expect(EbookFileLoader.downloadedFile(in: item([ebook]), fileIno: nil, locations: locations) == url)
        #expect(EbookFileLoader.downloadedFile(in: item([ebook]), fileIno: "other", locations: locations) == nil)
        #expect(EbookFileLoader.downloadedFile(in: item([audio]), fileIno: "ino_2", locations: locations) == nil)
        #expect(EbookFileLoader.downloadedFile(in: item([escaping]), fileIno: "ino_3", locations: locations) == nil)
        #expect(EbookFileLoader.downloadedFile(in: nil, fileIno: "ino_1", locations: locations) == nil)
    }

    @Test func aDownloadedFileOverTheBookLimitIsRefused() async throws {
        let directory = readerTemporaryDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let downloaded = directory.appending(path: "book.epub")
        // Sparse, so it takes no space.
        #expect(FileManager.default.createFile(atPath: downloaded.path, contents: nil))
        let handle = try FileHandle(forWritingTo: downloaded)
        try handle.truncate(atOffset: UInt64(EbookFileLoader.maxBookBytes) + 1)
        let fetcher = FakeEbookFetcher()
        let loader = EbookFileLoader(directory: directory, fetcher: fetcher) { _ in downloaded }

        await #expect(throws: EbookFileLoadError.tooLarge) { try await loader.load(request()) }

        try handle.truncate(atOffset: UInt64(EbookFileLoader.maxBookBytes))
        try handle.close()
        #expect(try await loader.load(request()) == (downloaded, .downloaded))
        #expect(fetcher.calls.value.isEmpty)
    }

    @Test func partialsFromEarlierLaunchesAreReclaimed() async throws {
        let directory = readerTemporaryDirectory()
        let partials = directory.appending(path: ".partial")
        let abandoned = partials.appending(path: UUID().uuidString)
        let active = partials.appending(path: EbookFileLoader.launchID)
        for folder in [abandoned, active] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data(count: 100).write(to: folder.appending(path: "download"))
        }
        let loader = EbookFileLoader(directory: directory, fetcher: FakeEbookFetcher())

        _ = try await loader.load(request())

        #expect(!FileManager.default.fileExists(atPath: abandoned.path))
        // This launch's may be another reader window's fetch.
        #expect(FileManager.default.fileExists(atPath: active.appending(path: "download").path))
    }

    private func holdingFetcher(host: String, routes: [String: HoldingURLProtocol.Route]) throws -> APIEbookFileFetcher
    {
        HoldingURLProtocol.register(host: host, routes: routes)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HoldingURLProtocol.self]
        let client = APIClient(
            configuration: try APIClientConfiguration(baseURL: try #require(URL(string: "https://\(host)"))),
            tokenProvider: FixedTokens(), sessionConfiguration: configuration)
        return APIEbookFileFetcher(client: client, sessionConfiguration: configuration)
    }

    static let rejections: [(HoldingURLProtocol.Route, EbookFileLoadError?)] = [
        // Declared too large.
        (.init(status: 200, headers: ["Content-Length": "1000"]), .tooLarge),
        // Streams past the limit.
        (.init(status: 200, body: Data(count: 20)), .tooLarge),
        // An error body.
        (.init(status: 404), nil),
    ]

    @Test(arguments: rejections)
    func aRejectedTransferIsStopped(route: HoldingURLProtocol.Route, error: EbookFileLoadError?) async throws {
        let host = "\(UUID().uuidString.lowercased()).hold.test"
        let path = "/api/items/li_1/ebook"
        let fetcher = try holdingFetcher(host: host, routes: [path: route])
        let destination = readerTemporaryDirectory()
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

        await #expect(throws: (any Error).self) {
            try await fetcher.downloadEbook(
                itemID: "li_1", fileIno: nil, to: destination.appending(path: "book"), maxBytes: 10)
        }

        #expect(await HoldingURLProtocol.waitForStop(host: host, path: path))
    }

    @Test func aRejected401TransferIsStoppedBeforeTheRefresh() async throws {
        let host = "\(UUID().uuidString.lowercased()).hold.test"
        let path = "/api/items/li_1/ebook"
        let fetcher = try holdingFetcher(
            host: host,
            routes: [
                path: .init(status: 401),
                "/auth/refresh": .init(status: 500, finishes: true, awaitsStopOf: path),
            ])
        let destination = readerTemporaryDirectory()
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

        await #expect(throws: (any Error).self) {
            try await fetcher.downloadEbook(
                itemID: "li_1", fileIno: nil, to: destination.appending(path: "book"), maxBytes: 10)
        }

        #expect(HoldingURLProtocol.stoppedBeforeStart(host: host, path: "/auth/refresh") == true)
    }
}

/// Answers with a status, headers and an optional first part of the body, then holds the
/// transfer open until the client stops it, recording which requests were stopped. It sets a
/// content type, so URLSession delivers the response without waiting to sniff the body.
final class HoldingURLProtocol: URLProtocol {
    struct Route: Sendable {
        var status: Int
        var headers: [String: String] = [:]
        var body = Data()
        /// Ends the response instead of holding it.
        var finishes = false
        /// Records whether the request for this path was stopped or cancelled before this one
        /// started.
        var awaitsStopOf: String?
    }

    private struct HeldTask: @unchecked Sendable {
        let task: URLSessionTask?
    }

    private struct Host {
        var routes: [String: Route]
        var stopped: Set<String> = []
        var tasks: [String: HeldTask] = [:]
        /// Whether the awaited path was stopped when each waiting path started.
        var stoppedBeforeStart: [String: Bool] = [:]
    }

    private static let hosts = Mutex<[String: Host]>([:])

    static func register(host: String, routes: [String: Route]) {
        hosts.withLock { $0[host] = Host(routes: routes) }
    }

    static func stoppedBeforeStart(host: String, path: String) -> Bool? {
        hosts.withLock { $0[host]?.stoppedBeforeStart[path] }
    }

    /// Stopped, or cancelled: `cancel()` makes the task `canceling` at once, while `stopLoading`
    /// arrives later on the protocols' thread. (A task whose bytes aren't being read may be
    /// suspended, which isn't stopped.)
    private static func isStopped(host: String, path: String) -> Bool {
        hosts.withLock {
            $0[host]?.stopped.contains(path) == true
                || $0[host]?.tasks[path].map { [.canceling, .completed].contains($0.task?.state) } == true
        }
    }

    /// Whether the request for `path` is stopped within a couple of seconds.
    static func waitForStop(host: String, path: String) async -> Bool {
        for _ in 0..<200 {
            if isStopped(host: host, path: path) { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }

    override class func canInit(with request: URLRequest) -> Bool {
        guard let host = request.url?.host() else { return false }
        return hosts.withLock { $0[host] != nil }
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let host = url.host(),
            let route = Self.hosts.withLock({ $0[host]?.routes[url.path()] })
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        let task = HeldTask(task: task)
        Self.hosts.withLock { $0[host]?.tasks[url.path()] = task }
        if let awaited = route.awaitsStopOf {
            let stopped = Self.isStopped(host: host, path: awaited)
            Self.hosts.withLock { $0[host]?.stoppedBeforeStart[url.path()] = stopped }
        }
        let response = HTTPURLResponse(
            url: url, statusCode: route.status, httpVersion: "HTTP/1.1",
            headerFields: route.headers.merging(["Content-Type": "application/octet-stream"]) { old, _ in old })
        client?.urlProtocol(self, didReceive: response ?? HTTPURLResponse(), cacheStoragePolicy: .notAllowed)
        if !route.body.isEmpty { client?.urlProtocol(self, didLoad: route.body) }
        if route.finishes { client?.urlProtocolDidFinishLoading(self) }
    }

    override func stopLoading() {
        guard let url = request.url, let host = url.host() else { return }
        _ = Self.hosts.withLock { $0[host]?.stopped.insert(url.path()) }
    }
}
