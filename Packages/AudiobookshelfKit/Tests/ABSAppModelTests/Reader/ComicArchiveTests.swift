import Foundation
import Testing
@preconcurrency import ZIPFoundation

@testable import ABSAppModel

@Suite struct ComicArchiveTests {
    private let root = URL.temporaryDirectory.appending(path: "ComicArchive-\(UUID().uuidString)")
    private var cache: URL { root.appending(path: "cache") }

    /// Writes a ZIP at `root/name` whose entries are `files` (path → contents), in order.
    private func makeZip(
        _ files: [(String, Data)], name: String = "comic.cbz", compression: CompressionMethod = .deflate
    ) throws -> URL {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appending(path: name)
        let archive = try Archive(url: url, accessMode: .create)
        for (path, data) in files {
            try archive.addEntry(
                with: path, type: .file, uncompressedSize: Int64(data.count), compressionMethod: compression,
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

    /// Replaces the only occurrence of `old` in the file with `new`, which has the same length.
    private func patch(_ url: URL, replacing old: Data, with new: Data) throws {
        var bytes = try Data(contentsOf: url)
        let range = try #require(bytes.range(of: old))
        #expect(bytes[range.upperBound...].range(of: old) == nil)
        bytes.replaceSubrange(range, with: new)
        try bytes.write(to: url)
    }

    /// Makes the only entry's local and central headers claim an uncompressed size of 1 byte.
    private func understateSize(_ url: URL) throws {
        var bytes = try Data(contentsOf: url)
        for (signature, offset) in [([0x50, 0x4B, 0x03, 0x04] as [UInt8], 22), ([0x50, 0x4B, 0x01, 0x02], 24)] {
            let start = try #require(bytes.range(of: Data(signature))).lowerBound + offset
            bytes.replaceSubrange(start..<start + 4, with: [1, 0, 0, 0])
        }
        try bytes.write(to: url)
    }

    /// A central-directory record of ``makeRawZip(files:records:)``: `name` for the stored data of
    /// `files[file]`, optionally claiming a ZIP64 size.
    private struct Record {
        var name: String
        var file = 0
        var claimedSize: UInt64?
    }

    /// Writes a ZIP of stored `files` by hand, with `records` in its central directory, which may
    /// share local headers or forge sizes.
    private func makeRawZip(files: [(String, Data)], records: [Record], name: String = "raw.cbz") throws -> URL {
        var bytes = Data()
        func put<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { bytes.append(contentsOf: $0) }
        }
        var offsets: [UInt32] = []
        for (path, data) in files {
            offsets.append(UInt32(bytes.count))
            put(UInt32(0x0403_4B50))
            put(UInt16(20)); put(UInt16(0)); put(UInt16(0)); put(UInt16(0)); put(UInt16(0x21))
            put(data.crc32(checksum: 0)); put(UInt32(data.count)); put(UInt32(data.count))
            put(UInt16(path.utf8.count)); put(UInt16(0))
            bytes.append(contentsOf: path.utf8)
            bytes.append(data)
        }
        let directoryOffset = bytes.count
        for record in records {
            let data = files[record.file].1
            put(UInt32(0x0201_4B50))
            put(UInt16(45)); put(UInt16(45)); put(UInt16(0)); put(UInt16(0)); put(UInt16(0)); put(UInt16(0x21))
            put(data.crc32(checksum: 0))
            let size: UInt32 = record.claimedSize == nil ? UInt32(data.count) : .max
            put(size); put(size)
            put(UInt16(record.name.utf8.count)); put(UInt16(record.claimedSize == nil ? 0 : 20)); put(UInt16(0))
            put(UInt16(0)); put(UInt16(0)); put(UInt32(0)); put(offsets[record.file])
            bytes.append(contentsOf: record.name.utf8)
            if let claimed = record.claimedSize {
                put(UInt16(1)); put(UInt16(16)); put(claimed); put(claimed)
            }
        }
        let directorySize = bytes.count - directoryOffset
        put(UInt32(0x0605_4B50))
        put(UInt16(0)); put(UInt16(0)); put(UInt16(records.count)); put(UInt16(records.count))
        put(UInt32(directorySize)); put(UInt32(directoryOffset)); put(UInt16(0))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appending(path: name)
        try bytes.write(to: url)
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

    @Test func numbersCompareAsDoublesLikeJavaScript() {
        // Both round to 2^53, so they keep their order, as `Number(a) - Number(b)` is 0.
        let order = ComicArchive.pageOrder(["page9007199254740993.jpg", "page9007199254740992.jpg"])
        #expect(order == ["page9007199254740993.jpg", "page9007199254740992.jpg"])
        let huge = String(repeating: "9", count: 400)
        // Both are infinite, so they're equal too.
        let infinite = ComicArchive.pageOrder(["b\(huge)9.jpg", "a\(huge)8.jpg", "c1.jpg", "x.jpg"])
        #expect(infinite == ["c1.jpg", "b\(huge)9.jpg", "a\(huge)8.jpg", "x.jpg"])
    }

    @Test func leadingZerosAndLongNumbersCompareByValue() {
        let order = ComicArchive.pageOrder(["p012.jpg", "p7.jpg", "p0.jpg", "p99999999999999999999999.jpg", "p100.jpg"])
        #expect(order == ["p0.jpg", "p7.jpg", "p012.jpg", "p100.jpg", "p99999999999999999999999.jpg"])
    }

    @Test func digitsInsideOtherCharactersCountLikeJavaScript() {
        let keycapOne = "page1\u{FE0F}\u{20E3}.jpg"
        #expect(ComicArchive.pageOrder(["page2.jpg", keycapOne]) == [keycapOne, "page2.jpg"])
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

    @Test func foldersKeepTheirContentsTogetherLikeTheWebClient() {
        #expect(ComicArchive.pageOrder(["b/1.jpg", "a/1.jpg", "b/01.jpg"]) == ["b/1.jpg", "b/01.jpg", "a/1.jpg"])
        #expect(ComicArchive.pageOrder(["b/x.jpg", "a/y.jpg", "b/z.jpg"]) == ["b/x.jpg", "b/z.jpg", "a/y.jpg"])
    }

    @Test func aFolderEntryPlacesItsFolderWhereItAppears() {
        #expect(ComicArchive.pageOrder(["a/", "b/1.jpg", "a/1.jpg"]) == ["a/1.jpg", "b/1.jpg"])
    }

    @Test func integerNamedFoldersComeFirstInNumericOrderLikeJavaScriptKeys() {
        let order = ComicArchive.pageOrder(["x/cover.jpg", "10/a.jpg", "2/b.jpg", "01/c.jpg"])
        #expect(order == ["2/b.jpg", "10/a.jpg", "x/cover.jpg", "01/c.jpg"])
    }

    @Test func aRepeatedPathIsOnePage() {
        #expect(ComicArchive.pageOrder(["2.jpg", "1.jpg", "2.jpg"]) == ["1.jpg", "2.jpg"])
    }

    @Test func canonicallyEquivalentNamesAreDifferentFolders() {
        let order = ComicArchive.pageOrder(["caf\u{E9}/1.jpg", "x/1.jpg", "cafe\u{301}/01.jpg"])
        // `String` equality is canonical, so compare the bytes.
        #expect(
            order?.map { Array($0.utf8) }
                == ["caf\u{E9}/1.jpg", "x/1.jpg", "cafe\u{301}/01.jpg"].map { Array($0.utf8) })
    }

    @Test func deeplyNestedFoldersDoNotOverflowTheStack() {
        let deep = String(repeating: "a/", count: 100_000)
        let order = ComicArchive.pageOrder(
            [
                "1.jpg", deep + "2.jpg", String(repeating: "b/", count: 100_000) + "x.txt",
                // A file replaces the deep folder of the same name.
                "c.jpg/" + deep + "3.jpg", "c.jpg",
            ], maxFolders: 1_000_000)
        #expect(order == ["1.jpg", deep + "2.jpg", "c.jpg"])
    }

    @Test func pathsOverTheFolderBudgetAreRejected() {
        #expect(ComicArchive.pageOrder(["a/b/1.jpg", "c/1.jpg", "a/b/2.jpg"], maxFolders: 3) != nil)
        #expect(ComicArchive.pageOrder(["a/b/1.jpg", "c/1.jpg", "d/"], maxFolders: 3) == nil)
    }

    // MARK: Opening

    @Test func aRepeatedEntryKeepsTheFirstOne() async throws {
        let url = try makeZip([
            ("1.jpg", Data("first".utf8)), ("2.jpg", Data("two".utf8)), ("1.jpg", Data("second".utf8)),
        ])
        let comic = try ComicArchive(url: url, cacheDirectory: cache)
        #expect(comic.pagePaths == ["1.jpg", "2.jpg"])
        #expect(try Data(contentsOf: try await comic.page(1)) == Data("first".utf8))
        #expect(try Data(contentsOf: try await comic.page(2)) == Data("two".utf8))
    }

    @Test func canonicallyEquivalentEntriesAreDifferentPages() async throws {
        let url = try makeZip([("caf\u{E9}1.jpg", Data("nfc".utf8)), ("cafe\u{301}1.jpg", Data("nfd".utf8))])
        let comic = try ComicArchive(url: url, cacheDirectory: cache)
        #expect(comic.pageCount == 2)
        #expect(try Data(contentsOf: try await comic.page(1)) == Data("nfc".utf8))
        #expect(try Data(contentsOf: try await comic.page(2)) == Data("nfd".utf8))
    }

    @Test func anArchiveWithDeeplyNestedFoldersOpens() throws {
        let deep = String(repeating: "a/", count: 30_000)
        let files = pages("1.jpg", deep + "2.jpg", "c.jpg/" + deep + "3.jpg", "c.jpg")
        let comic = try ComicArchive(url: try makeZip(files), cacheDirectory: cache)
        #expect(comic.pagePaths == ["1.jpg", deep + "2.jpg", "c.jpg"])
    }

    @Test func anArchiveWithTooManyFoldersThrows() throws {
        let files =
            pages("1.jpg") + (0..<3).flatMap { pages("\($0)/" + String(repeating: "a/", count: 30_000) + "2.jpg") }
        #expect(throws: ComicArchiveError.tooManyFolders) {
            try ComicArchive(url: try makeZip(files), cacheDirectory: cache)
        }
    }

    @Test func anArchiveWithTooManyEntriesThrows() throws {
        let image = [("1.jpg", Data("image".utf8))]
        let atLimit = (0..<ComicArchive.maxEntries).map { Record(name: "\($0).jpg") }
        let comic = try ComicArchive(url: try makeRawZip(files: image, records: atLimit), cacheDirectory: cache)
        #expect(comic.pageCount == ComicArchive.maxEntries)
        let overLimit = atLimit + [Record(name: "x.jpg")]
        let url = try makeRawZip(files: image, records: overLimit, name: "over.cbz")
        #expect(throws: ComicArchiveError.tooManyEntries) { try ComicArchive(url: url, cacheDirectory: cache) }
    }

    @Test func anArchiveWithTooLongPathsThrows() throws {
        let long = String(repeating: "a", count: 60_000)
        let count = ComicArchive.maxPathBytes / 60_000 + 1
        let records = (0..<count).map { Record(name: "\(long)\($0).jpg") }
        let url = try makeRawZip(files: [("1.jpg", Data("image".utf8))], records: records)
        #expect(throws: ComicArchiveError.tooManyEntries) { try ComicArchive(url: url, cacheDirectory: cache) }
    }

    @Test func entriesSharingAHeaderAreReadAgainWhenExtracted() async throws {
        let files = [("1.jpg", Data("one".utf8)), ("2.jpg", Data("two".utf8))]
        let records = [Record(name: "2.jpg", file: 1), Record(name: "1.jpg", file: 0), Record(name: "3.jpg", file: 1)]
        let comic = try ComicArchive(url: try makeRawZip(files: files, records: records), cacheDirectory: cache)
        #expect(comic.pagePaths == ["1.jpg", "2.jpg", "3.jpg"])
        #expect(try Data(contentsOf: try await comic.page(1)) == Data("one".utf8))
        #expect(try Data(contentsOf: try await comic.page(3)) == Data("two".utf8))
    }

    @Test func entriesClaimingSizesOverInt64AreUnreadable() async throws {
        let forged = UInt64(Int64.max) + 1
        let files = [
            ("1.jpg", Data("one".utf8)), ("ComicInfo.xml", Data("<ComicInfo><Title>T</Title></ComicInfo>".utf8)),
        ]
        let records = [
            Record(name: "1.jpg"), Record(name: "2.jpg", claimedSize: forged),
            Record(name: "ComicInfo.xml", file: 1, claimedSize: forged),
        ]
        let comic = try ComicArchive(url: try makeRawZip(files: files, records: records), cacheDirectory: cache)
        #expect(comic.comicInfo == nil)
        #expect(try Data(contentsOf: try await comic.page(1)) == Data("one".utf8))
        await #expect(throws: ComicArchiveError.unreadablePage(2)) { try await comic.page(2) }
    }

    @Test func aRawZipWithoutForgedSizesIsRead() throws {
        let files = [
            ("1.jpg", Data("one".utf8)), ("ComicInfo.xml", Data("<ComicInfo><Title>T</Title></ComicInfo>".utf8)),
        ]
        let records = [Record(name: "1.jpg"), Record(name: "ComicInfo.xml", file: 1)]
        let comic = try ComicArchive(url: try makeRawZip(files: files, records: records), cacheDirectory: cache)
        #expect(comic.comicInfo?.title == "T")
    }

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

    @Test func aPageThatDecompressesPastTheLimitIsRemoved() async throws {
        let bomb = Data(count: 1 << 20)
        let url = try makeZip([("1.jpg", bomb), ("2.jpg", Data("small".utf8))])
        #expect(try Data(contentsOf: url).count < 16 << 10)
        let comic = try ComicArchive(url: url, cacheDirectory: cache, maxPageBytes: 64 << 10)

        await #expect(throws: ComicArchiveError.pageTooLarge(1)) { try await comic.page(1) }
        #expect(cachedFiles().isEmpty)
        #expect(try Data(contentsOf: try await comic.page(2)) == Data("small".utf8))
    }

    @Test func aPageAtTheLimitIsExtracted() async throws {
        let comic = try ComicArchive(
            url: try makeZip([("1.jpg", Data(count: 4096))]), cacheDirectory: cache, maxPageBytes: 4096)
        #expect(try Data(contentsOf: try await comic.page(1)).count == 4096)
    }

    @Test func aPageWithTheWrongChecksumIsUnreadable() async throws {
        let url = try makeZip(
            [("1.jpg", Data("page one bytes".utf8)), ("2.jpg", Data("two".utf8))], compression: .none)
        try patch(url, replacing: Data("page one bytes".utf8), with: Data("page one bytez".utf8))
        let comic = try ComicArchive(url: url, cacheDirectory: cache)

        await #expect(throws: ComicArchiveError.unreadablePage(1)) { try await comic.page(1) }
        #expect(cachedFiles().isEmpty)
        #expect(try Data(contentsOf: try await comic.page(2)) == Data("two".utf8))
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

    @Test func comicInfoWithTheWrongChecksumIsIgnored() throws {
        let xml = "<ComicInfo><Title>Original</Title></ComicInfo>"
        let url = try makeZip(pages("1.jpg") + [("ComicInfo.xml", Data(xml.utf8))], compression: .none)
        try patch(url, replacing: Data("Original".utf8), with: Data("Tampered".utf8))
        #expect(try ComicArchive(url: url, cacheDirectory: cache).comicInfo == nil)
    }

    @Test func comicInfoThatDecompressesPastTheLimitIsIgnoredWhateverItsHeaderSays() throws {
        let padding = String(repeating: " ", count: ComicArchive.maxComicInfoSize)
        let xml = "<ComicInfo><Title>Big</Title>\(padding)</ComicInfo>"
        let url = try makeZip([("ComicInfo.xml", Data(xml.utf8))] + pages("1.jpg"))
        try understateSize(url)
        #expect(try ComicArchive(url: url, cacheDirectory: cache).comicInfo == nil)
    }

    @Test func comicInfoUnderTheLimitIsReadWhateverItsHeaderSays() throws {
        let url = try makeZip(
            [("ComicInfo.xml", Data("<ComicInfo><Title>Small</Title></ComicInfo>".utf8))] + pages("1.jpg"))
        try understateSize(url)
        #expect(try ComicArchive(url: url, cacheDirectory: cache).comicInfo?.title == "Small")
    }

    @Test func readsCDATAText() {
        let xml =
            "<ComicInfo><Title><![CDATA[The <Start> & More]]></Title><Manga><![CDATA[YesAndRightToLeft]]></Manga></ComicInfo>"
        let info = ComicInfo(xml: Data(xml.utf8))
        #expect(info?.title == "The <Start> & More")
        #expect(info?.isRightToLeft == true)
    }

    @Test func anotherXMLFileIsReadWhenThereIsNoComicInfoFile() throws {
        let files = pages("1.jpg") + [("meta.xml", Data("<ComicInfo><Title>Other</Title></ComicInfo>".utf8))]
        let comic = try ComicArchive(url: try makeZip(files), cacheDirectory: cache)
        #expect(comic.comicInfo?.title == "Other")
    }

    @Test func resourceForksAndSkippedFoldersAreNotMetadata() throws {
        let files =
            pages("1.jpg") + [
                ("__MACOSX/._meta.xml", Data([0, 5, 22, 7])),
                ("_extras/meta.xml", Data("<ComicInfo><Title>Skipped</Title></ComicInfo>".utf8)),
                (".meta.xml", Data("<ComicInfo><Title>Hidden</Title></ComicInfo>".utf8)),
                ("meta.xml", Data("<ComicInfo><Title>Other</Title></ComicInfo>".utf8)),
            ]
        let comic = try ComicArchive(url: try makeZip(files), cacheDirectory: cache)
        #expect(comic.comicInfo?.title == "Other")
    }

    @Test func theFirstXMLFileIsTheFirstInTheWebClientsOrder() throws {
        let meta = ("b/meta.xml", Data("<ComicInfo><Title>Meta</Title></ComicInfo>".utf8))
        let notes = ("a/notes.xml", Data("<Notes/>".utf8))
        let comic = try ComicArchive(url: try makeZip(pages("b/1.jpg") + [notes, meta]), cacheDirectory: cache)
        #expect(comic.comicInfo?.title == "Meta")
    }

    @Test func comicInfoIsPreferredWhereverItIs() throws {
        let files =
            pages("b/1.jpg") + [
                ("b/meta.xml", Data("<ComicInfo><Title>Meta</Title></ComicInfo>".utf8)),
                ("a/ComicInfo.xml", Data("<ComicInfo><Title>Info</Title></ComicInfo>".utf8)),
            ]
        let comic = try ComicArchive(url: try makeZip(files, name: "info.cbz"), cacheDirectory: cache)
        #expect(comic.comicInfo?.title == "Info")
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
