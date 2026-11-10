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
    /// than legacy so the text meets the WCAG 4.5:1 minimum on every surface above.
    public static let mutedForeground = ABSThemedColor(
        light: .rgb(91, 99, 108), dark: .rgb(156, 161, 167), black: .rgb(120, 126, 132)
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
}

extension Color {
    static func rgb(_ red: Double, _ green: Double, _ blue: Double) -> Color {
        Color(.sRGB, red: red / 255, green: green / 255, blue: blue / 255)
    }
}
