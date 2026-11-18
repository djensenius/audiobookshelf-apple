import Foundation

/// Human-readable byte counts for every size the app shows, so they all agree. Uses Apple's file
/// convention (1000-based, as in Files, Finder and Settings); labels, digits and rounding follow
/// the locale.
public enum ByteCountFormatting {
    /// For example `432.1 MB` for 432,103,424 bytes in `en_US`. Negative counts show as zero.
    public static func string(fromBytes bytes: Int64, locale: Locale = .current) -> String {
        max(bytes, 0).formatted(.byteCount(style: .file, spellsOutZero: false).locale(locale))
    }
}
