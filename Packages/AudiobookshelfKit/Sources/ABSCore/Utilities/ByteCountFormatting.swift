import Foundation

/// Human-readable byte counts, in binary (1024-based) units like the legacy app.
public enum ByteCountFormatting {
    /// For example `0 bytes`, `1.5 MB`, or `1.12 TB` in `en_US`. Negative counts show as zero.
    public static func string(fromBytes bytes: Int64, locale: Locale = .current) -> String {
        max(bytes, 0).formatted(.byteCount(style: .binary, spellsOutZero: false).locale(locale))
    }
}
