import ABSCore
import SwiftUI

/// Semantic colours from the legacy `tailwind.css` palette, with light, dark and true-black
/// (``AppTheme/black``) variants.
///
/// The themed colours are ``ABSThemedColor`` shape styles that resolve from the view's
/// `colorScheme` and `absTheme` environment values, so set the theme with `absTheme(_:)`.
/// Presentations that don't inherit the environment (some sheets, new macOS windows) must
/// apply `absTheme(_:)` again.
public enum ABSColor {
    /// The app's accent colour from the app target's `AccentColor` asset.
    public static let accent = Color.accentColor

    /// Screen background (legacy `bg`).
    public static let background = ABSThemedColor(light: .rgb(255, 255, 255), dark: .rgb(56, 56, 56), black: .black)
    /// Bars, sheets and cards (legacy `primary`).
    public static let surface = ABSThemedColor(light: .rgb(222, 222, 222), dark: .rgb(35, 35, 35), black: .black)
    /// Grouped rows and inputs (legacy `secondary`).
    public static let secondarySurface = ABSThemedColor(
        light: .rgb(246, 248, 250), dark: .rgb(47, 48, 48), black: .black
    )
    /// Primary text (legacy `fg`).
    public static let foreground = ABSThemedColor(
        light: .rgb(37, 37, 37), dark: .rgb(230, 237, 243), black: .rgb(230, 237, 243)
    )
    /// Secondary text (legacy `fg-muted`). Light and dark are a little darker and lighter
    /// than legacy so the text meets the WCAG 4.5:1 minimum on every surface above. Black uses
    /// dark's, not legacy's `rgb(120, 126, 132)`, which is 3.5:1 on the full player's backdrop. #641
    public static let mutedForeground = ABSThemedColor(
        light: .rgb(91, 99, 108), dark: .rgb(156, 161, 167), black: .rgb(156, 161, 167)
    )
    /// Secondary text on Liquid Glass, such as the mini player's author: in dark mode the glass
    /// takes a lighter tint from the content under it, where ``mutedForeground`` measures 2.7:1;
    /// this is 5.1:1 there. #641 Also the chapter list's times: at the sheet's medium detent
    /// they're on glass over the player, darker in light, where ``mutedForeground`` measures 3.7:1
    /// in light and 3.5:1 in dark. #705
    public static let mutedForegroundOnGlass = ABSThemedColor(
        light: .rgb(71, 78, 86), dark: .rgb(214, 218, 222), black: .rgb(214, 218, 222)
    )
    /// Text and icons on an ``accent`` fill, such as a prominent button's label: white on the
    /// light accent (4.9:1), and dark on the dark accent, `rgb(79, 195, 204)`, where white is
    /// 2.1:1 (7.5:1). #641
    public static let onAccent = ABSThemedColor(
        light: .rgb(255, 255, 255), dark: .rgb(35, 35, 35), black: .rgb(35, 35, 35)
    )
    /// Separators and outlines (legacy `border`).
    public static let border = ABSThemedColor(
        light: .rgb(189, 191, 191), dark: .rgb(75, 85, 89), black: .rgb(55, 62, 65))
    /// Unfilled part of progress bars and sliders (legacy `track`).
    public static let track = ABSThemedColor(
        light: .rgb(189, 191, 191), dark: .rgb(107, 114, 128), black: .rgb(107, 114, 128)
    )
    /// Buffered part of the playback track (legacy `track-buffered`).
    public static let trackBuffered = ABSThemedColor(
        light: .rgb(129, 131, 131), dark: .rgb(75, 85, 99), black: .rgb(75, 85, 99)
    )

    public static let error = Color.rgb(255, 82, 82)
    public static let info = Color.rgb(33, 150, 243)
    public static let success = Color.rgb(76, 175, 80)
    public static let warning = Color.rgb(251, 140, 0)
    /// Listening progress on covers (legacy `yellow-400`).
    public static let progress = Color.rgb(250, 204, 21)
}

/// A colour that resolves per appearance and app theme: `black` for ``AppTheme/black``,
/// otherwise `light` or `dark` by colour scheme.
public struct ABSThemedColor: ShapeStyle, Hashable, Sendable {
    public let light: Color
    public let dark: Color
    public let black: Color

    public init(light: Color, dark: Color, black: Color) {
        self.light = light
        self.dark = dark
        self.black = black
    }

    public func resolve(in environment: EnvironmentValues) -> Color {
        if environment.absTheme.usesTrueBlack { return black }
        return environment.colorScheme == .dark ? dark : light
    }
}

extension AppTheme {
    /// The colour scheme to force, or `nil` to follow the system.
    public var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark, .black: .dark
        }
    }

    /// Whether backgrounds are true black (``AppTheme/black``).
    public var usesTrueBlack: Bool { self == .black }
}

extension EnvironmentValues {
    /// The app theme set with `absTheme(_:)`.
    @Entry public var absTheme: AppTheme = .system
}

extension View {
    /// Applies `theme`'s colour scheme and makes the theme available to ``ABSColor``.
    public func absTheme(_ theme: AppTheme) -> some View {
        preferredColorScheme(theme.colorScheme)
            .environment(\.absTheme, theme)
    }

    /// Fills the background with the themed screen background, true black for the black theme.
    public func absBackground() -> some View {
        background(ABSColor.background, ignoresSafeAreaEdges: .all)
    }

    /// Draws a `.borderedProminent` button's label in ``ABSColor/onAccent`` while the button is
    /// enabled, since white is 2.1:1 on the dark accent (#641, #645). Apply it inside the label.
    /// While disabled (`isEnabled`, which `.disabled` passes down to the label) it leaves the
    /// style's own dimmed label on its grey fill, which an explicit colour would override.
    public func onAccentForeground() -> some View {
        modifier(OnAccentForeground())
    }
}

private struct OnAccentForeground: ViewModifier {
    @Environment(\.isEnabled) private var isEnabled

    func body(content: Content) -> some View {
        if isEnabled {
            content.foregroundStyle(ABSColor.onAccent)
        } else {
            content
        }
    }
}

extension Color {
    static func rgb(_ red: Double, _ green: Double, _ blue: Double) -> Color {
        Color(.sRGB, red: red / 255, green: green / 255, blue: blue / 255)
    }
}
