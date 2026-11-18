import XCTest

/// The chapter list's current-chapter highlight (#705), on iOS: the details pane beside the
/// landscape player on an iPad, and the chapters sheet elsewhere. The accessibility audits can't
/// catch a missing tint: the row stays readable without it.
final class ChapterHighlightTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    #if os(iOS)
        /// How far apart the current row's background and another row's must be, in the largest
        /// difference of a channel (0 to 255). The light accent at 20% is 59 from white.
        private static let minimumTint = 20

        /// In light, the current chapter's row is tinted, unlike the others, and its times are
        /// readable on the tint: drawn in the primary colour, black, they're at least 4.5:1. The
        /// fixture's *Pride and Prejudice* plays from Chapter 1 and has a second chapter.
        @MainActor
        func testCurrentChapterIsTinted() throws {
            let app = signIn()
            open(.player, in: app)
            showChapters(in: app)
            let rows = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Chapter "))
            let current = rows.matching(NSPredicate(format: "selected == true")).firstMatch
            let other = rows.matching(NSPredicate(format: "selected == false")).firstMatch
            XCTAssertTrue(current.waitForExistence(timeout: Self.fixtureTimeout), "No row is the current chapter")
            XCTAssertTrue(other.exists, "There's no row besides the current chapter")
            // Let the sheet or rotation settle, so the screenshot shows the rows where their frames are.
            var frame = CGRect.null
            XCTAssertTrue(
                wait(
                    for: {
                        defer { frame = current.frame }
                        return current.frame == frame
                    }, timeout: Self.fixtureTimeout),
                "The chapter list didn't settle")

            let screenshot = XCUIScreen.main.screenshot()
            let attachment = XCTAttachment(screenshot: screenshot)
            attachment.name = "chapters"
            add(attachment)
            let image = try XCTUnwrap(Self.upright(screenshot), "Couldn't read the screenshot")
            let scale = CGFloat(image.width) / app.windows.firstMatch.frame.width
            let tinted = try XCTUnwrap(Self.background(in: current.frame, of: image, scale: scale))
            let plain = try XCTUnwrap(Self.background(in: other.frame, of: image, scale: scale))
            let difference = max(
                abs(Int(tinted.red) - Int(plain.red)), abs(Int(tinted.green) - Int(plain.green)),
                abs(Int(tinted.blue) - Int(plain.blue)))
            XCTAssertGreaterThanOrEqual(
                difference, Self.minimumTint,
                "The current chapter's row isn't tinted: \(tinted) against another row's \(plain)")

            // The row's texts are its title, start and duration.
            let texts = current.staticTexts.allElementsBoundByIndex
            XCTAssertEqual(texts.count, 3, "The current row's texts: \(texts.map(\.label))")
            for time in texts.dropFirst() {
                let ratio = MeasuredContrast.ratio(
                    in: time.frame, of: image, scale: scale, text: .init(red: 0, green: 0, blue: 0))
                XCTAssertGreaterThanOrEqual(
                    ratio ?? 0, 4.5, "The current row's '\(time.label)' isn't black at 4.5:1 on its tint")
            }
        }

        /// Shows the chapter list: on an iPad, turned to landscape, the details pane beside the player
        /// (turned back after the test); elsewhere, the chapters sheet at its large detent, where it's
        /// opaque, not glass over the player. A vertical bar (the iPhone Duo's outer display) has the
        /// Chapters button in its overflow menu, found by symbol as in `open(.bookmarks, in:)`.
        @MainActor
        private func showChapters(in app: XCUIApplication) {
            if UIDevice.current.userInterfaceIdiom == .pad {
                XCUIDevice.shared.orientation = .landscapeLeft
                addTeardownBlock { @MainActor in XCUIDevice.shared.orientation = .portrait }
                return
            }
            var button = app.buttons["player.chapters"].firstMatch
            if !(button.waitForExistence(timeout: 3) && button.isHittable) {
                let overflow = app.buttons["BottomOverflowBarButtonItem"].firstMatch
                XCTAssertTrue(overflow.exists, "The player has no Chapters button, and no overflow menu")
                overflow.press()
                button = app.collectionViews.buttons.containing(.image, identifier: "list.bullet").firstMatch
            }
            XCTAssertTrue(button.waitForEnabled(timeout: Self.fixtureTimeout), "The Chapters button isn't enabled")
            button.press()
            let bar = app.navigationBars.containing(.button, identifier: "player.sheet.done").firstMatch
            XCTAssertTrue(bar.waitForExistence(timeout: Self.fixtureTimeout), "The chapters sheet didn't appear")
            bar.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.5)).press(
                forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.05)))
        }

        /// `screenshot` drawn upright. In landscape it's the portrait framebuffer tagged with its
        /// orientation, while elements' frames are in the turned window.
        private static func upright(_ screenshot: XCUIScreenshot) -> CGImage? {
            let image = screenshot.image
            let format = UIGraphicsImageRendererFormat()
            format.scale = image.scale
            return UIGraphicsImageRenderer(size: image.size, format: format).image { _ in image.draw(at: .zero) }
                .cgImage
        }

        /// The most common colour of `image` in `frame` (in points, `scale` pixels each): a row's
        /// background, which its text covers little of.
        private static func background(in frame: CGRect, of image: CGImage, scale: CGFloat) -> MeasuredContrast.RGB? {
            let pixelFrame = CGRect(
                x: frame.minX * scale, y: frame.minY * scale, width: frame.width * scale, height: frame.height * scale
            ).integral.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
            guard !pixelFrame.isEmpty, let crop = image.cropping(to: pixelFrame),
                let space = CGColorSpace(name: CGColorSpace.sRGB),
                let context = CGContext(
                    data: nil, width: crop.width, height: crop.height, bitsPerComponent: 8,
                    bytesPerRow: crop.width * 4, space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
            else { return nil }
            context.draw(crop, in: CGRect(x: 0, y: 0, width: crop.width, height: crop.height))
            guard let data = context.data else { return nil }
            let count = crop.width * crop.height
            let pixels = data.bindMemory(to: UInt8.self, capacity: count * 4)
            var counts: [UInt32: Int] = [:]
            for pixel in 0..<count {
                let key =
                    UInt32(pixels[pixel * 4]) << 16 | UInt32(pixels[pixel * 4 + 1]) << 8
                    | UInt32(pixels[pixel * 4 + 2])
                counts[key, default: 0] += 1
            }
            guard let key = counts.max(by: { $0.value < $1.value })?.key else { return nil }
            return .init(red: UInt8(key >> 16 & 0xFF), green: UInt8(key >> 8 & 0xFF), blue: UInt8(key & 0xFF))
        }
    #endif
}
