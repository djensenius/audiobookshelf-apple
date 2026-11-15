import CoreGraphics
import XCTest

/// ``MeasuredContrast`` on drawn images, without launching the app: text strokes, three pixels
/// wide every 15, over one background or two. #641
final class MeasuredContrastTests: XCTestCase {
    private typealias RGB = MeasuredContrast.RGB

    private static let glassText = RGB(red: 214, green: 218, blue: 222)
    private static let white = RGB(red: 255, green: 255, blue: 255)

    /// (a) Text over a dark and a lighter half of the glass, which together pass frame-wide (a
    /// crop of about 45% each and 10% text measures 11.6:1 between its percentiles): measured
    /// against the lighter half, where it's 3.1:1, it fails.
    func testTextOnNonuniformGlassMeasuresAgainstItsLocalBackground() throws {
        let image = try XCTUnwrap(Self.image(text: Self.glassText, backgrounds: [.grey(32), .grey(120)]))
        let ratio = try XCTUnwrap(MeasuredContrast.ratio(in: Self.frame, of: image, scale: 1, text: Self.glassText))
        XCTAssertLessThan(ratio, 3.2)
    }

    /// (b) The mini player's author on the dark glass on the iPhone Duo, 5.9:1.
    func testMutedTextOnDarkGlass() throws {
        let image = try XCTUnwrap(
            Self.image(text: Self.glassText, backgrounds: [RGB(red: 78, green: 79, blue: 79)]))
        let ratio = try XCTUnwrap(MeasuredContrast.ratio(in: Self.frame, of: image, scale: 1, text: Self.glassText))
        XCTAssertEqual(ratio, 5.9, accuracy: 0.1)
    }

    /// (c) The mini player's title on the black theme's glass, 16.3:1.
    func testWhiteTextOnBlackGlass() throws {
        let image = try XCTUnwrap(Self.image(text: Self.white, backgrounds: [.grey(32)]))
        let ratio = try XCTUnwrap(MeasuredContrast.ratio(in: Self.frame, of: image, scale: 1, text: Self.white))
        XCTAssertEqual(ratio, 16.3, accuracy: 0.1)
    }

    /// (d) No text, or a frame too small to find any: not measured, so the issue isn't filtered.
    func testNoTextOrATinyFrameIsNotMeasured() throws {
        let glass = RGB(red: 78, green: 79, blue: 79)
        let blank = try XCTUnwrap(Self.image(text: nil, backgrounds: [glass]))
        XCTAssertNil(MeasuredContrast.ratio(in: Self.frame, of: blank, scale: 1, text: Self.glassText))
        let text = try XCTUnwrap(Self.image(text: Self.glassText, backgrounds: [glass]))
        let tiny = CGRect(x: 10, y: 10, width: 2, height: 2)
        XCTAssertNil(MeasuredContrast.ratio(in: tiny, of: text, scale: 1, text: Self.glassText))
        XCTAssertNil(MeasuredContrast.ratio(in: tiny, of: text, scale: 3, text: Self.glassText))
    }

    /// (e) Text over mid-grey glass with a narrow dark strip down its left edge: over the grey,
    /// where most of it is, it's 2.4:1.
    func testTextBesideADarkStripMeasuresAgainstTheGrey() throws {
        let image = try XCTUnwrap(
            Self.image(
                text: Self.glassText, backgrounds: [.grey(140)],
                patch: (CGRect(x: 0, y: 0, width: 15, height: Self.size.height), .grey(32))))
        let ratio = try XCTUnwrap(MeasuredContrast.ratio(in: Self.frame, of: image, scale: 1, text: Self.glassText))
        XCTAssertEqual(ratio, 2.4, accuracy: 0.1)
    }

    /// (g) Text on grey glass with a white highlight across the frame, near the strokes' ends: the
    /// highlight isn't the text's colour, so the strokes are measured, 3.6:1, not the highlight.
    func testABackgroundHighlightIsNotTakenForText() throws {
        let image = try XCTUnwrap(
            Self.image(
                text: Self.glassText, backgrounds: [.grey(110)],
                patch: (CGRect(x: 0, y: 3, width: Self.size.width, height: 4), Self.white)))
        let ratio = try XCTUnwrap(MeasuredContrast.ratio(in: Self.frame, of: image, scale: 1, text: Self.glassText))
        XCTAssertEqual(ratio, 3.6, accuracy: 0.1)
    }

    /// (h) A patch of background nearly the text's colour under half the strokes: its pixels
    /// match the text's colour but have no background to measure, so it's not measured, rather
    /// than passing on the other half.
    func testAPatchInTheTextsColourIsNotMeasured() throws {
        let image = try XCTUnwrap(
            Self.image(
                text: Self.glassText, backgrounds: [RGB(red: 78, green: 79, blue: 79)],
                patch: (CGRect(x: 150, y: 10, width: 150, height: 40), RGB(red: 210, green: 214, blue: 218))))
        XCTAssertNil(MeasuredContrast.ratio(in: Self.frame, of: image, scale: 1, text: Self.glassText))
    }

    /// (i) Text not in the colour expected, as when the app's colour changes and the test's
    /// doesn't: not measured.
    func testTextNotInTheExpectedColourIsNotMeasured() throws {
        let image = try XCTUnwrap(
            Self.image(text: Self.glassText, backgrounds: [RGB(red: 78, green: 79, blue: 79)]))
        XCTAssertNil(MeasuredContrast.ratio(in: Self.frame, of: image, scale: 1, text: Self.white))
    }

    private static let size = (width: 300, height: 60)
    private static let frame = CGRect(x: 0, y: 0, width: size.width, height: size.height)

    /// The backgrounds side by side, left to right, then `patch` over them, under vertical text
    /// strokes, rows 10 to 50, three pixels wide every 15 (about 13% of the image), or none.
    private static func image(text: RGB?, backgrounds: [RGB], patch: (CGRect, RGB)? = nil) -> CGImage? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
            let context = CGContext(
                data: nil, width: size.width, height: size.height, bitsPerComponent: 8,
                bytesPerRow: size.width * 4, space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        let part = size.width / backgrounds.count
        for (index, background) in backgrounds.enumerated() {
            context.setFillColor(color(background))
            context.fill(CGRect(x: index * part, y: 0, width: part, height: size.height))
        }
        if let (rect, color) = patch {
            context.setFillColor(Self.color(color))
            context.fill(rect)
        }
        if let text {
            context.setFillColor(color(text))
            for x in stride(from: 6, to: size.width - 3, by: 15) {
                context.fill(CGRect(x: x, y: 10, width: 3, height: 40))
            }
        }
        return context.makeImage()
    }

    private static func color(_ rgb: RGB) -> CGColor {
        CGColor(
            srgbRed: CGFloat(rgb.red) / 255, green: CGFloat(rgb.green) / 255, blue: CGFloat(rgb.blue) / 255, alpha: 1)
    }
}

extension MeasuredContrast.RGB {
    fileprivate static func grey(_ value: UInt8) -> Self { Self(red: value, green: value, blue: value) }
}
