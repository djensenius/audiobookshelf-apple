import ABSCore
import CoreGraphics
import Foundation
import Synchronization
import Testing

@testable import ABSUI

@Suite struct CoverPaletteTests {
    private let key = ImageKey(serverID: UUID(), kind: .itemCover, entityID: "li_1", updatedAt: 1)

    /// An opaque 8 × 8 sRGB image whose left and right halves have these colours.
    private static func image(left: (UInt8, UInt8, UInt8), right: (UInt8, UInt8, UInt8)? = nil) throws -> CGImage {
        let side = 8
        var pixels = [UInt8]()
        for _ in 0..<side {
            for x in 0..<side {
                let (r, g, b) = x < side / 2 ? left : (right ?? left)
                pixels += [r, g, b, 255]
            }
        }
        let provider = try #require(CGDataProvider(data: Data(pixels) as CFData))
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        return try #require(
            CGImage(
                width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: side * 4,
                space: space,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue), provider: provider,
                decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    }

    private func expect(_ color: CoverColor, _ rgb: (Double, Double, Double)) {
        #expect(abs(color.red * 255 - rgb.0) <= 1, "red \(color.red * 255)")
        #expect(abs(color.green * 255 - rgb.1) <= 1, "green \(color.green * 255)")
        #expect(abs(color.blue * 255 - rgb.2) <= 1, "blue \(color.blue * 255)")
    }

    @Test func solidCoverAveragesToItsColour() throws {
        expect(try #require(CoverPalette.averageColor(of: Self.image(left: (200, 100, 50)))), (200, 100, 50))
    }

    @Test func averageIsTheMeanOfTheEncodedValues() throws {
        let image = try Self.image(left: (0, 0, 0), right: (255, 255, 255))
        // Averaging linear light would give about 188.
        expect(try #require(CoverPalette.averageColor(of: image)), (127.5, 127.5, 127.5))
    }

    @Test func lightnessFollowsRelativeLuminance() {
        #expect(CoverColor(red: 1, green: 1, blue: 1).isLight)
        #expect(CoverColor(red: 1, green: 1, blue: 0).isLight)
        #expect(!CoverColor(red: 0, green: 0, blue: 1).isLight)
        #expect(!CoverColor.fallback.isLight)
        // Mid grey is light by luminance (0.216), though 50 % in sRGB.
        #expect(CoverColor(red: 0.5, green: 0.5, blue: 0.5).isLight)
        #expect(!CoverColor(red: 0.45, green: 0.45, blue: 0.45).isLight)
    }

    @Test func colourIsCachedPerKeyWhateverTheBucket() async throws {
        let loads = Mutex<[ImageKey]>([])
        let image = try Self.image(left: (10, 200, 30))
        let palette = CoverPalette { key in
            loads.withLock { $0.append(key) }
            return image
        }
        #expect(palette.cachedColor(for: key) == nil)

        let first = await palette.color(for: key.with(bucket: .large))
        let second = await palette.color(for: key)
        expect(first, (10, 200, 30))
        #expect(second == first)
        #expect(palette.cachedColor(for: key.with(bucket: .medium)) == first)
        #expect(loads.withLock { $0 } == [key.with(bucket: .small)])

        var newer = key
        newer.updatedAt = 2
        _ = await palette.color(for: newer)
        #expect(loads.withLock { $0.count } == 2)
    }

    @Test func failedLoadGivesTheFallbackAndIsRetried() async throws {
        let fails = Mutex(true)
        let image = try Self.image(left: (240, 240, 240))
        let palette = CoverPalette { _ in
            if fails.withLock({ $0 }) { throw URLError(.notConnectedToInternet) }
            return image
        }

        #expect(await palette.color(for: key) == .fallback)
        #expect(palette.cachedColor(for: key) == nil)
        fails.withLock { $0 = false }
        let color = await palette.color(for: key)
        expect(color, (240, 240, 240))
        #expect(color.isLight)
    }
}
