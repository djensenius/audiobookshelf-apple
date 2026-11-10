import Foundation

/// Human-readable byte counts: 1024-based, like the legacy app; labels and rounding follow the system.
public enum ByteCountFormatting {
    /// For example `1.5 MB` in `en_US`. Negative counts show as zero.
    public static func string(fromBytes bytes: Int64, locale: Locale = .current) -> String {
        max(bytes, 0).formatted(.byteCount(style: .binary, spellsOutZero: false).locale(locale))
    }
}
