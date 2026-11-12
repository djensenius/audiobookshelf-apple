import ABSCore
import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI
import Synchronization

/// A cover's average colour, for the player's background (ADR 0005).
public struct CoverColor: Sendable, Hashable {
    /// sRGB components from 0 to 1.
    public var red: Double
    public var green: Double
    public var blue: Double

    public init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    /// The legacy app's `rgb(55, 56, 56)`, for covers that can't be loaded.
    public static let fallback = CoverColor(red: 55 / 255, green: 56 / 255, blue: 56 / 255)

    public var color: Color { Color(.sRGB, red: red, green: green, blue: blue) }

    /// Whether dark text reads better on this colour than light text: its WCAG relative
    /// luminance is above 0.179, where the contrast with black and with white is equal.
    public var isLight: Bool { relativeLuminance > 0.179 }

    var relativeLuminance: Double {
        func linear(_ value: Double) -> Double {
            value <= 0.040_45 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }
}

/// Average cover colours, cached per ``ImageKey`` whatever its width bucket. Computed with
/// `CIAreaAverage` on the 300-pixel bucket, a simple mean of the sRGB-encoded values as in the
/// legacy app.
public final class CoverPalette: Sendable {
    private struct State {
        var colors: [ImageKey: CoverColor] = [:]
        /// Averages in progress, which concurrent callers for the same key share.
        var loads: [ImageKey: Task<CoverColor?, Never>] = [:]
    }

    private let state = Mutex(State())
    private let load: @Sendable (ImageKey) async throws -> CGImage
    private let capacity: Int

    public convenience init(pipeline: ImagePipeline) {
        self.init { key in try await pipeline.cgImage(for: key, size: CGSize(width: 64, height: 64)) }
    }

    /// - Parameter capacity: the most colours kept; one is dropped to make room for another.
    init(capacity: Int = 1_000, load: @escaping @Sendable (ImageKey) async throws -> CGImage) {
        self.capacity = capacity
        self.load = load
    }

    /// The colour already computed for `key`, without loading anything, for a view's first frame.
    public func cachedColor(for key: ImageKey) -> CoverColor? {
        state.withLock { $0.colors[key.with(bucket: .small)] }
    }

    /// The average colour of `key`'s cover, or ``CoverColor/fallback`` if it can't be loaded.
    /// The fallback isn't cached, so a later call tries again.
    public func color(for key: ImageKey) async -> CoverColor {
        let key = key.with(bucket: .small)
        let (cached, task) = state.withLock { state -> (CoverColor?, Task<CoverColor?, Never>?) in
            if let color = state.colors[key] { return (color, nil) }
            if let task = state.loads[key] { return (nil, task) }
            let task = Task { [load] in (try? await load(key)).flatMap(Self.averageColor) }
            state.loads[key] = task
            return (nil, task)
        }
        guard let task else { return cached ?? .fallback }
        let color = await task.value
        state.withLock { state in
            guard state.loads[key] == task else { return }
            state.loads[key] = nil
            guard let color else { return }
            if state.colors.count >= capacity, state.colors[key] == nil {
                state.colors.remove(at: state.colors.startIndex)
            }
            state.colors[key] = color
        }
        return color ?? .fallback
    }

    private static let sRGB = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    /// Thread-safe, and costly to create.
    private static let context = CIContext(options: [.workingColorSpace: sRGB])

    static func averageColor(of image: CGImage) -> CoverColor? {
        let input = CIImage(cgImage: image)
        let filter = CIFilter.areaAverage()
        filter.inputImage = input
        filter.extent = input.extent
        guard let output = filter.outputImage else { return nil }
        // An sRGB working space: other spaces such as Display P3 are converted, but the values
        // stay encoded rather than linear light.
        var pixel = [UInt8](repeating: 0, count: 4)
        context.render(
            output, toBitmap: &pixel, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBA8,
            colorSpace: sRGB)
        return CoverColor(red: Double(pixel[0]) / 255, green: Double(pixel[1]) / 255, blue: Double(pixel[2]) / 255)
    }
}
