import Foundation
import ImageIO
import Synchronization
import Testing

@testable import ABSCore

/// `ImagePipeline.ensureCoverFile(for:)` and the widget snapshot's eviction exemption (ADR 0005,
/// "Widgets").
@Suite(.timeLimit(.minutes(1))) struct EnsureCoverFileTests {
    private let harness: PipelineHarness

    init() throws {
        harness = try PipelineHarness()
    }

    /// The widget's key: the 300 px bucket.
    private func key(_ id: String = "item-1", updatedAt: Int? = 2) -> ImageKey {
        harness.key(id, updatedAt: updatedAt).with(bucket: .small)
    }

    /// A downloaded-cover lookup that reports when it's asked, then waits for `release`.
    private struct GatedCovers: DownloadedCoverLookup {
        var cover: DownloadedCover
        let asked = Gate()
        let release = Gate()

        func downloadedCover(for key: ImageKey) async -> DownloadedCover? {
            asked.open()
            await release.wait()
            return cover
        }
    }

    private func downloaded(
        updatedAt: Int, width: Int = 1200, height: Int = 1920
    ) throws -> [String: DownloadedCover] {
        let file = try TestImages.file(width: width, height: height, in: harness.directory.url)
        return ["item-1": DownloadedCover(fileURL: file, updatedAt: updatedAt)]
    }

    private func pixelSize(of url: URL) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let width = properties[kCGImagePropertyPixelWidth] as? Int,
            let height = properties[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        return (width, height)
    }

    @Test func aFreshDownloadedCoverShownFromMemoryIsStoredAtTheBucket() async throws {
        let (pipeline, store) = await harness.make(downloaded: try downloaded(updatedAt: 2))
        let key = key()
        // Shown from the downloaded file, then from memory: neither writes the store.
        _ = try await pipeline.image(for: key, pixelBox: PixelBox(width: 300, height: 480))
        #expect(pipeline.cachedImage(for: key, pixelBox: PixelBox(width: 300, height: 480)) != nil)
        #expect(await store.lookup(key) == nil)

        let url = try await pipeline.ensureCoverFile(for: key)

        #expect(url.pathExtension == "jpg")
        #expect(await store.lookup(key)?.url == url)
        let size = try #require(pixelSize(of: url))
        #expect(size.width == 300 && size.height == 480)
        #expect(await pipeline.networkFetchCount == 0)
    }

    @Test func aTallDownloadedCoverIsLimitedByWidthOnly() async throws {
        let (pipeline, _) = await harness.make(downloaded: try downloaded(updatedAt: 2, width: 600, height: 3600))

        let url = try await pipeline.ensureCoverFile(for: key())

        let size = try #require(pixelSize(of: url))
        #expect(size.width == 300 && size.height == 1800)
    }

    @Test func aServerRemovedDuringTheDownloadedCoverLookupIsNotWritten() async throws {
        let store = CoverFileStore(directory: harness.directory.url.appending(path: "Images"), limit: 1 << 20)
        let file = try TestImages.file(width: 600, height: 960, in: harness.directory.url)
        let covers = GatedCovers(cover: DownloadedCover(fileURL: file, updatedAt: 2))
        let pipeline = ImagePipeline(limits: .iPhone, fileStore: store, downloadedCovers: covers)
        let key = key()
        let ensure = Task { try await pipeline.ensureCoverFile(for: key) }
        await covers.asked.wait()

        await pipeline.removeServer(harness.serverID)
        covers.release.open()

        await #expect(throws: ImagePipelineError.noRequest) { try await ensure.value }
        #expect(await store.size == 0)
        let folder = store.directory.appending(path: harness.serverID.uuidString)
        #expect(!FileManager.default.fileExists(atPath: folder.path))
    }

    @Test func aStoredFileIsReturnedWithoutFetchingAgain() async throws {
        let host = PipelineHarness.pngRoute(width: 300, height: 480)
        let (pipeline, store) = await harness.make(host: host)
        let key = key()

        let first = try await pipeline.ensureCoverFile(for: key)
        let second = try await pipeline.ensureCoverFile(for: key)

        #expect(first == second)
        #expect(await store.lookup(key)?.url == first)
        #expect(ImageStubProtocol.route(host)?.requests.count == 1)
        #expect(ImageStubProtocol.route(host)?.requests.first?.url?.query()?.contains("width=300") == true)
    }

    @Test func anOlderDownloadedCoverIsFetchedInsteadOfStoredUnderANewerKey() async throws {
        let host = PipelineHarness.pngRoute(width: 300, height: 480)
        let (pipeline, store) = await harness.make(host: host, downloaded: try downloaded(updatedAt: 1))
        let key = key(updatedAt: 2)

        let url = try await pipeline.ensureCoverFile(for: key)

        #expect(url.pathExtension == "png")
        #expect(await store.lookup(key)?.url == url)
        #expect(await pipeline.networkFetchCount == 1)
    }

    @Test func offlineWithOnlyAnOlderDownloadedCoverItThrowsAndStoresNothing() async throws {
        let host = PipelineHarness.pngRoute()
        let (pipeline, store) = await harness.make(
            host: host, downloaded: try downloaded(updatedAt: 1), isOnline: { false })
        let key = key(updatedAt: 2)
        // The display path shows the older cover offline …
        _ = try await pipeline.image(for: key, pixelBox: PixelBox(width: 300, height: 480))

        // … but it's never stored under the newer key.
        await #expect(throws: ImagePipelineError.offline) { try await pipeline.ensureCoverFile(for: key) }
        #expect(await store.lookup(key) == nil)
        #expect(await store.size == 0)
        #expect(ImageStubProtocol.route(host)?.requests.isEmpty == true)
    }

    @Test func aRemovedServersCoverIsNotWritten() async throws {
        let (pipeline, store) = await harness.make(downloaded: try downloaded(updatedAt: 2))
        await pipeline.removeServer(harness.serverID)

        await #expect(throws: ImagePipelineError.noRequest) { try await pipeline.ensureCoverFile(for: key()) }
        #expect(await store.size == 0)
    }

    @Test func snapshotFilesAreSkippedByEviction() async throws {
        let tick = Mutex(0.0)
        let store = CoverFileStore(directory: harness.directory.url.appending(path: "Images"), limit: 50_000) {
            tick.withLock { value in
                value += 60
                return Date(timeIntervalSince1970: value)
            }
        }
        let pipeline = ImagePipeline(limits: .iPhone, fileStore: store)
        func insert(_ id: String) async throws {
            let file = harness.directory.url.appending(path: UUID().uuidString)
            try Data(repeating: 7, count: 16_384).write(to: file)
            _ = try await store.insert(moving: file, for: key(id), pathExtension: "webp", generation: 0)
        }
        // The two oldest files are the snapshot's; the first set is replaced, so "z" is evictable.
        await pipeline.exemptFromEviction([key("z")])
        await pipeline.exemptFromEviction([key("a"), key("b")])
        for id in ["z", "a", "b", "c"] {
            try await insert(id)
        }
        await store.waitForEviction()

        #expect(await store.evictionCount == 1)
        #expect(await store.lookup(key("a")) != nil)
        #expect(await store.lookup(key("b")) != nil)
        #expect(await store.lookup(key("z")) == nil)
        #expect(await store.size <= 45_000)
    }
}
