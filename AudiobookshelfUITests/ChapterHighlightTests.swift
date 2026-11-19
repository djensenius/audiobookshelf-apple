import XCTest

/// The chapter list's current-chapter highlight (#705), on iOS: the details pane beside the
/// landscape player on an iPad from iOS 27.1, and the chapters sheet elsewhere. The accessibility
/// audits can't catch a missing tint: the row stays readable without it. On an iPhone, also the
/// list's header on the sheet's glass, which no audit walk reaches.
final class ChapterHighlightTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    #if os(iOS)
        /// How far apart the current row's background and another row's must be, in the largest
        /// difference of a channel (0 to 255). The light accent at 20% is 59 from white.
        private static let minimumTint = 20

        /// The light theme and the default text size (Large), whatever the simulator's appearance and
        /// text size: the test measures the times in black, and reads the default rows.
        private static let launchArguments = [
            "-ABSTheme", "light", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryL",
        ]

        /// `ABSColor.mutedForegroundOnGlass` in light (ABSUI), the chapter list's header colour. If the
        /// app's colour changes and this doesn't, too few pixels match and the measurement is `nil`.
        private static let headerText = MeasuredContrast.RGB(red: 71, green: 78, blue: 86)

        /// At the Chapters sheet's medium detent, as it opens on an iPhone in portrait, the list is on
        /// glass over the player. In the light theme at the default text size (`launchArguments`) the
        /// header's Start and Duration measure 4.5:1 or more against the glass around them. The margin
        /// is thin on an iPhone 17, 4.68:1 and 5.20:1, while CI's iPhone Duo reads 5.49:1 and 5.83:1,
        /// so a local failure just under 4.5:1 may be the glass's rendering, not a regression; with
        /// `mutedForeground`, Start read 3.5:1 on the iPhone 17 and 3.9:1 on the Duo. The sheet must be
        /// at its medium detent: at the large detent the list is opaque, and `mutedForeground` passes
        /// there too. Not the header's "Chapters", in the same colour: it's semibold, and around its
        /// wider strokes `MeasuredContrast` takes the glyphs' own anti-aliased edges for the
        /// background, reading 3.8:1 for a colour 6.5:1 against the glass past them. It turns the
        /// iPhone to portrait, and back afterwards if it was in portrait or landscape: a fresh runner
        /// reports `.unknown`, which can't be set. Skipped on an iPad, where from iOS 27.1 the list is
        /// a sheet only in portrait.
        @MainActor
        func testHeaderIsReadableOnGlass() throws {
            try XCTSkipIf(UIDevice.current.userInterfaceIdiom == .pad, "Measured on an iPhone's sheet")
            let initial = XCUIDevice.shared.orientation
            if initial.isPortrait || initial.isLandscape {
                addTeardownBlock { @MainActor in XCUIDevice.shared.orientation = initial }
            }
            XCUIDevice.shared.orientation = .portrait
            let app = signIn(launchArguments: Self.launchArguments)
            open(.player, in: app)
            let bar = openChaptersSheet(in: app)
            let rows = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Chapter "))
            let first = rows.firstMatch
            XCTAssertTrue(first.waitForExistence(timeout: Self.fixtureTimeout), "The chapter list has no rows")
            var frame = CGRect.null
            XCTAssertTrue(
                wait(
                    for: {
                        defer { frame = first.frame }
                        return first.frame == frame
                    }, timeout: Self.fixtureTimeout),
                "The chapter list didn't settle")

            let screenshot = XCUIScreen.main.screenshot()
            let attachment = XCTAttachment(screenshot: screenshot)
            attachment.name = "chapters-medium-detent"
            add(attachment)
            // The sheet's navigation bar is its top: about halfway down at the medium detent, near the
            // window's top at the large one.
            let window = app.windows.firstMatch.frame
            XCTAssertGreaterThan(
                bar.frame.minY, window.height * 0.25,
                "The chapters sheet isn't at its medium detent: its top is at \(bar.frame.minY) of \(window.height)")
            let image = try XCTUnwrap(Self.upright(screenshot), "Couldn't read the screenshot")
            let scale = CGFloat(image.width) / window.width
            // The header is the text right above the first row, in its column: the navigation
            // title and the player's own Duration, under the sheet, have the same labels.
            for label in ["Start", "Duration"] {
                let header = app.staticTexts.matching(NSPredicate(format: "label == %@", label))
                    .allElementsBoundByIndex.map(\.frame)
                    .filter { $0.maxY <= frame.minY + 1 && $0.maxX > frame.minX && $0.minX < frame.maxX }
                    .max { $0.maxY < $1.maxY }
                let found = try XCTUnwrap(header, "The chapter list's header has no '\(label)'")
                let ratio = MeasuredContrast.ratio(in: found, of: image, scale: scale, text: Self.headerText)
                XCTAssertGreaterThanOrEqual(
                    ratio ?? 0, 4.5,
                    "The header's '\(label)' isn't 4.5:1 on the sheet's glass: \(String(describing: ratio))")
            }
        }

        /// In the light theme at the default text size (`launchArguments`), the current chapter's row
        /// is tinted, unlike the others, and its times are readable on the tint: drawn in the primary
        /// colour, black, they're at least 4.5:1. The fixture's *Pride and Prejudice* plays from
        /// Chapter 1 and has a second chapter.
        @MainActor
        func testCurrentChapterIsTinted() throws {
            let app = signIn(launchArguments: Self.launchArguments)
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

        /// Shows the chapter list: on an iPad from iOS 27.1, turned to landscape, the details pane
        /// beside the player (turned back afterwards if it was in portrait or landscape; a fresh
        /// runner reports `.unknown`, which can't be set); elsewhere, the chapters sheet at its large
        /// detent, where it's opaque, not glass over the player. A vertical bar (the iPhone Duo's
        /// outer display) has the Chapters button in its overflow menu, found by symbol as in
        /// `open(.bookmarks, in:)`.
        @MainActor
        private func showChapters(in app: XCUIApplication) {
            // The player has arrangements, and so the details pane, from iOS 27.1, as in `NowPlayingView`.
            if UIDevice.current.userInterfaceIdiom == .pad, #available(iOS 27.1, *) {
                let initial = XCUIDevice.shared.orientation
                if initial.isPortrait || initial.isLandscape {
                    addTeardownBlock { @MainActor in XCUIDevice.shared.orientation = initial }
                }
                XCUIDevice.shared.orientation = .landscapeLeft
                return
            }
            let bar = openChaptersSheet(in: app)
            bar.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.5)).press(
                forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.05)))
        }

        /// Opens the Chapters sheet, at its medium detent, and returns its navigation bar.
        @MainActor
        @discardableResult
        private func openChaptersSheet(in app: XCUIApplication) -> XCUIElement {
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
            return bar
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
