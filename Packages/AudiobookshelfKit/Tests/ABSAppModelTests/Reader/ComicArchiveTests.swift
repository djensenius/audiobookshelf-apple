import Foundation
import Testing
@preconcurrency import ZIPFoundation

@testable import ABSAppModel

@Suite struct ComicArchiveTests {
    private let root = URL.temporaryDirectory.appending(path: "ComicArchive-\(UUID().uuidString)")
    private var cache: URL { root.appending(path: "cache") }

    /// Writes a ZIP at `root/name` whose entries are `files` (path → contents), in order.
    private func makeZip(_ files: [(String, Data)], name: String = "comic.cbz") throws -> URL {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appending(path: name)
        let archive = try Archive(url: url, accessMode: .create)
        for (path, data) in files {
            try archive.addEntry(
                with: path, type: .file, uncompressedSize: Int64(data.count), compressionMethod: .deflate,
                provider: { position, size in data.subdata(in: Int(position)..<Int(position) + size) })
        }
        return url
    }

    private func pages(_ names: String...) -> [(String, Data)] {
        names.map { ($0, Data("image \($0)".utf8)) }
    }

    private func write(_ bytes: [UInt8], name: String) throws -> URL {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appending(path: name)
        try Data(bytes).write(to: url)
        return url
    }

    private func cachedFiles() -> Set<String> {
        Set((try? FileManager.default.contentsOfDirectory(atPath: cache.path)) ?? [])
    }

    // MARK: Page order

    @Test func pagesSortByTheirNumberNotTheirName() {
        #expect(
            ComicArchive.pageOrder(["page10.jpg", "page9.jpg", "page1.jpg"]) == [
                "page1.jpg", "page9.jpg", "page10.jpg",
            ])
    }

    @Test func theLastNumberInTheBasenameCounts() {
        let order = ComicArchive.pageOrder(["vol2_page3.png", "vol9_page1.png", "vol1_page2.png"])
        #expect(order == ["vol9_page1.png", "vol1_page2.png", "vol2_page3.png"])
    }

    @Test func leadingZerosAndLongNumbersCompareByValue() {
        let order = ComicArchive.pageOrder(["p012.jpg", "p7.jpg", "p0.jpg", "p99999999999999999999999.jpg", "p100.jpg"])
        #expect(order == ["p0.jpg", "p7.jpg", "p012.jpg", "p100.jpg", "p99999999999999999999999.jpg"])
    }

    @Test func unnumberedImagesComeLastInArchiveOrder() {
        let order = ComicArchive.pageOrder(["credits.jpg", "2.jpg", "cover.jpg", "1.jpg"])
        #expect(order == ["1.jpg", "2.jpg", "credits.jpg", "cover.jpg"])
    }

    @Test func equalNumbersKeepArchiveOrder() {
        let order = ComicArchive.pageOrder(["b/1.jpg", "a/1.jpg", "c/01.jpg", "0.jpg"])
        #expect(order == ["0.jpg", "b/1.jpg", "a/1.jpg", "c/01.jpg"])
    }

    @Test func onlyImageExtensionsInAnyCaseArePages() {
        let order = ComicArchive.pageOrder([
            "1.JPG", "2.Jpeg", "3.PNG", "4.webp", "5.gif", "6.txt", "ComicInfo.xml", "7", "8.jpg.bak",
        ])
        #expect(order == ["1.JPG", "2.Jpeg", "3.PNG", "4.webp"])
    }

    @Test func nestedFoldersArePages() {
        let order = ComicArchive.pageOrder(["Comic/Chapter 2/page2.jpg", "Comic/Chapter 1/page1.jpg"])
        #expect(order == ["Comic/Chapter 1/page1.jpg", "Comic/Chapter 2/page2.jpg"])
    }

    @Test func macOSMetadataAndDotfilesAreNotPages() {
        let order = ComicArchive.pageOrder([
            "__MACOSX/Comic/._page1.jpg", "Comic/._page2.jpg", ".hidden.jpg", "Comic/.thumbs/3.jpg",
            "_extras/4.jpg", "Comic/page1.jpg",
        ])
        #expect(order == ["Comic/page1.jpg"])
    }

    // MARK: Opening

    @Test func opensAZipWithItsPagesInOrder() async throws {
        let url = try makeZip(pages("page10.jpg", "__MACOSX/._page1.jpg", "page9.jpg", "cover.png"))
        let comic = try ComicArchive(url: url, cacheDirectory: cache)
        #expect(comic.pagePaths == ["page9.jpg", "page10.jpg", "cover.png"])
        #expect(comic.pageCount == 3)
        #expect(comic.comicInfo == nil)
    }

    @Test func aFileThatIsNotAZipThrows() throws {
        let url = try write(Array("not a zip at all".utf8), name: "comic.cbz")
        #expect(throws: ComicArchiveError.notAZip) { try ComicArchive(url: url, cacheDirectory: cache) }
    }

    @Test func aMissingFileThrowsNotAZip() {
        #expect(throws: ComicArchiveError.notAZip) {
            try ComicArchive(url: root.appending(path: "missing.cbz"), cacheDirectory: cache)
        }
    }

    @Test func aRARThrowsUnsupported() throws {
        let url = try write([0x52, 0x61, 0x72, 0x21, 0x1A, 0x07, 0x01, 0x00, 0x00], name: "comic.cbz")
        #expect(throws: ComicArchiveError.unsupportedRAR) { try ComicArchive(url: url, cacheDirectory: cache) }
    }

    @Test func anArchiveWithoutImagesThrowsNoPages() throws {
        let url = try makeZip([("ComicInfo.xml", Data("<ComicInfo/>".utf8)), ("__MACOSX/._1.jpg", Data())])
        #expect(throws: ComicArchiveError.noPages) { try ComicArchive(url: url, cacheDirectory: cache) }
    }

    @Test func openingEmptiesTheCacheDirectory() throws {
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        try Data("stale".utf8).write(to: cache.appending(path: "page-1.jpg"))
        _ = try ComicArchive(url: try makeZip(pages("1.jpg")), cacheDirectory: cache)
        #expect(cachedFiles().isEmpty)
    }

    // MARK: Pages

    @Test func pagesAreExtractedOnlyWhenRequested() async throws {
        let comic = try ComicArchive(url: try makeZip(pages("1.jpg", "2.png", "3.jpg")), cacheDirectory: cache)
        #expect(cachedFiles().isEmpty)
        #expect(await comic.extractionCount == 0)

        let url = try await comic.page(2)

        #expect(try Data(contentsOf: url) == Data("image 2.png".utf8))
        #expect(url.lastPathComponent == "page-2.png")
        #expect(cachedFiles() == ["page-2.png"])
        #expect(await comic.extractionCount == 1)
    }

    @Test func aSecondRequestUsesTheCache() async throws {
        let comic = try ComicArchive(url: try makeZip(pages("1.jpg", "2.jpg")), cacheDirectory: cache)
        let first = try await comic.page(1)
        let second = try await comic.page(1)
        #expect(first == second)
        #expect(await comic.extractionCount == 1)
    }

    @Test func aDeletedCacheFileIsExtractedAgain() async throws {
        let comic = try ComicArchive(url: try makeZip(pages("1.jpg")), cacheDirectory: cache)
        try FileManager.default.removeItem(at: try await comic.page(1))
        let url = try await comic.page(1)
        #expect(try Data(contentsOf: url) == Data("image 1.jpg".utf8))
        #expect(await comic.extractionCount == 2)
    }

    @Test func theCacheKeepsTheMostRecentlyRequestedPages() async throws {
        let comic = try ComicArchive(
            url: try makeZip(pages("1.jpg", "2.jpg", "3.jpg", "4.jpg")), cacheDirectory: cache, maxCachedPages: 2)
        _ = try await comic.page(1)
        _ = try await comic.page(2)
        _ = try await comic.page(1)
        _ = try await comic.page(3)

        #expect(cachedFiles() == ["page-1.jpg", "page-3.jpg"])
        _ = try await comic.page(1)
        #expect(await comic.extractionCount == 3)
    }

    @Test func removeCacheDeletesTheDirectory() async throws {
        let comic = try ComicArchive(url: try makeZip(pages("1.jpg")), cacheDirectory: cache)
        _ = try await comic.page(1)
        await comic.removeCache()
        #expect(!FileManager.default.fileExists(atPath: cache.path))

        _ = try await comic.page(1)
        #expect(await comic.extractionCount == 2)
    }

    @Test func releasingTheArchiveDeletesItsCache() async throws {
        var comic: ComicArchive? = try ComicArchive(url: try makeZip(pages("1.jpg")), cacheDirectory: cache)
        _ = try await comic?.page(1)
        #expect(FileManager.default.fileExists(atPath: cache.path))
        comic = nil
        #expect(!FileManager.default.fileExists(atPath: cache.path))
    }

    @Test(arguments: [0, 3, -1])
    func pagesOutsideOneToCountThrow(page: Int) async throws {
        let comic = try ComicArchive(url: try makeZip(pages("1.jpg", "2.jpg")), cacheDirectory: cache)
        await #expect(throws: ComicArchiveError.pageOutOfRange(page: page, pageCount: 2)) {
            try await comic.page(page)
        }
        #expect(cachedFiles().isEmpty)
    }

    @Test func entryPathsNeverNameCacheFiles() async throws {
        let comic = try ComicArchive(url: try makeZip(pages("Comic/Chapter 1/1.jpg")), cacheDirectory: cache)
        let url = try await comic.page(1)
        #expect(url.deletingLastPathComponent().standardizedFileURL == cache.standardizedFileURL)
        #expect(url.lastPathComponent == "page-1.jpg")
    }

    @Test func parentDirectoryEntriesAreNotPages() {
        #expect(ComicArchive.pageOrder(["../../escape1.jpg", "a/../2.jpg", "3.jpg"]) == ["3.jpg"])
    }

    // MARK: ComicInfo

    @Test func readsComicInfo() throws {
        let xml = """
            <?xml version="1.0"?>
            <ComicInfo>
              <Title> The Start </Title><Series>Saga</Series><Number>1</Number><PageCount>3</PageCount>
              <Manga>YesAndRightToLeft</Manga>
              <Pages>
                <Page Image="0" Type="FrontCover"/><Page Image="1" DoublePage="True"/><Page Image="2"/>
              </Pages>
            </ComicInfo>
            """
        let files = pages("1.jpg") + [("Comic/comicinfo.XML", Data(xml.utf8)), ("notes.xml", Data("<x/>".utf8))]
        let comic = try ComicArchive(url: try makeZip(files), cacheDirectory: cache)
        #expect(
            comic.comicInfo
                == ComicInfo(
                    title: "The Start", series: "Saga", number: "1", pageCount: 3, isRightToLeft: true,
                    singlePageImages: [0, 1]))
    }

    @Test func anotherXMLFileIsReadWhenThereIsNoComicInfoFile() throws {
        let files = pages("1.jpg") + [("meta.xml", Data("<ComicInfo><Title>Other</Title></ComicInfo>".utf8))]
        let comic = try ComicArchive(url: try makeZip(files), cacheDirectory: cache)
        #expect(comic.comicInfo?.title == "Other")
    }

    @Test(arguments: ["<NotComicInfo/>", "not xml <", "", "<ComicInfo><Title>x</ComicInfo>"])
    func malformedComicInfoIsIgnored(xml: String) {
        #expect(ComicInfo(xml: Data(xml.utf8)) == nil)
    }

    @Test func mangaThatReadsLeftToRightIsNotRightToLeft() {
        #expect(ComicInfo(xml: Data("<ComicInfo><Manga>Yes</Manga></ComicInfo>".utf8))?.isRightToLeft == false)
    }

    // MARK: Format

    @Test func classifiesBySignature() throws {
        #expect(ComicArchiveFormat(signature: [0x50, 0x4B, 0x03, 0x04, 0x14]) == .zip)
        #expect(ComicArchiveFormat(signature: [0x50, 0x4B, 0x05, 0x06]) == .zip)
        #expect(ComicArchiveFormat(signature: Array("Rar!".utf8) + [0x1A, 0x07, 0x00]) == .rar)
        #expect(ComicArchiveFormat(signature: Array("Rar!".utf8) + [0x1A, 0x07, 0x01, 0x00]) == .rar)
        #expect(ComicArchiveFormat(signature: Array("%PDF-1.7".utf8)) == .unknown)
        #expect(ComicArchiveFormat(signature: [0x50, 0x4B]) == .unknown)
        #expect(ComicArchiveFormat(signature: []) == .unknown)
    }

    @Test func classifiesFilesByContentNotExtension() throws {
        let zip = try makeZip(pages("1.jpg"), name: "really-a-zip.cbr")
        let rar = try write(Array("Rar!".utf8) + [0x1A, 0x07, 0x00], name: "really-a-rar.cbz")
        #expect(try ComicArchiveFormat(contentsOf: zip) == .zip)
        #expect(try ComicArchiveFormat(contentsOf: rar) == .rar)
        #expect(ComicArchiveFormat.zip.canOpen)
        #expect(!ComicArchiveFormat.rar.canOpen)
        #expect(!ComicArchiveFormat.unknown.canOpen)
    }
}
