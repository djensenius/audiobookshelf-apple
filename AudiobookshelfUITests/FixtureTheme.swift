import XCTest

/// A dark app theme a fixture launch can force with `-ABSTheme` (`FixtureServer.themeArgument`),
/// so audits cover dark mode on a simulator in light mode: a newly created simulator, as on CI,
/// ignores appearance changes until it's rebooted. #641
enum FixtureTheme: String {
    case dark, black

    /// The launch arguments that set the theme.
    var launchArguments: [String] { ["-ABSTheme", rawValue] }
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

/// The contrast of a screenshot's pixels, for a contrast issue the audit reports on text whose
/// pixels pass. #641
enum MeasuredContrast {
    /// The WCAG contrast ratio, from 1 to 21, between the 5th and 95th percentile relative
    /// luminance of `screenshot`'s pixels in `frame` (in points): the background and the text's
    /// strokes. `nil` if the frame is empty or the screenshot can't be read.
    static func ratio(in frame: CGRect, of screenshot: XCUIScreenshot) -> Double? {
        #if os(macOS)
            let image = screenshot.image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        #else
            let image = screenshot.image.cgImage
        #endif
        guard let image, screenshot.image.size.width > 0 else { return nil }
        let scale = CGFloat(image.width) / screenshot.image.size.width
        let pixelFrame = CGRect(
            x: frame.minX * scale, y: frame.minY * scale, width: frame.width * scale, height: frame.height * scale
        ).integral.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard !pixelFrame.isEmpty, let crop = image.cropping(to: pixelFrame),
            let space = CGColorSpace(name: CGColorSpace.sRGB),
            let context = CGContext(
                data: nil, width: crop.width, height: crop.height, bitsPerComponent: 8, bytesPerRow: crop.width * 4,
                space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        context.draw(crop, in: CGRect(x: 0, y: 0, width: crop.width, height: crop.height))
        guard let data = context.data else { return nil }
        let count = crop.width * crop.height
        let pixels = data.bindMemory(to: UInt8.self, capacity: count * 4)
        let luminances = (0..<count).map { pixel in
            0.2126 * linear(pixels[pixel * 4]) + 0.7152 * linear(pixels[pixel * 4 + 1])
                + 0.0722 * linear(pixels[pixel * 4 + 2])
        }.sorted()
        let dark = luminances[count * 5 / 100]
        let light = luminances[min(count - 1, count * 95 / 100)]
        return (light + 0.05) / (dark + 0.05)
    }

    /// An sRGB channel's linear value, from 0 to 1.
    private static func linear(_ channel: UInt8) -> Double {
        let value = Double(channel) / 255
        return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
    }
}
