import Foundation
import Testing

@testable import ABSAppModel

@Suite struct EPUBBridgeEventTests {
    private func decode(_ json: String) throws(EPUBBridgeDecodingError) -> EPUBBridgeEvent {
        try EPUBBridgeEvent.decode(Data(json.utf8))
    }

    /// A valid `relocated` event with `fields` replaced (`NSNull()` for null) and `removing` left out.
    private static func relocated(_ fields: [String: Any] = [:], removing: String? = nil) -> String {
        var object: [String: Any] = [
            "type": "relocated", "startCfi": "a", "endCfi": "b", "progress": 0, "atStart": false, "atEnd": false,
        ]
        object.merge(fields) { $1 }
        if let removing { object[removing] = nil }
        let data = (try? JSONSerialization.data(withJSONObject: object, options: .sortedKeys)) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    @Test func decodesReady() throws {
        #expect(try decode(#"{"type":"ready"}"#) == .ready)
    }

    @Test func decodesTOC() throws {
        let json = """
            {"type":"toc","items":[
              {"id":"c1","label":"Chapter 1","href":"ch1.xhtml","subitems":[
                {"id":"c1a","label":"Part A","href":"ch1.xhtml#a","subitems":[]}]},
              {"id":"c2","label":"Chapter 2","href":"ch2.xhtml"}]}
            """
        let expected: [EPUBTOCItem] = [
            EPUBTOCItem(
                id: "c1", label: "Chapter 1", href: "ch1.xhtml",
                subitems: [EPUBTOCItem(id: "c1a", label: "Part A", href: "ch1.xhtml#a")]),
            EPUBTOCItem(id: "c2", label: "Chapter 2", href: "ch2.xhtml"),
        ]
        #expect(try decode(json) == .toc(expected))
    }

    @Test func decodesLocationsReady() throws {
        let locations = #"["epubcfi(/6/2!/4/1:0)","epubcfi(/6/4!/4/2:150)"]"#
        let json = try String(
            decoding: JSONSerialization.data(withJSONObject: ["type": "locationsReady", "locations": locations]),
            as: UTF8.self)
        #expect(try decode(json) == .locationsReady(locations))
    }

    @Test func decodesRelocated() throws {
        let json = """
            {"type":"relocated","startCfi":"epubcfi(/6/4!/4/2:0)","endCfi":"epubcfi(/6/4!/4/2:300)",
             "progress":0.25,"href":"ch1.xhtml","atStart":false,"atEnd":true}
            """
        let expected = EPUBRelocation(
            startCfi: "epubcfi(/6/4!/4/2:0)", endCfi: "epubcfi(/6/4!/4/2:300)", progress: 0.25, href: "ch1.xhtml",
            atStart: false, atEnd: true)
        #expect(try decode(json) == .relocated(expected))
    }

    @Test func relocatedWithoutHrefDecodes() throws {
        let json = Self.relocated(["atStart": true])
        #expect(try decode(json) == .relocated(EPUBRelocation(startCfi: "a", endCfi: "b", progress: 0, atStart: true)))
    }

    @Test(arguments: [(-0.5, 0.0), (1.7, 1.0), (1, 1), (0.5, 0.5)])
    func progressIsClamped(sent: Double, expected: Double) throws {
        let json = Self.relocated(["progress": sent])
        guard case .relocated(let relocation) = try decode(json) else {
            Issue.record("not relocated")
            return
        }
        #expect(relocation.progress == expected)
    }

    @Test func decodesTap() throws {
        #expect(try decode(#"{"type":"tap","x":0.1,"y":0.9}"#) == .tap(x: 0.1, y: 0.9))
        #expect(try decode(#"{"type":"tap","x":-1,"y":2}"#) == .tap(x: 0, y: 1))
    }

    @Test func decodesErrorWithAndWithoutPhase() throws {
        #expect(
            try decode(#"{"type":"error","message":"Bad zip","phase":"open"}"#)
                == .error(message: "Bad zip", phase: "open"))
        #expect(try decode(#"{"type":"error","message":"Oops"}"#) == .error(message: "Oops", phase: nil))
        #expect(try decode(#"{"type":"error","message":"Oops","phase":null}"#) == .error(message: "Oops", phase: nil))
    }

    @Test func unknownTypesAreNotErrors() throws {
        #expect(try decode(#"{"type":"selected","cfiRange":"x"}"#) == .unknown("selected"))
        #expect(try decode(#"{"type":""}"#) == .unknown(""))
    }

    @Test func skippedTypesAreNotDecoded() throws {
        // An invalid body, so decoding it would throw.
        let toc = Data(#"{"type":"toc","items":[{"id":5}]}"#.utf8)
        #expect(try EPUBBridgeEvent.decode(toc, skipping: ["toc"]) == .unknown("toc"))
        #expect(throws: EPUBBridgeDecodingError.self) { try EPUBBridgeEvent.decode(toc) }
        #expect(try EPUBBridgeEvent.decode(Data(#"{"type":"ready"}"#.utf8), skipping: ["toc"]) == .ready)
    }

    @Test func messagesOverTheLimitAreNotParsed() throws {
        let prefix = #"{"type":"locationsReady","locations":""#
        let fits = String(repeating: "a", count: EPUBBridgeEvent.maxMessageBytes - prefix.utf8.count - 2)
        #expect(try EPUBBridgeEvent.decode(Data((prefix + fits + #""}"#).utf8)) == .locationsReady(fits))
        let over = Data((prefix + fits + #"a"}"#).utf8)
        #expect(over.count == EPUBBridgeEvent.maxMessageBytes + 1)
        #expect(throws: EPUBBridgeDecodingError.tooLarge) { try EPUBBridgeEvent.decode(over) }
    }

    @Test func extraFieldsAreIgnored() throws {
        #expect(try decode(#"{"type":"ready","version":2}"#) == .ready)
    }

    @Test(arguments: [
        (#"{"type":"locationsReady"}"#, "locationsReady", "locations"),
        (relocated(removing: "startCfi"), "relocated", "startCfi"),
        (relocated(removing: "endCfi"), "relocated", "endCfi"),
        (relocated(removing: "progress"), "relocated", "progress"),
        (relocated(["progress": NSNull()]), "relocated", "progress"),
        (relocated(removing: "atEnd"), "relocated", "atEnd"),
        (#"{"type":"tap","x":0.5}"#, "tap", "y"),
        (#"{"type":"error","phase":"open"}"#, "error", "message"),
        (#"{"type":"toc"}"#, "toc", "items"),
        (#"{"type":"toc","items":[{"id":"c1","href":"ch1.xhtml"}]}"#, "toc", "items.0.label"),
    ])
    func missingRequiredFieldsThrow(json: String, type: String, field: String) {
        #expect(throws: EPUBBridgeDecodingError.missingField(type: type, field: field)) { try decode(json) }
    }

    @Test func wrongFieldTypesThrow() {
        #expect(throws: EPUBBridgeDecodingError.invalidField(type: "tap", field: "x")) {
            try decode(#"{"type":"tap","x":"left","y":0.5}"#)
        }
        #expect(throws: EPUBBridgeDecodingError.invalidField(type: "relocated", field: "atEnd")) {
            try decode(Self.relocated(["atEnd": 1]))
        }
    }

    @Test(arguments: ["", "not json", "[]", "\"ready\"", "null", "42"])
    func nonObjectsThrow(json: String) {
        #expect(throws: EPUBBridgeDecodingError.notAnObject) { try decode(json) }
    }

    @Test(arguments: ["{}", #"{"type":5}"#, #"{"type":null}"#, #"{"kind":"ready"}"#])
    func objectsWithoutAStringTypeThrow(json: String) {
        #expect(throws: EPUBBridgeDecodingError.missingType) { try decode(json) }
    }
}

@Suite struct EPUBBridgeCommandTests {
    private struct Payload: Encodable {
        var theme = "sepia"
        var fontScale = 120
        var spread = "auto"
        var themeRules = ["body": ["color": "#5b4636"]]
    }

    private func object(_ command: EPUBBridgeCommand) throws -> NSDictionary {
        try #require(try JSONSerialization.jsonObject(with: command.jsonData()) as? NSDictionary)
    }

    private var settings: EPUBSettingsJSON {
        get throws { try EPUBSettingsJSON(encoding: Payload()) }
    }

    private var settingsObject: NSDictionary {
        ["theme": "sepia", "fontScale": 120, "spread": "auto", "themeRules": ["body": ["color": "#5b4636"]]]
    }

    @Test func encodesOpen() throws {
        let url = try #require(URL(string: "absreader://book/li_1.epub"))
        let command = EPUBBridgeCommand.open(
            url: url, location: "epubcfi(/6/4!/4/2:0)", locations: #"["epubcfi(/6/2)"]"#, settings: try settings)
        let expected: NSDictionary = [
            "type": "open", "url": "absreader://book/li_1.epub", "location": "epubcfi(/6/4!/4/2:0)",
            "locations": #"["epubcfi(/6/2)"]"#, "settings": settingsObject,
        ]
        #expect(try object(command) == expected)
    }

    @Test func openLeavesOutAMissingLocationAndLocations() throws {
        let url = try #require(URL(string: "absreader://book/li_1.epub"))
        let command = EPUBBridgeCommand.open(url: url, location: nil, locations: nil, settings: try settings)
        let expected: NSDictionary = ["type": "open", "url": "absreader://book/li_1.epub", "settings": settingsObject]
        #expect(try object(command) == expected)
    }

    @Test func encodesDisplayNextPrevAndApplySettings() throws {
        #expect(try object(.display(target: "ch2.xhtml")) == ["type": "display", "target": "ch2.xhtml"])
        #expect(try object(.next) == ["type": "next"])
        #expect(try object(.prev) == ["type": "prev"])
        #expect(try object(.applySettings(try settings)) == ["type": "applySettings", "settings": settingsObject])
    }

    @Test func outputIsStableAndKeepsSlashes() throws {
        let data = try EPUBBridgeCommand.display(target: "OEBPS/ch1.xhtml").jsonData()
        #expect(String(decoding: data, as: UTF8.self) == #"{"target":"OEBPS/ch1.xhtml","type":"display"}"#)
    }

    @Test func preEncodedSettingsAreSplicedAsAnObject() throws {
        let settings = try EPUBSettingsJSON(jsonObject: Data(#"{"gap":24,"spread":"none"}"#.utf8))
        #expect(
            try object(.applySettings(settings)) == [
                "type": "applySettings", "settings": ["gap": 24, "spread": "none"],
            ])
    }

    @Test(arguments: [#"[1,2]"#, #""light""#, "nope", ""])
    func settingsMustBeAnObject(json: String) {
        #expect(throws: EPUBBridgeCommandError.settingsNotAnObject) {
            try EPUBSettingsJSON(jsonObject: Data(json.utf8))
        }
    }

    @Test func settingsThatEncodeToANonObjectThrow() {
        #expect(throws: EPUBBridgeCommandError.settingsNotAnObject) { try EPUBSettingsJSON(encoding: ["a", "b"]) }
    }
}
