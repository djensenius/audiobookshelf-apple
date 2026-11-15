import CoreGraphics
import XCTest

/// ``MeasuredContrast`` on drawn images, without launching the app: text strokes, three pixels
/// wide every 15, over one background or two. #641
final class MeasuredContrastTests: XCTestCase {
    private typealias RGB = (red: UInt8, green: UInt8, blue: UInt8)

    private static let glassText: RGB = (214, 218, 222)

    /// Text over a dark and a lighter half of the glass, which together pass frame-wide (a crop
    /// of about 45% each and 10% text measures 11.6:1 between its percentiles): measured against
    /// the lighter half, where it's 3.1:1, it fails.
    func testTextOnNonuniformGlassMeasuresAgainstItsLocalBackground() throws {
        let image = try XCTUnwrap(
            Self.image(text: Self.glassText, backgrounds: [(32, 32, 32), (120, 120, 120)]))
        let ratio = try XCTUnwrap(MeasuredContrast.ratio(in: Self.frame, of: image, scale: 1))
        XCTAssertLessThan(ratio, 3.2)
        XCTAssertLessThan(ratio, 4.5)
    }

    /// The mini player's author on the dark glass on the iPhone Duo, 5.9:1.
    func testMutedTextOnDarkGlass() throws {
        let image = try XCTUnwrap(Self.image(text: Self.glassText, backgrounds: [(78, 79, 79)]))
        let ratio = try XCTUnwrap(MeasuredContrast.ratio(in: Self.frame, of: image, scale: 1))
        XCTAssertEqual(ratio, 5.9, accuracy: 0.1)
    }

    /// The mini player's title on the black theme's glass, 16.3:1.
    func testWhiteTextOnBlackGlass() throws {
        let image = try XCTUnwrap(Self.image(text: (255, 255, 255), backgrounds: [(32, 32, 32)]))
        let ratio = try XCTUnwrap(MeasuredContrast.ratio(in: Self.frame, of: image, scale: 1))
        XCTAssertEqual(ratio, 16.3, accuracy: 0.1)
    }

    /// No text, or a frame too small to find any: not measured, so the issue isn't filtered.
    func testNoTextOrATinyFrameIsNotMeasured() throws {
        let blank = try XCTUnwrap(Self.image(text: nil, backgrounds: [(78, 79, 79)]))
        XCTAssertNil(MeasuredContrast.ratio(in: Self.frame, of: blank, scale: 1))
        let text = try XCTUnwrap(Self.image(text: Self.glassText, backgrounds: [(78, 79, 79)]))
        XCTAssertNil(MeasuredContrast.ratio(in: CGRect(x: 10, y: 10, width: 2, height: 2), of: text, scale: 1))
        XCTAssertNil(MeasuredContrast.ratio(in: CGRect(x: 10, y: 10, width: 2, height: 2), of: text, scale: 3))
    }

    private static let size = (width: 300, height: 60)
    private static let frame = CGRect(x: 0, y: 0, width: size.width, height: size.height)

    /// The backgrounds side by side, left to right, under vertical text strokes, rows 10 to 50,
    /// three pixels wide every 15 (about 13% of the image), or none.
    private static func image(text: RGB?, backgrounds: [RGB]) -> CGImage? {
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
