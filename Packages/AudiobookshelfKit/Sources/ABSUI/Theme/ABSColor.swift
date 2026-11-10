import ABSCore
import SwiftUI

#if canImport(UIKit)
    import UIKit
#elseif canImport(AppKit)
    import AppKit
#endif

/// Semantic colours, adapted from the legacy `tailwind.css` palette for system light and
/// dark appearance. The `black` theme uses the true-black variants from
/// ``background(for:)`` and ``surface(for:)``.
public enum ABSColor {
    /// The app's accent colour from the app target's `AccentColor` asset.
    public static let accent = Color.accentColor

    /// Screen background (legacy `bg`).
    public static let background = Color(light: .rgb(255, 255, 255), dark: .rgb(56, 56, 56))
    /// Bars, sheets and cards (legacy `primary`).
    public static let surface = Color(light: .rgb(222, 222, 222), dark: .rgb(35, 35, 35))
    /// Grouped rows and inputs (legacy `secondary`).
    public static let secondarySurface = Color(light: .rgb(246, 248, 250), dark: .rgb(47, 48, 48))
    /// Primary text (legacy `fg`).
    public static let foreground = Color(light: .rgb(37, 37, 37), dark: .rgb(230, 237, 243))
    /// Secondary text (legacy `fg-muted`).
    public static let mutedForeground = Color(light: .rgb(101, 109, 118), dark: .rgb(142, 147, 153))
    /// Separators and outlines (legacy `border`).
    public static let border = Color(light: .rgb(189, 191, 191), dark: .rgb(75, 85, 89))
    /// Unfilled part of progress bars and sliders (legacy `track`).
    public static let track = Color(light: .rgb(189, 191, 191), dark: .rgb(107, 114, 128))
    /// Buffered part of the playback track (legacy `track-buffered`).
    public static let trackBuffered = Color(light: .rgb(129, 131, 131), dark: .rgb(75, 85, 99))

    public static let error = Color.rgb(255, 82, 82)
    public static let info = Color.rgb(33, 150, 243)
    public static let success = Color.rgb(76, 175, 80)
    public static let warning = Color.rgb(251, 140, 0)
    /// Listening progress on covers (legacy `yellow-400`).
    public static let progress = Color.rgb(250, 204, 21)

    /// The screen background for `theme`: true black for ``AppTheme/black``.
    public static func background(for theme: AppTheme) -> Color {
        theme.usesTrueBlack ? .black : background
    }

    /// The surface colour for `theme`: true black for ``AppTheme/black``.
    public static func surface(for theme: AppTheme) -> Color {
        theme.usesTrueBlack ? .black : surface
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
    /// Applies `theme`'s colour scheme and makes the theme available to `absBackground()`.
    public func absTheme(_ theme: AppTheme) -> some View {
        preferredColorScheme(theme.colorScheme)
            .environment(\.absTheme, theme)
    }

    /// Fills the background with the themed screen background, true black for the black theme.
    public func absBackground() -> some View {
        modifier(ThemedBackground())
    }
}

private struct ThemedBackground: ViewModifier {
    @Environment(\.absTheme) private var theme

    func body(content: Content) -> some View {
        content.background(ABSColor.background(for: theme), ignoresSafeAreaEdges: .all)
    }
}

extension Color {
    /// A colour that resolves to `light` or `dark` with the current appearance.
    public init(light: Color, dark: Color) {
        #if canImport(UIKit)
            self.init(
                uiColor: UIColor { traits in
                    traits.userInterfaceStyle == .dark ? UIColor(dark) : UIColor(light)
                }
            )
        #elseif canImport(AppKit)
            self.init(
                nsColor: NSColor(name: nil) { appearance in
                    appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(dark) : NSColor(light)
                }
            )
        #endif
    }

    static func rgb(_ red: Double, _ green: Double, _ blue: Double) -> Color {
        Color(.sRGB, red: red / 255, green: green / 255, blue: blue / 255)
    }
}
