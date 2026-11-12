import ABSAppModel
import ABSCore
import ABSUI
import CoreGraphics
import Foundation
import SwiftUI
import Testing

@testable import Audiobookshelf

private let userStats = UserYearStats(
    totalListeningSessions: 42, totalListeningTime: 93_600,
    topAuthors: [YearStatsNameTime(name: "Mary Shelley", time: 1), YearStatsNameTime(name: "Bram Stoker", time: 1)],
    topGenres: [YearStatsGenreTime(genre: "Horror", time: 1)], numBooksFinished: 7, numBooksListened: 9,
    booksWithCovers: ["li-2"], finishedBooksWithCovers: ["li-1"])

/// A solid square image, standing in for a decoded cover.
private func solidImage(red: Double, green: Double, blue: Double) throws -> CGImage {
    let context = try #require(
        CGContext(
            data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(CGColor(srgbRed: red, green: green, blue: blue, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
    return try #require(context.makeImage())
}

/// The number of pure red pixels in `image`, redrawn as 8-bit sRGB RGBA. Nothing on the card
/// but a red cover is red: its text is white and tan, and its backdrop grey and gold.
private func redPixelCount(_ image: CGImage) throws -> Int {
    let width = image.width
    let height = image.height
    var bytes = [UInt8](repeating: 0, count: width * height * 4)
    try bytes.withUnsafeMutableBytes { buffer in
        let context = try #require(
            CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    }
    return stride(from: 0, to: bytes.count, by: 4).count { index in
        bytes[index] > 240 && bytes[index + 1] < 15 && bytes[index + 2] < 15
    }
}

@MainActor
@Suite struct YearInReviewPresentationTests {
    private let english = Locale(identifier: "en_US")

    @Test func stringsAreLocalized() {
        let keys = [
            "HeaderYearInReview", "LabelYearInReviewAdditions", "LabelYearInReviewAuthorsAdded",
            "LabelYearInReviewBooksAdded", "LabelYearInReviewBooksFinished", "LabelYearInReviewBooksListened",
            "LabelYearInReviewFinishedBooks", "LabelYearInReviewServer", "LabelYearInReviewSessions",
            "LabelYearInReviewSpentListening", "LabelYearInReviewTopAuthors", "LabelYearInReviewTopGenres",
            "LabelYearInReviewUser", "LabelYearInReviewVariant", "LabelYearInReviewYear",
            "MessageYearInReviewLoadFailed", "LabelYearReviewShow",
        ]
        for key in keys {
            #expect(L10n.string(key) != key, "\(key)")
        }
        #expect(L10n.string("HeaderYearInReviewYear", "2025") == "2025 Year in Review")
    }

    /// The shared image is the card's point size times the scale.
    @Test(arguments: [2.0, 3.0])
    func renderedImageHasTheExpectedPixelSize(scale: Double) throws {
        let card = YearInReviewCard(
            content: .user(userStats), year: 2025, covers: YearInReviewCovers(), locale: english)
        let image = try #require(YearInReviewShareImage.render(card, variant: .user, scale: scale))
        #expect(image.cgImage.width == Int(400 * scale))
        #expect(image.cgImage.height == Int(600 * scale))
        #expect(!image.png.isEmpty)
        #expect(image.filename == "audiobookshelf_my_2025.png")
    }

    @Test func serverImageIsNamedForTheServer() throws {
        let card = YearInReviewCard(
            content: .server(ServerYearStats(numBooksAdded: 3)), year: 2024, covers: YearInReviewCovers(),
            locale: english)
        let image = try #require(YearInReviewShareImage.render(card, variant: .server, scale: 2))
        #expect(image.filename == "audiobookshelf_server_2024.png")
        #expect(image.cgImage.width == 800)
    }

    /// Covers handed to the card are drawn in the one frame `ImageRenderer` takes.
    @Test func preloadedCoversAreDrawn() throws {
        func render(_ covers: YearInReviewCovers) throws -> CGImage {
            let card = YearInReviewCard(content: .user(userStats), year: 2025, covers: covers, locale: english)
            return try #require(YearInReviewShareImage.render(card, variant: .user, scale: 2)).cgImage
        }
        let red = try solidImage(red: 1, green: 0, blue: 0)
        let blue = try solidImage(red: 0, green: 0, blue: 1)
        #expect(try redPixelCount(render(YearInReviewCovers())) == 0)
        // The finished book's cover, 64 pt square at full opacity in the bottom row (2x).
        let drawn = try redPixelCount(render(YearInReviewCovers(images: ["li-1": red, "li-2": blue])))
        #expect(drawn >= 120 * 120)
    }

    @Test func tilesShowTheLegacyTotals() {
        let user = YearInReviewCard.tiles(for: .user(userStats), locale: english)
        #expect(user.map(\.value) == ["7", "1d 2h", "42", "9"])
        #expect(
            user.map(\.labelKey) == [
                "LabelYearInReviewBooksFinished", "LabelYearInReviewSpentListening", "LabelYearInReviewSessions",
                "LabelYearInReviewBooksListened",
            ])
        let server = YearInReviewCard.tiles(
            for: .server(ServerYearStats(numListeningSessions: 1200, numBooksAdded: 3, numAuthorsAdded: 2)),
            locale: english)
        #expect(server.map(\.value) == ["3", "0m", "1,200", "2"])
    }

    @Test func summaryReadsTheTotalsAndTopLists() {
        let summary = YearInReviewCard.summary(for: .user(userStats), year: 2025, locale: english)
        #expect(summary.hasPrefix("2025 Year in Review, 7 books finished, 1d 2h spent listening"))
        #expect(summary.contains("Top Authors: Mary Shelley and Bram Stoker"))
        #expect(summary.hasSuffix("Top Genres: Horror"))
    }
}
