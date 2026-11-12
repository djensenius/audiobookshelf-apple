import Foundation
import Testing

@testable import ABSCore

@Suite struct ReaderSettingsTests {
    @Test func defaultsFollowLegacyExceptTheTheme() {
        let settings = ReaderSettings()
        // Legacy defaulted to dark; the native reader follows the system appearance.
        #expect(settings.theme == .matchSystem)
        #expect(settings.fontFamily == .serif)
        #expect(settings.fontScale == 100)
        #expect(settings.lineSpacing == 115)
        #expect(settings.textStroke == 0)
        #expect(settings.spread == .auto)
    }

    @Test func rawValuesAreTheStoredAndBridgeStrings() {
        #expect(ReaderSettings.Theme.allCases.map(\.rawValue) == ["system", "light", "dark", "black", "sepia"])
        #expect(ReaderSettings.FontFamily.allCases.map(\.rawValue) == ["serif", "sans-serif"])
        #expect(ReaderSettings.Spread.allCases.map(\.rawValue) == ["auto", "none"])
    }

    @Test(arguments: [
        // (input, fontScale, lineSpacing, textStroke)
        (-50, 5, 100, 0),
        (0, 5, 100, 0),
        (4, 5, 100, 5),
        (102, 100, 100, 100),
        (103, 105, 105, 105),
        (117, 115, 115, 115),
        (300, 300, 300, 300),
        (1_000, 300, 300, 300),
    ])
    func numbersClampToTheLegacySliders(input: Int, fontScale: Int, lineSpacing: Int, textStroke: Int) {
        let initialised = ReaderSettings(fontScale: input, lineSpacing: input, textStroke: input)
        #expect(initialised.fontScale == fontScale)
        #expect(initialised.lineSpacing == lineSpacing)
        #expect(initialised.textStroke == textStroke)

        var assigned = ReaderSettings()
        assigned.fontScale = input
        assigned.lineSpacing = input
        assigned.textStroke = input
        #expect(assigned == initialised)
    }

    @Test func codableRoundTrips() throws {
        let settings = ReaderSettings(
            theme: .sepia, fontFamily: .sansSerif, fontScale: 140, lineSpacing: 180, textStroke: 25, spread: .none)
        let data = try JSONEncoder().encode(settings)
        #expect(try JSONDecoder().decode(ReaderSettings.self, from: data) == settings)

        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["theme"] as? String == "sepia")
        #expect(object["fontFamily"] as? String == "sans-serif")
        #expect(object["spread"] as? String == "none")
    }

    @Test func decodingIsLenientFieldByField() throws {
        func decode(_ json: String) throws -> ReaderSettings {
            try JSONDecoder().decode(ReaderSettings.self, from: Data(json.utf8))
        }
        #expect(try decode("{}") == ReaderSettings())
        #expect(try decode(#"{"theme":"black","future":true}"#) == ReaderSettings(theme: .black))
        #expect(
            try decode(#"{"theme":"neon","fontFamily":3,"fontScale":"big","spread":"both","lineSpacing":200}"#)
                == ReaderSettings(lineSpacing: 200))
        #expect(try decode(#"{"fontScale":9999,"textStroke":-4}"#) == ReaderSettings(fontScale: 300, textStroke: 0))
        #expect(try decode(#"{"theme":null}"#) == ReaderSettings())
    }
}
