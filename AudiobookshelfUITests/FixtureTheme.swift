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
