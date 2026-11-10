/// The app's colour scheme.
///
/// Legacy offered black, dark and light and defaulted to dark; the native app adds
/// `system` and defaults to it so it follows the device appearance.
public enum AppTheme: String, CaseIterable, Sendable {
    case system
    case light
    case dark
    case black
}

/// Haptic feedback strength. Raw values match the legacy `hapticFeedback` setting.
public enum HapticFeedback: String, CaseIterable, Sendable {
    case off = "OFF"
    case light = "LIGHT"
    case medium = "MEDIUM"
    case heavy = "HEAVY"
}

/// How hard the device must be shaken to reset the sleep timer. Raw values match the
/// legacy `shakeSensitivity` setting.
public enum ShakeSensitivity: String, CaseIterable, Sendable {
    case veryLow = "VERY_LOW"
    case low = "LOW"
    case medium = "MEDIUM"
    case high = "HIGH"
    case veryHigh = "VERY_HIGH"
}

/// Whether downloads or streaming may use a cellular connection. Raw values match the
/// legacy `downloadUsingCellular` and `streamingUsingCellular` settings.
public enum CellularPolicy: String, CaseIterable, Sendable {
    case always = "ALWAYS"
    case ask = "ASK"
    case never = "NEVER"
}
