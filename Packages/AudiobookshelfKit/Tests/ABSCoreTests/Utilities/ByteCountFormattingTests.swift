import ABSCore
import Foundation
import Testing

/// Exact labels and rounding come from the system's locale data, so these tests check the
/// wiring and structure rather than exact strings, except for the en_US case from #688.
@Suite struct ByteCountFormattingTests {
    static let style = ByteCountFormatStyle(style: .file, spellsOutZero: false)

    @Test(arguments: [0, 1, 512, 1536, 1_536_000, 1_073_741_824, 1_234_567_890_123] as [Int64])
    func matchesFileByteCountStyle(bytes: Int64) {
        let locale = Locale(identifier: "en_US")
        #expect(
            ByteCountFormatting.string(fromBytes: bytes, locale: locale) == bytes.formatted(Self.style.locale(locale)))
    }

    @Test func clampsNegativeCountsToZero() {
        let locale = Locale(identifier: "en_US")
        #expect(
            ByteCountFormatting.string(fromBytes: -5, locale: locale)
                == ByteCountFormatting.string(fromBytes: 0, locale: locale))
    }

    @Test func usesDecimalUnits() {
        // The #688 download: decimal units give 432.1 MB, binary ones 412.1.
        #expect(ByteCountFormatting.string(fromBytes: 432_103_424, locale: Locale(identifier: "en_US")) == "432.1 MB")
    }

    @Test func usesLocale() {
        let string = ByteCountFormatting.string(fromBytes: 1_572_864, locale: Locale(identifier: "de_DE"))
        #expect(string.contains("1,6"))
        #expect(string.contains("MB"))
    }
}
