import ABSAPI
import ABSCore
import Foundation
import Testing

// Independently captured from owned Docker servers on 2026-11-10, before implementing the DTO.
// Each scanned two generated sine-tone MP3 books, associated them with one unique series,
// verified expanded item/media IDs and membership, and marked only the first book finished.
// No response keys trimmed. IDs/names and epoch milliseconds sanitized; no credentials retained.
// Exact source pins, image digests, capture procedure and omitted responses:
// docs/testing/series-detail-contracts.md.
func seriesDetailFixture(_ version: String) throws -> Data {
    let url = try #require(
        Bundle.module.url(forResource: "series-detail-\(version)", withExtension: "json", subdirectory: "Fixtures"))
    return try Data(contentsOf: url)
}

@Suite struct SeriesDetailResponseTests {
    private func decode(_ json: String) throws -> SeriesDetailResponse {
        try JSONDecoder().decode(SeriesDetailResponse.self, from: Data(json.utf8))
    }

    @Test(arguments: ["2.26.0", "2.37.2"])
    func independentlyCapturedPartialProgress(version: String) throws {
        let data = try seriesDetailFixture(version)
        let response = try JSONDecoder().decode(SeriesDetailResponse.self, from: data)
        let raw = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let rawProgress = try #require(raw["progress"] as? [String: Any])
        #expect(response.series == (try JSONDecoder().decode(Series.self, from: data)))
        #expect(response.series.id == "series-fixture")
        #expect(response.series.name == "Series Evidence Fixture")
        #expect(response.series.nameIgnorePrefix == "Series Evidence Fixture")
        #expect(response.series.libraryId == "library-fixture")
        #expect(response.series.description == nil)
        #expect(response.series.addedAt == 1_700_000_000_000)
        #expect(response.series.updatedAt == 1_700_000_000_000)
        #expect(response.series.books == nil)
        #expect(raw["books"] == nil)
        let progress = try #require(response.progress)
        #expect(progress.libraryItemIds == ["item-one", "item-two"])
        #expect(progress.libraryItemIdsFinished == ["item-one"])
        #expect(!progress.isFinished)
        #expect(progress.libraryItemIds == rawProgress["libraryItemIds"] as? [String])
        #expect(progress.libraryItemIdsFinished == rawProgress["libraryItemIdsFinished"] as? [String])
        #expect(progress.isFinished == rawProgress["isFinished"] as? Bool)
    }

    @Test(arguments: [
        #"{"id":"s","name":"Series"}"#,
        #"{"id":"s","name":"Series","progress":null,"nameIgnorePrefix":null,"description":null,"sequence":null,"libraryId":null,"addedAt":null,"updatedAt":null,"books":null,"totalDuration":null}"#,
    ])
    func missingAndNullProgressAreNotAnUnfinishedAggregate(json: String) throws {
        let response = try decode(json)
        #expect(response == SeriesDetailResponse(series: Series(id: "s", name: "Series")))
        #expect(response.progress == nil)
    }

    @Test func flatMetadataAndUnknownFieldsUseExistingSeriesDecoder() throws {
        let response = try decode(
            #"""
            {"id":"s","name":"The Cycle","nameIgnorePrefix":"Cycle","description":"Synthetic notes",
             "libraryId":"lib","addedAt":123,"updatedAt":456,"future":{"key":true},
             "progress":{"libraryItemIds":["one"],"libraryItemIdsFinished":[],
                         "isFinished":false,"future":[1,2]}}
            """#)
        #expect(
            response.series
                == Series(
                    id: "s", name: "The Cycle", nameIgnorePrefix: "Cycle", description: "Synthetic notes",
                    libraryId: "lib", addedAt: 123, updatedAt: 456))
        #expect(
            response.progress
                == SeriesProgress(
                    libraryItemIds: ["one"], libraryItemIdsFinished: [], isFinished: false))
    }

    @Test func malformedElementsAreSkippedWithoutSortingOrDeduplicating() throws {
        let response = try decode(
            #"""
            {"id":"s","name":"Series","progress":{
              "libraryItemIds":[null,17,{},["nested"],true,"two","one","two"],
              "libraryItemIdsFinished":["two",false,{"id":"one"},null,"two"],
              "isFinished":true}}
            """#)
        let progress = try #require(response.progress)
        #expect(progress.libraryItemIds == ["two", "one", "two"])
        #expect(progress.libraryItemIdsFinished == ["two", "two"])
        // The surviving arrays disagree with completion; the server's boolean still wins.
        #expect(progress.isFinished)
    }

    @Test(arguments: [true, false])
    func allMalformedElementsAndEmptyArraysPreserveServerCompletion(finished: Bool) throws {
        for arrays in [
            #""libraryItemIds":[null,1,false,{}],"libraryItemIdsFinished":[[],true]"#,
            #""libraryItemIds":[],"libraryItemIdsFinished":[]"#,
        ] {
            let response = try decode(
                #"{"id":"s","name":"Series","progress":{\#(arrays),"isFinished":\#(finished)}}"#)
            #expect(response.progress?.libraryItemIds == [])
            #expect(response.progress?.libraryItemIdsFinished == [])
            #expect(response.progress?.isFinished == finished)
        }
    }

    @Test(arguments: ["libraryItemIds", "libraryItemIdsFinished", "isFinished"])
    func presentProgressRequiresEveryCanonicalField(field: String) throws {
        var progress: [String: Any] = [
            "libraryItemIds": ["one"], "libraryItemIdsFinished": [], "isFinished": false,
        ]
        progress.removeValue(forKey: field)
        try expectInvalidProgress(progress)
        progress[field] = NSNull()
        try expectInvalidProgress(progress)
    }

    @Test(arguments: ["libraryItemIds", "libraryItemIdsFinished"])
    func wrongArrayContainersFail(field: String) throws {
        for invalid: Any in ["one", 1, true, ["id": "one"]] {
            var progress: [String: Any] = [
                "libraryItemIds": ["one"], "libraryItemIdsFinished": [], "isFinished": false,
            ]
            progress[field] = invalid
            try expectInvalidProgress(progress)
        }
    }

    @Test func wrongBooleansAreNotCoerced() throws {
        for invalid: Any in [0, 1, "true", "false", [true], ["value": true]] {
            try expectInvalidProgress([
                "libraryItemIds": ["one"], "libraryItemIdsFinished": [], "isFinished": invalid,
            ])
        }
    }

    @Test(arguments: ["[]", "true", "1", #""progress""#])
    func wrongProgressContainerFails(fragment: String) {
        #expect(throws: DecodingError.self) {
            try decode(#"{"id":"s","name":"Series","progress":\#(fragment)}"#)
        }
    }

    @Test(arguments: [
        "{}", #"{"id":"s"}"#, #"{"name":"Series"}"#, #"{"id":null,"name":"Series"}"#,
        #"{"id":"s","name":17}"#, #"{"id":"s","name":"Series","addedAt":"yesterday"}"#,
    ])
    func requiredIdentityAndMalformedMetadataStillFail(json: String) {
        #expect(throws: DecodingError.self) { try decode(json) }
    }

    private func expectInvalidProgress(
        _ progress: [String: Any], sourceLocation: SourceLocation = #_sourceLocation
    ) throws {
        let data = try JSONSerialization.data(withJSONObject: ["id": "s", "name": "Series", "progress": progress])
        #expect(throws: DecodingError.self, sourceLocation: sourceLocation) {
            try JSONDecoder().decode(SeriesDetailResponse.self, from: data)
        }
    }
}
