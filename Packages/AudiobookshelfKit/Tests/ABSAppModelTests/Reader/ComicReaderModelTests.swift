import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@preconcurrency import ZIPFoundation

@testable import ABSAppModel

@MainActor
@Suite struct ComicReaderModelTests {
    private let root = URL.temporaryDirectory.appending(path: "ComicReader-\(UUID().uuidString)")
    private var cache: URL { root.appending(path: "cache") }
    private let defaults: UserDefaults

    init() throws {
        defaults = try #require(UserDefaults(suiteName: "ComicReaderModelTests-\(UUID().uuidString)"))
    }

    /// A PNG of `width` × `height` pixels.
    private func png(width: Int = 2, height: Int = 3) throws -> Data {
        let context = try #require(
            CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try #require(context.makeImage())
        let data = NSMutableData()
        let destination = try #require(
            CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }

    /// A CBZ of `count` portrait pages (`page1.png` …), with `landscape` pages wider than tall,
    /// plus `extra` entries.
    private func makeComic(
        pages count: Int, landscape: Set<Int> = [], extra: [(String, Data)] = [], name: String = "comic.cbz"
    ) throws -> URL {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appending(path: name)
        let archive = try Archive(url: url, accessMode: .create)
        var files = try (1...count).map { page in
            ("page\(page).png", landscape.contains(page) ? try png(width: 4, height: 2) : try png())
        }
        files += extra
        for (path, data) in files {
            try archive.addEntry(
                with: path, type: .file, uncompressedSize: Int64(data.count), compressionMethod: .deflate,
                provider: { position, size in data.subdata(in: Int(position)..<Int(position) + size) })
        }
        return url
    }

    private final class Reports {
        var turns: [(EbookLocation, Double)] = []
    }

    private func model(
        _ url: URL, start: EbookLocation? = nil, key: String? = nil, reports: Reports = Reports()
    ) -> ComicReaderModel {
        ComicReaderModel(
            fileURL: url, cacheDirectory: cache, startLocation: start, defaults: defaults, preferencesKey: key
        ) { location, progress in
            reports.turns.append((location, progress))
        }
    }

    // MARK: Location and progress

    @Test func opensAtTheSavedPageWithoutReportingIt() async throws {
        let reports = Reports()
        let reader = model(try makeComic(pages: 10), start: .page(4), reports: reports)
        await reader.open()
        #expect(reader.state == .ready)
        #expect(reader.pageCount == 10)
        #expect(reader.currentPage == 4)
        #expect(reports.turns.isEmpty)
    }

    @Test func aSavedPageOutsideTheComicOpensAtTheStart() async throws {
        let url = try makeComic(pages: 10)
        for start in [EbookLocation.page(11), .cfi("epubcfi(/6/2)"), nil] {
            let reader = model(url, start: start)
            await reader.open()
            #expect(reader.currentPage == 1)
        }
    }

    @Test func turnsReportTheOneBasedPageAndTheWebProgress() async throws {
        let reports = Reports()
        let reader = model(try makeComic(pages: 10), start: .page(2), reports: reports)
        await reader.open()
        reader.turn(by: 1)
        reader.show(page: 10)
        reader.show(spreadAt: 0)
        #expect(reports.turns.map(\.0) == [.page(3), .page(10), .page(1)])
        #expect(reports.turns.map(\.1) == [0.2, 0.9, 0])
        #expect(reports.turns.allSatisfy { $0.0.isValid(for: .comic) })
    }

    @Test func turnsStopAtTheEndsAndRepeatsArentReported() async throws {
        let reports = Reports()
        let reader = model(try makeComic(pages: 3), reports: reports)
        await reader.open()
        reader.turn(by: -1)
        reader.show(spreadAt: 7)
        reader.show(page: 0)
        reader.turn(by: 5)
        reader.turn(by: 5)
        #expect(reports.turns.map(\.0) == [.page(3)])
        #expect(reader.currentPage == 3)
    }

    // MARK: Spreads

    @Test func spreadsPairAfterTheCoverAndKeepThePageBeingRead() async throws {
        let reports = Reports()
        let reader = model(try makeComic(pages: 6), start: .page(5), reports: reports)
        await reader.open()
        reader.setTwoUp(true)
        #expect(reader.spreads.map(\.pages) == [[1], [2, 3], [4, 5], [6]])
        #expect(reader.spreadIndex == 2)
        // The location is the spread's lower page, reported on the next turn only.
        #expect(reader.currentPage == 4)
        #expect(reports.turns.isEmpty)
        reader.turn(by: -1)
        #expect(reports.turns.map(\.0) == [.page(2)])
        reader.setTwoUp(false)
        #expect(reader.currentPage == 2)
    }

    @Test func verticalScrollIsAlwaysSingleAndRemembered() async throws {
        let url = try makeComic(pages: 4)
        let reader = model(url)
        await reader.open()
        reader.setTwoUp(true)
        reader.setVerticalScroll(true)
        #expect(reader.spreads.map(\.pages) == [[1], [2], [3], [4]])
        let reopened = model(url)
        #expect(reopened.isVerticalScroll)
    }

    @Test func landscapeAndMarkedPagesShowAlone() async throws {
        let info = Data(
            """
            <ComicInfo><Pages><Page Image="5" DoublePage="True"/></Pages></ComicInfo>
            """.utf8)
        let reader = model(try makeComic(pages: 9, landscape: [3], extra: [("ComicInfo.xml", info)]), start: .page(5))
        await reader.open()
        reader.setTwoUp(true)
        #expect(reader.spreads.map(\.pages) == [[1], [2, 3], [4, 5], [6], [7, 8], [9]])
        let page = try #require(await reader.image(ofPage: 3))
        #expect(page.size == CGSize(width: 4, height: 2))
        #expect(reader.spreads.map(\.pages) == [[1], [2], [3], [4, 5], [6], [7, 8], [9]])
        #expect(reader.currentPage == 4)
        #expect(await reader.image(ofPage: 2)?.size == CGSize(width: 2, height: 3))
        #expect(await reader.image(ofPage: 10) == nil)
    }

    // MARK: Direction

    @Test func mangaOpensRightToLeftAndArrowsFollowIt() async throws {
        let info = Data("<ComicInfo><Manga>YesAndRightToLeft</Manga></ComicInfo>".utf8)
        let reports = Reports()
        let reader = model(try makeComic(pages: 3, extra: [("ComicInfo.xml", info)]), reports: reports)
        await reader.open()
        #expect(reader.isRightToLeft)
        reader.turn(.left)
        reader.turn(.right)
        #expect(reports.turns.map(\.0) == [.page(2), .page(1)])
    }

    @Test func aChosenDirectionIsSavedPerBook() async throws {
        let info = Data("<ComicInfo><Manga>YesAndRightToLeft</Manga></ComicInfo>".utf8)
        let url = try makeComic(pages: 3, extra: [("ComicInfo.xml", info)])
        let first = model(url, key: "book-a")
        await first.open()
        first.setRightToLeft(false)
        let again = model(url, key: "book-a")
        await again.open()
        #expect(!again.isRightToLeft)
        let other = model(url, key: "book-b")
        await other.open()
        #expect(other.isRightToLeft)
    }

    // MARK: Unopenable files

    @Test func aRARArchiveIsUnsupportedAndOtherFilesFail() async throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let rar = root.appending(path: "comic.cbz")
        try Data([0x52, 0x61, 0x72, 0x21, 0x1A, 0x07, 0x01, 0x00]).write(to: rar)
        let reader = model(rar)
        await reader.open()
        #expect(reader.state == .unsupportedFormat)
        let text = root.appending(path: "notes.cbz")
        try Data("not a comic".utf8).write(to: text)
        let broken = model(text)
        await broken.open()
        #expect(broken.state == .failed)
        #expect(broken.spreads.isEmpty)
    }
}
