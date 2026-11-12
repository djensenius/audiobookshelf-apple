import ABSCore
import CoreGraphics
import Foundation
import Synchronization
import Testing

@testable import ABSUI

@Suite struct CoverPaletteTests {
    private let key = ImageKey(serverID: UUID(), kind: .itemCover, entityID: "li_1", updatedAt: 1)

    /// An opaque 8 × 8 image whose left and right halves have these colours.
    private static func image(
        left: (UInt8, UInt8, UInt8), right: (UInt8, UInt8, UInt8)? = nil, space: CFString = CGColorSpace.sRGB
    ) throws -> CGImage {
        let side = 8
        var pixels = [UInt8]()
        for _ in 0..<side {
            for x in 0..<side {
                let (r, g, b) = x < side / 2 ? left : (right ?? left)
                pixels += [r, g, b, 255]
            }
        }
        let provider = try #require(CGDataProvider(data: Data(pixels) as CFData))
        let space = try #require(CGColorSpace(name: space))
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

    @Test func displayP3CoverIsConvertedToSRGB() throws {
        let image = try Self.image(left: (204, 102, 51), space: CGColorSpace.displayP3)
        let p3Space = try #require(CGColorSpace(name: CGColorSpace.displayP3))
        let sRGBSpace = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let p3 = try #require(CGColor(colorSpace: p3Space, components: [0.8, 0.4, 0.2, 1]))
        let converted = p3.converted(to: sRGBSpace, intent: .defaultIntent, options: nil)
        let srgb = try #require(converted?.components)
        let expected = (Double(srgb[0]) * 255, Double(srgb[1]) * 255, Double(srgb[2]) * 255)
        // Far enough from the P3 values that reading them unconverted fails.
        #expect(abs(expected.0 - 204) > 5)
        expect(try #require(CoverPalette.averageColor(of: image)), expected)
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

    @Test func concurrentCallersShareOneLoad() async throws {
        let loads = Mutex(0)
        let released = Mutex(false)
        let image = try Self.image(left: (90, 90, 90))
        let palette = CoverPalette { _ in
            loads.withLock { $0 += 1 }
            while !released.withLock({ $0 }) { try await Task.sleep(for: .milliseconds(1)) }
            return image
        }
        let first = Task { await palette.color(for: key) }
        while loads.withLock({ $0 }) == 0 { await Task.yield() }
        let second = Task { await palette.color(for: key.with(bucket: .large)) }
        // A second load would start within this window.
        try await Task.sleep(for: .milliseconds(200))
        released.withLock { $0 = true }
        #expect(await first.value == second.value)
        #expect(loads.withLock { $0 } == 1)
    }

    @Test func cacheKeepsAtMostItsCapacity() async throws {
        let image = try Self.image(left: (10, 20, 30))
        let palette = CoverPalette(capacity: 2) { _ in image }
        let keys = (1...3).map {
            ImageKey(serverID: key.serverID, kind: .itemCover, entityID: "li_\($0)", updatedAt: 1)
        }
        for key in keys { _ = await palette.color(for: key) }
        #expect(keys.filter { palette.cachedColor(for: $0) != nil }.count == 2)
        #expect(palette.cachedColor(for: keys[2]) != nil)
    }
}
