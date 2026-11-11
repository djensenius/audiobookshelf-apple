import ABSAPI
import ABSCore
import Foundation
import Testing

@testable import ABSAppModel

private func detail(_ id: String, _ data: LibraryFilterData) -> LibraryWithFilterData {
    LibraryWithFilterData(library: makeLibrary(id), filterData: data)
}

private func author(_ id: String, _ name: String) throws -> Author {
    try JSONDecoder().decode(Author.self, from: Data(#"{"id":"\#(id)","name":"\#(name)"}"#.utf8))
}

private func series(_ id: String, _ name: String) throws -> ABSCore.Series {
    try JSONDecoder().decode(ABSCore.Series.self, from: Data(#"{"id":"\#(id)","name":"\#(name)"}"#.utf8))
}

@MainActor
@Suite struct LibraryFilterModelTests {
    @Test func mapsAndSortsTheChoicesInTheLocalesCollation() async throws {
        let data = LibraryFilterData(
            authors: [try author("a2", "zoë"), try author("a1", "Álvaro"), try author("a3", "Adam")],
            series: [try series("s10", "Book 10"), try series("s2", "Book 2")],
            genres: ["thriller", "Fantasy", "adventure"], tags: ["b", "A"], narrators: ["Zed", "amy"],
            languages: ["fr", "English"])
        let service = FakeLibraryService(libraryHandler: { id in detail(id, data) })
        let model = LibraryFilterModel(client: service, locale: Locale(identifier: "en_US"))

        await model.load(libraryID: "books")?.value
        let choices = try #require(model.choices)
        #expect(choices.genres.map(\.name) == ["adventure", "Fantasy", "thriller"])
        #expect(choices.tags.map(\.name) == ["A", "b"])
        #expect(choices.narrators.map(\.name) == ["amy", "Zed"])
        #expect(choices.languages.map(\.name) == ["English", "fr"])
        #expect(choices.series.map(\.id) == [LibraryFilterModel.Choice.noSeries.id, "s2", "s10"])
        #expect(choices.authors.map(\.id) == ["a3", "a1", "a2"])
        #expect(choices.genres.map(\.id) == choices.genres.map(\.name))
        #expect(!model.isLoading && model.error == nil)
    }

    @Test func progressChoicesAreTheServersValues() {
        #expect(
            LibraryFilterModel.ProgressState.allCases.map(\.rawValue) == [
                "finished", "in-progress", "not-started", "not-finished",
            ])
    }

    @Test func noSeriesComesFirstAndEbookValuesAreOffered() async throws {
        let data = LibraryFilterData(series: [try series("s1", "A")])
        let service = FakeLibraryService(libraryHandler: { id in
            detail(id, id == "empty" ? LibraryFilterData() : data)
        })
        let model = LibraryFilterModel(client: service)

        await model.load(libraryID: "books")?.value
        let noSeries = LibraryFilterModel.Choice.noSeries
        #expect(model.choices?.series == [noSeries, LibraryFilterModel.Choice(id: "s1", name: "A")])
        #expect(LibraryViewPreferences.Filter(group: .series, value: noSeries.id).libraryFilter == .noSeries)
        // Legacy offers it even when the library has no series.
        await model.load(libraryID: "empty")?.value
        #expect(model.choices?.series == [noSeries])

        #expect(LibraryFilterModel.EbookKind.allCases.map(\.rawValue) == ["ebook", "supplementary"])
        #expect(
            LibraryViewPreferences.Filter(group: .ebooks, value: LibraryFilterModel.EbookKind.supplementary.rawValue)
                .libraryFilter == .ebooks("supplementary"))
    }

    @Test func loadsOncePerLibraryUntilReloaded() async throws {
        let calls = Locked(0)
        let service = FakeLibraryService(libraryHandler: { id in
            calls.value += 1
            return detail(id, LibraryFilterData(genres: ["g\(calls.value)"]))
        })
        let model = LibraryFilterModel(client: service)

        await model.load(libraryID: "a")?.value
        await model.load(libraryID: "b")?.value
        #expect(model.load(libraryID: "a") == nil)
        #expect(model.choices?.genres.map(\.name) == ["g1"])
        #expect(calls.value == 2)

        await model.reload()?.value
        #expect(model.choices?.genres.map(\.name) == ["g3"])
        #expect(model.load(libraryID: "a") == nil)
        #expect(calls.value == 3)
    }

    @Test func aResponseForALibraryTheModelLeftIsDropped() async throws {
        let gate = GatedCalls<String, LibraryWithFilterData>()
        let service = FakeLibraryService(libraryHandler: { id in try await gate.call(id) })
        let model = LibraryFilterModel(client: service)
        var calls = gate.calls.makeAsyncIterator()

        let first = model.load(libraryID: "a")
        let stale = try #require(await calls.next())
        let second = model.load(libraryID: "b")
        let fresh = try #require(await calls.next())
        #expect(model.libraryID == "b" && model.choices == nil)

        stale.reply.resume(returning: detail("a", LibraryFilterData(genres: ["old"])))
        await first?.value
        #expect(model.choices == nil)
        #expect(model.isLoading)

        fresh.reply.resume(returning: detail("b", LibraryFilterData(genres: ["new"])))
        await second?.value
        #expect(model.choices?.genres.map(\.name) == ["new"])
        // The dropped response wasn't cached either: coming back to "a" loads it again.
        let again = model.load(libraryID: "a")
        _ = try #require(await calls.next())
        #expect(again != nil)
    }

    @Test func aReloadReplacesTheLoadInFlight() async throws {
        let gate = GatedCalls<String, LibraryWithFilterData>()
        let service = FakeLibraryService(libraryHandler: { id in try await gate.call(id) })
        let model = LibraryFilterModel(client: service)
        var calls = gate.calls.makeAsyncIterator()

        let first = model.load(libraryID: "a")
        let stale = try #require(await calls.next())
        let second = model.reload()
        let fresh = try #require(await calls.next())

        fresh.reply.resume(returning: detail("a", LibraryFilterData(genres: ["new"])))
        await second?.value
        stale.reply.resume(returning: detail("a", LibraryFilterData(genres: ["old"])))
        await first?.value
        #expect(model.choices?.genres.map(\.name) == ["new"])
    }

    @Test func aFailureIsReportedAndLoadingAgainRetries() async throws {
        let fail = Locked(true)
        let service = FakeLibraryService(libraryHandler: { id in
            if fail.value { throw TestError.offline }
            return detail(id, LibraryFilterData(genres: ["g"]))
        })
        let model = LibraryFilterModel(client: service)

        await model.load(libraryID: "a")?.value
        #expect(model.error != nil && model.choices == nil && !model.isLoading)

        fail.value = false
        await model.load(libraryID: "a")?.value
        #expect(model.error == nil)
        #expect(model.choices?.genres.map(\.name) == ["g"])
    }
}
