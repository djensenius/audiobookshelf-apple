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
            "MessageYearInReviewLoadFailed", "LabelYearReviewShow", "LabelYearInReviewLayoutCard",
            "LabelYearInReviewLayoutShort", "LabelYearInReviewLayoutBanner", "ButtonYearInReviewCopyImage",
            "ButtonYearInReviewSaveToPhotos", "HeaderYearInReviewPhotosFailed", "MessageYearInReviewImageCopied",
            "MessageYearInReviewSavedToPhotos", "MessageYearInReviewPhotosDenied",
            "MessageYearInReviewPhotosRestricted", "MessageYearInReviewPhotosSaveFailed", "LabelLayout",
            "LabelMore",
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

    /// The short and banner layouts render at their own point size times the scale, and are
    /// named apart from the full card.
    @Test(arguments: [YearInReviewLayout.short, .banner], [2.0, 3.0])
    func layoutImagesHaveTheExpectedPixelSize(layout: YearInReviewLayout, scale: Double) throws {
        let card = YearInReviewCard(
            content: .user(userStats), year: 2025, covers: YearInReviewCovers(), locale: english, layout: layout)
        let image = try #require(YearInReviewShareImage.render(card, variant: .user, scale: scale))
        let points: (Int, Int) = layout == .short ? (600, 200) : (800, 420)
        #expect(image.cgImage.width == Int(Double(points.0) * scale))
        #expect(image.cgImage.height == Int(Double(points.1) * scale))
        #expect(image.filename == "audiobookshelf_my_2025_\(layout.rawValue).png")
        #expect(!image.png.isEmpty)
    }

    /// The banner draws the finished books' covers like the full card; the short layout, like
    /// legacy, has no cover row. Negative control: without covers the banner draws none.
    @Test func bannerDrawsTheFinishedCovers() throws {
        func render(_ layout: YearInReviewLayout, _ covers: YearInReviewCovers) throws -> CGImage {
            let card = YearInReviewCard(
                content: .user(userStats), year: 2025, covers: covers, locale: english, layout: layout)
            return try #require(YearInReviewShareImage.render(card, variant: .user, scale: 2)).cgImage
        }
        let covers = YearInReviewCovers(images: ["li-1": try solidImage(red: 1, green: 0, blue: 0)])
        #expect(try redPixelCount(render(.banner, covers)) >= 120 * 120)
        #expect(try redPixelCount(render(.banner, YearInReviewCovers())) == 0)
        #expect(try redPixelCount(render(.short, covers)) == 0)
    }

    /// VoiceOver reads only what the short layout shows.
    @Test func shortSummaryReadsItsTwoTotals() {
        let short = YearInReviewCard.summary(for: .user(userStats), year: 2025, locale: english, layout: .short)
        #expect(short == "2025 Year in Review, 7 books finished, 9 books listened to")
        let banner = YearInReviewCard.summary(for: .user(userStats), year: 2025, locale: english, layout: .banner)
        #expect(banner == YearInReviewCard.summary(for: .user(userStats), year: 2025, locale: english))
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
        // VoiceOver reads the full unit names; the tile shows the narrow ones.
        #expect(user[1].spoken == "1 day, 2 hours spent listening")
        #expect(
            user.map(\.labelKey) == [
                "LabelYearInReviewBooksFinished", "LabelYearInReviewSpentListening", "LabelYearInReviewSessions",
                "LabelYearInReviewBooksListened",
            ])
        let server = YearInReviewCard.tiles(
            for: .server(ServerYearStats(numListeningSessions: 1200, numBooksAdded: 3, numAuthorsAdded: 2)),
            locale: english)
        #expect(server.map(\.value) == ["3", "0m", "1,200", "2"])
        #expect(
            server.map(\.spoken) == [
                "3 books added", "0 minutes spent listening", "1,200 listening sessions", "2 authors added",
            ])
    }

    /// VoiceOver reads each total as one localized phrase, in the singular for one.
    @Test func spokenTotalsUseThePluralForms() {
        let one = YearInReviewCard.tiles(
            for: .user(
                UserYearStats(
                    totalListeningSessions: 1, totalListeningTime: 60, numBooksFinished: 1, numBooksListened: 1)),
            locale: english)
        #expect(
            one.map(\.spoken) == [
                "1 book finished", "1 minute spent listening", "1 listening session", "1 book listened to",
            ])
    }

    @Test func summaryReadsTheTotalsAndTopLists() {
        let summary = YearInReviewCard.summary(for: .user(userStats), year: 2025, locale: english)
        #expect(summary.hasPrefix("2025 Year in Review, 7 books finished, 1 day, 2 hours spent listening"))
        #expect(summary.contains("Top Authors: Mary Shelley and Bram Stoker"))
        #expect(summary.hasSuffix("Top Genres: Horror"))
    }

    /// The year shows as plain Gregorian digits, whatever the locale's calendar or grouping.
    /// The negative control shows what formatting it through such a locale would give instead.
    @Test func yearIsShownAsAPlainGregorianNumber() throws {
        let japanese = Locale(identifier: "ja_JP@calendar=japanese")
        let summary = YearInReviewCard.summary(for: .user(userStats), year: 2025, locale: japanese)
        #expect(summary.hasPrefix("2025 Year in Review"))
        let card = YearInReviewCard(
            content: .user(userStats), year: 2025, covers: YearInReviewCovers(), locale: japanese)
        #expect(try #require(YearInReviewShareImage.render(card, variant: .user, scale: 2)).filename.contains("2025"))

        #expect(2025.formatted(.number.locale(english)) == "2,025")
        let june = try Date("2025-06-15T12:00:00Z", strategy: .iso8601)
        let style = Date.FormatStyle(locale: japanese, calendar: Calendar(identifier: .japanese), timeZone: .gmt)
        #expect(!june.formatted(style.year()).contains("2025"))
    }

    // MARK: Render slot

    private func key(year: Int, variant: YearInReviewVariant = .user, revision: Int = 1) -> YearInReviewRenderKey {
        YearInReviewRenderKey(
            content: .user(userStats), year: year, variant: variant, scale: 2, locale: english,
            loadRevision: revision)
    }

    /// A render that finishes after the selection changed doesn't replace the newer one's image,
    /// whether or not the newer render has begun.
    @Test func lateRenderDoesNotReplaceANewerSelection() {
        let old = key(year: 2024)
        let new = key(year: 2025, variant: .server)
        var slot = YearInReviewRenderSlot<String>()
        slot.begin(old)
        // The selection changed; its render hasn't begun yet.
        let published1 = slot.finish("2024", for: old, current: new)
        #expect(!published1)
        #expect(slot.image == nil)
        slot.begin(new)
        let published2 = slot.finish("2025", for: new, current: new)
        #expect(published2)
        let published3 = slot.finish("2024", for: old, current: new)
        #expect(!published3)
        #expect(slot.image == "2025")
        #expect(!slot.failed)
    }

    /// Negative control: the same late render is published when its key is still the selection,
    /// and a render without an image marks the slot failed.
    @Test func renderForTheCurrentSelectionIsPublished() {
        let current = key(year: 2024)
        var slot = YearInReviewRenderSlot<String>()
        slot.begin(current)
        let publishedImage = slot.finish("2024", for: current, current: current)
        #expect(publishedImage)
        #expect(slot.image == "2024")
        slot.begin(current)
        #expect(slot.image == nil)
        let publishedFailure = slot.finish(nil, for: current, current: current)
        #expect(publishedFailure)
        #expect(slot.failed)
    }

    /// A successful refresh with unchanged stats gives a new key, so the view renders again and
    /// retries covers that failed, while the current image stays shown until the new one is
    /// ready. Negative control: without a refresh the key is unchanged, so nothing re-renders.
    @Test func refreshOfUnchangedStatsRendersAgain() {
        let loaded = key(year: 2024, revision: 1)
        let refreshed = key(year: 2024, revision: 2)
        #expect(key(year: 2024, revision: 1) == loaded)
        #expect(refreshed != loaded)
        #expect(refreshed.isSameSelection(as: loaded))
        #expect(!key(year: 2025, revision: 2).isSameSelection(as: loaded))
        var slot = YearInReviewRenderSlot<String>()
        slot.begin(loaded)
        let missingCovers = slot.finish("no covers", for: loaded, current: loaded)
        #expect(missingCovers)
        slot.begin(refreshed)
        #expect(slot.image == "no covers")
        let stale = slot.finish("late", for: loaded, current: refreshed)
        #expect(!stale)
        let withCovers = slot.finish("covers", for: refreshed, current: refreshed)
        #expect(withCovers)
        #expect(slot.image == "covers")
        // Another selection still clears the image while it renders, and so does another layout.
        var otherLayout = refreshed
        otherLayout.layout = .short
        #expect(!otherLayout.isSameSelection(as: refreshed))
        slot.begin(otherLayout)
        #expect(slot.image == nil)
    }
}
