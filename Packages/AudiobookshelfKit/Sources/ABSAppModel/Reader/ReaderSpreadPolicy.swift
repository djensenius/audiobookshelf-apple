import CoreGraphics
import Foundation

/// The reader's `spread` setting (ADR 0008, decision 6), as the legacy app and the EPUB bridge
/// spell it.
public enum ReaderSpreadSetting: String, Sendable, Hashable, CaseIterable {
    /// Two pages when the layout is wide enough (``ReaderSpreadPolicy``).
    case auto
    /// Always one page.
    case none
}

/// The platform a reader lays out for. Size classes describe the window only on iOS and iPadOS.
public enum ReaderPlatform: Sendable, Hashable {
    case iOS
    case macOS
}

/// The horizontal size class, without SwiftUI, so the policy runs under `swift test`.
public enum ReaderSizeClass: Sendable, Hashable {
    case compact
    case regular
}

/// How many pages a reader shows side by side.
public enum ReaderSpreadLayout: Sendable, Hashable {
    case single
    /// Two pages, `gap` points apart. A gap of `0` leaves the spacing to the renderer (the EPUB
    /// bridge's `gap` field); on a spanned Duo it is the hinge's width, so nothing falls in the
    /// fold.
    case twoUp(gap: CGFloat)

    public var isTwoUp: Bool {
        if case .twoUp = self { true } else { false }
    }
}

/// Whether a reader shows one page or a two-page spread (ADR 0008, decision 7). PDF, EPUB and
/// comics share it, so every format spreads under the same rule.
public enum ReaderSpreadPolicy {
    /// The narrowest Mac reader that shows a spread, epub.js's `minSpreadWidth`.
    public static let minimumMacSpreadWidth: CGFloat = 800

    /// - Parameters:
    ///   - setting: The reader's `spread` setting. ``ReaderSpreadSetting/none`` always gives a
    ///     single page.
    ///   - platform: macOS ignores `sizeClass`, which doesn't describe a Mac window.
    ///   - sizeClass: The horizontal size class on iOS; `nil` counts as compact.
    ///   - size: The reader area, as measured with `onGeometryChange`.
    ///   - hingeWidth: The width of the hinge's reserved region while an iPhone Duo is spanned
    ///     across it, or `nil` when it isn't (folded, or not a Duo). A spanned Duo spreads with
    ///     one page on each side whatever its size class says.
    public static func layout(
        setting: ReaderSpreadSetting, platform: ReaderPlatform, sizeClass: ReaderSizeClass?, size: CGSize,
        hingeWidth: CGFloat?
    ) -> ReaderSpreadLayout {
        let width = size.width
        let height = size.height
        // A reader that isn't measured yet shows one page, even on a spanned Duo.
        guard setting == .auto, width.isFinite, height.isFinite, width > 0, height > 0 else { return .single }
        // Checked before the shape: a spanned Duo is taller than wide and still spreads.
        if platform == .iOS, let hingeWidth, hingeWidth.isFinite, hingeWidth > 0 {
            return .twoUp(gap: hingeWidth)
        }
        // Strictly wider than tall: a square reader shows one page.
        guard width > height else { return .single }
        switch platform {
        case .iOS:
            return sizeClass == .regular ? .twoUp(gap: 0) : .single
        case .macOS:
            return width >= minimumMacSpreadWidth ? .twoUp(gap: 0) : .single
        }
    }
}
