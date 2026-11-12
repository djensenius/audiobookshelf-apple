import ABSAPI
import ABSCore
import ABSData
import ABSDownloads
import Foundation
import Testing

@testable import ABSAppModel

/// Serves ebook bytes and records each request as `itemID|ino`.
final class FakeEbookFetcher: EbookFileFetching {
    struct Failure: Error {}

    let calls = Locked<[String]>([])
    let fails = Locked(false)
    let body: Data

    init(body: Data = Data("book".utf8)) {
        self.body = body
    }

    func ebookData(itemID: String, fileIno: String?) async throws -> Data {
        calls.value.append("\(itemID)|\(fileIno ?? "-")")
        if fails.value { throw Failure() }
        return body
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

    @Test func theAPIClientSendsCredentialsToTheServerAndRefusesARedirect() async throws {
        let host = "\(UUID().uuidString.lowercased()).stub.test"
        StubURLProtocol.register(host: host) { request in
            switch request.url?.path() {
            case "/api/items/li_1/ebook/ino_1": StubResponse(status: 200, body: Data("bytes".utf8))
            default: StubResponse(status: 302, headers: ["Location": "https://elsewhere.test/book.epub"])
            }
        }
        let client = APIClient(
            configuration: try APIClientConfiguration(
                baseURL: try #require(URL(string: "https://\(host)")), customHeaders: ["X-Proxy": "secret"]),
            tokenProvider: FixedTokens(), sessionConfiguration: StubURLProtocol.sessionConfiguration())
        let loader = EbookFileLoader(directory: readerTemporaryDirectory(), fetcher: client)

        let loaded = try await loader.load(request())
        await #expect(throws: APIError.self) { try await loader.load(request("li_2")) }

        #expect(try Data(contentsOf: loaded.url) == Data("bytes".utf8))
        #expect(!FileManager.default.fileExists(atPath: loader.cacheURL(for: request("li_2")).path))
        let sent = try #require(StubURLProtocol.requests(host: host).first)
        #expect(sent.value(forHTTPHeaderField: "Authorization") == "Bearer access")
        #expect(sent.value(forHTTPHeaderField: "X-Proxy") == "secret")
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
}
