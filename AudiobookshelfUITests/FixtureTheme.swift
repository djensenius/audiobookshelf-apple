import XCTest

/// A dark app theme a fixture launch can force with `-ABSTheme` (`FixtureServer.themeArgument`),
/// so audits cover dark mode on a simulator in light mode: a newly created simulator, as on CI,
/// ignores appearance changes until it's rebooted. #641
enum FixtureTheme: String {
    case dark, black

    /// The launch arguments that set the theme.
    var launchArguments: [String] { ["-ABSTheme", rawValue] }

    /// The theme `arguments` launch with, if one of these.
    init?(launchArguments arguments: [String]) {
        guard let index = arguments.lastIndex(of: "-ABSTheme"), index + 1 < arguments.endIndex else { return nil }
        self.init(rawValue: arguments[index + 1])
    }

    /// The colour the mini player draws its title in for `theme` (`nil`: the light appearance a new
    /// simulator has): SwiftUI's primary label, white in dark and black in light. #698
    static func miniPlayerTitle(_ theme: FixtureTheme?) -> MeasuredContrast.RGB {
        theme == nil ? .init(red: 0, green: 0, blue: 0) : .init(red: 255, green: 255, blue: 255)
    }

    /// The colour the mini player draws its author in for `theme` (`nil`: light): mirrors
    /// `ABSColor.mutedForegroundOnGlass` (ABSUI), the same in dark and black. If the app's colour
    /// changes and this doesn't, too few pixels match, the measurement is `nil` and the audit issue
    /// fails, unfiltered. #698
    static func miniPlayerSecondaryText(_ theme: FixtureTheme?) -> MeasuredContrast.RGB {
        theme == nil ? .init(red: 91, green: 99, blue: 108) : .init(red: 214, green: 218, blue: 222)
    }

    /// The colour the Player draws its elapsed and remaining times in for `theme` (`nil`: the light
    /// appearance a new simulator has): mirrors `ABSColor.mutedForeground` (ABSUI). If the app's
    /// colour changes and this doesn't, the measurement is `nil` and the audit issue fails. #653
    static func playerTimes(_ theme: FixtureTheme?) -> MeasuredContrast.RGB {
        theme == nil ? .init(red: 91, green: 99, blue: 108) : .init(red: 156, green: 161, blue: 167)
    }
}

extension XCTestCase {
    /// Fails unless `screen` shows dark, so a dark pass can't quietly audit light mode: most of the
    /// screenshot (over half its pixels) must be dark, under half brightness. A light cover, such
    /// as Item detail's and the Player's, is a quarter of the screen at most. The screenshot is
    /// attached when it fails.
    @MainActor
    func assertAppearance(of screen: FixtureScreen, _ theme: FixtureTheme, in app: XCUIApplication) {
        let screenshot = app.screenshot()
        guard let dark = Self.darkFraction(of: screenshot) else {
            return XCTFail("\(screen.name): couldn't read the screenshot to check the \(theme.rawValue) theme")
        }
        guard dark <= 0.5 else { return }
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = "appearance-\(screen.rawValue)-\(theme.rawValue)"
        attachment.lifetime = .keepAlways
        add(attachment)
        XCTFail(
            "\(screen.name) isn't in the \(theme.rawValue) theme: \(Int(dark * 100))% of it is dark, not over half")
    }

    /// The fraction of `screenshot`'s pixels, scaled down to 32 by 32, whose mean channel is under
    /// half brightness.
    private static func darkFraction(of screenshot: XCUIScreenshot) -> Double? {
        #if os(macOS)
            let image = screenshot.image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        #else
            let image = screenshot.image.cgImage
        #endif
        let side = 32
        guard let image,
            let context = CGContext(
                data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        guard let data = context.data else { return nil }
        let pixels = data.bindMemory(to: UInt8.self, capacity: side * side * 4)
        let dark = (0..<(side * side)).count { pixel in
            Int(pixels[pixel * 4]) + Int(pixels[pixel * 4 + 1]) + Int(pixels[pixel * 4 + 2]) < 3 * 128
        }
        return Double(dark) / Double(side * side)
    }
}

/// The contrast of a screenshot's text against the background right around it, for a contrast
/// issue the audit reports on text whose pixels pass. #641
enum MeasuredContrast {
    /// An sRGB colour, 0 to 255 a channel.
    struct RGB: Equatable {
        var red: UInt8, green: UInt8, blue: UInt8

        /// Its relative luminance, from 0 to 1.
        var luminance: Double {
            0.2126 * MeasuredContrast.linear(red) + 0.7152 * MeasuredContrast.linear(green)
                + 0.0722 * MeasuredContrast.linear(blue)
        }
    }

    /// ``ratio(in:of:scale:text:)`` for `screenshot`'s image, at its scale.
    static func ratio(in frame: CGRect, of screenshot: XCUIScreenshot, text: RGB) -> Double? {
        #if os(macOS)
            let image = screenshot.image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        #else
            let image = screenshot.image.cgImage
        #endif
        guard let image, screenshot.image.size.width > 0 else { return nil }
        return ratio(in: frame, of: image, scale: CGFloat(image.width) / screenshot.image.size.width, text: text)
    }

    /// The WCAG contrast ratio, from 1 to 21, of the text in `frame` (in points, `scale` pixels
    /// each) against its local background, conservatively: the 10th percentile over the text's
    /// pixels. The text's pixels are those within 10% contrast of `text`, the colour the app draws
    /// it in, not guessed from the image; that colour only picks them out. Each pixel's own
    /// luminance, as drawn, is compared with the median luminance of the non-text pixels 2 to 4
    /// pixels away, which skips its anti-aliased edge, so text over a lighter patch of glass is
    /// measured against that patch. `nil`, so the issue isn't filtered, when that can't be
    /// established: a frame too small or unreadable, too few pixels in the text's colour, or over
    /// a quarter of them with too little background around them to measure (a patch of
    /// background in the text's colour isn't text that passes).
    static func ratio(in frame: CGRect, of image: CGImage, scale: CGFloat, text: RGB) -> Double? {
        guard let luminance = luminances(in: frame, of: image, scale: scale) else { return nil }
        let (values, width, height) = luminance
        let textLuminance = text.luminance
        let isText = values.map { contrast($0, textLuminance) <= 1.1 }
        let textPixels = isText.count { $0 }
        guard textPixels >= minimumTextPixels else { return nil }
        var ratios: [Double] = []
        var ring: [Double] = []
        for y in 0..<height {
            for x in 0..<width where isText[y * width + x] {
                ring.removeAll(keepingCapacity: true)
                for dy in -ringOuter...ringOuter {
                    for dx in -ringOuter...ringOuter where max(abs(dx), abs(dy)) >= ringInner {
                        let (nx, ny) = (x + dx, y + dy)
                        guard nx >= 0, nx < width, ny >= 0, ny < height, !isText[ny * width + nx] else { continue }
                        ring.append(values[ny * width + nx])
                    }
                }
                guard ring.count >= minimumRingSamples else { continue }
                ring.sort()
                ratios.append(contrast(values[y * width + x], ring[ring.count / 2]))
            }
        }
        let unmeasurable = textPixels - ratios.count
        guard ratios.count >= minimumTextPixels, Double(unmeasurable) <= maximumUnmeasurable * Double(textPixels)
        else { return nil }
        ratios.sort()
        return ratios[ratios.count / 10]
    }

    /// The ring around a text pixel the background is taken from, in pixels (Chebyshev distance).
    private static let ringInner = 2
    private static let ringOuter = 4
    /// Non-text pixels a text pixel's ring needs for its background to count.
    private static let minimumRingSamples = 8
    /// Pixels in the text's colour the frame needs, and text pixels with a background.
    private static let minimumTextPixels = 20
    /// The fraction of the text's pixels that may have too little background to measure. The
    /// mini player's real glyphs on the iPhone Duo have none. #641
    private static let maximumUnmeasurable = 0.25

    /// The relative luminance of `image`'s pixels in `frame` (in points), row by row, with the
    /// crop's width and height; `nil` if the crop is under 8 pixels either way or unreadable.
    private static func luminances(
        in frame: CGRect, of image: CGImage, scale: CGFloat
    ) -> (values: [Double], width: Int, height: Int)? {
        let pixelFrame = CGRect(
            x: frame.minX * scale, y: frame.minY * scale, width: frame.width * scale, height: frame.height * scale
        ).integral.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard pixelFrame.width >= 8, pixelFrame.height >= 8, let crop = image.cropping(to: pixelFrame),
            let space = CGColorSpace(name: CGColorSpace.sRGB),
            let context = CGContext(
                data: nil, width: crop.width, height: crop.height, bitsPerComponent: 8, bytesPerRow: crop.width * 4,
                space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        context.draw(crop, in: CGRect(x: 0, y: 0, width: crop.width, height: crop.height))
        guard let data = context.data else { return nil }
        let count = crop.width * crop.height
        let pixels = data.bindMemory(to: UInt8.self, capacity: count * 4)
        let values = (0..<count).map { pixel in
            0.2126 * linear(pixels[pixel * 4]) + 0.7152 * linear(pixels[pixel * 4 + 1])
                + 0.0722 * linear(pixels[pixel * 4 + 2])
        }
        return (values, crop.width, crop.height)
    }

    /// The WCAG contrast ratio of two relative luminances.
    private static func contrast(_ first: Double, _ second: Double) -> Double {
        (max(first, second) + 0.05) / (min(first, second) + 0.05)
    }

    /// An sRGB channel's linear value, from 0 to 1.
    private static func linear(_ channel: UInt8) -> Double {
        let value = Double(channel) / 255
        return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
    }
}
