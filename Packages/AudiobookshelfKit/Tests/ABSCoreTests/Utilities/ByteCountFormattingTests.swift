import ABSCore
import Foundation
import Testing

@Suite struct ByteCountFormattingTests {
    let locale = Locale(identifier: "en_US")

    @Test(
        arguments: [
            (0, "0 bytes"), (1, "1 byte"), (512, "512 bytes"), (1_536_000, "1.5 MB"), (1_073_741_824, "1 GB"),
            (1_234_567_890_123, "1.12 TB"), (-5, "0 bytes"),
        ] as [(Int64, String)])
    func formatsBinaryUnits(bytes: Int64, expected: String) {
        #expect(ByteCountFormatting.string(fromBytes: bytes, locale: locale) == expected)
    }

    @Test func usesLocale() {
        #expect(ByteCountFormatting.string(fromBytes: 1_536_000, locale: Locale(identifier: "de_DE")) == "1,5 MB")
    }
}
