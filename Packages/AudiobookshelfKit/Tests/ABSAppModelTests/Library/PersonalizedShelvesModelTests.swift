import ABSCore
import Foundation
import Testing

@testable import ABSAppModel

@MainActor
@Suite struct PersonalizedShelvesModelTests {
    @Test func loadsTheLibrarysShelves() async {
        var service = FakeLibraryService()
        service.shelvesHandler = { libraryID in
            #expect(libraryID == "lib")
            return [makeShelf("continue-listening"), makeShelf("recently-added")]
        }
        let model = PersonalizedShelvesModel(client: service, libraryID: "lib")
        #expect(!model.hasLoaded)

        await model.load()
        #expect(model.shelves.map(\.id) == ["continue-listening", "recently-added"])
        #expect(model.hasLoaded)
        #expect(!model.isLoading)
        #expect(model.error == nil)
    }

    @Test func failedReloadKeepsTheShelves() async {
        let fail = Locked(false)
        var service = FakeLibraryService()
        service.shelvesHandler = { _ in
            if fail.value { throw TestError.offline }
            return [makeShelf("continue-listening")]
        }
        let model = PersonalizedShelvesModel(client: service, libraryID: "lib")
        await model.load()

        fail.value = true
        await model.load()
        #expect(model.error is TestError)
        #expect(model.shelves.map(\.id) == ["continue-listening"])

        fail.value = false
        await model.load()
        #expect(model.error == nil)
    }

    @Test func onlyTheLatestLoadIsApplied() async throws {
        let gate = GatedCalls<String, [Shelf]>()
        var service = FakeLibraryService()
        service.shelvesHandler = { libraryID in try await gate.call(libraryID) }
        var calls = gate.calls.makeAsyncIterator()
        let model = PersonalizedShelvesModel(client: service, libraryID: "lib")

        let first = Task { await model.load() }
        let firstCall = try #require(await calls.next())
        let second = Task { await model.load() }
        let secondCall = try #require(await calls.next())

        secondCall.reply.resume(returning: [makeShelf("new")])
        await second.value
        #expect(model.shelves.map(\.id) == ["new"])
        #expect(!model.isLoading)

        firstCall.reply.resume(returning: [makeShelf("old")])
        await first.value
        #expect(model.shelves.map(\.id) == ["new"])
    }
}
