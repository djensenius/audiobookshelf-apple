import ABSAPI
import ABSCore
import ABSRealtime
import Foundation
import Testing

@testable import ABSAppModel

private let accountA = LibraryConnectionKey(connectionID: identityA.connectionID, userID: identityA.userID)
private let accountB = LibraryConnectionKey(connectionID: identityB.connectionID, userID: identityB.userID)

private func added(_ author: Author, in libraryID: String = "lib1") -> LibraryChange {
    .author(.added(author, libraryID: libraryID))
}

private func updated(_ author: Author, in libraryID: String = "lib1") -> LibraryChange {
    .author(.updated(author, libraryID: libraryID))
}

private func removed(_ id: String, in libraryID: String = "lib1") -> LibraryChange {
    .author(.removed(id: id, libraryID: libraryID))
}

@MainActor
private func loadedAuthors(_ authors: [Author] = [Author(id: "a1", name: "Asimov", numBooks: 3)]) async
    -> AuthorsModel
{
    let model = AuthorsModel(libraryID: "lib1", service: FakeSeriesAuthorsService(authorListHandler: { _ in authors }))
    await model.load()
    return model
}

@MainActor
@Suite struct AuthorLiveUpdateTests {
    @Test func theListPatchesEachChange() async {
        let model = await loadedAuthors([
            Author(id: "a1", name: "Asimov", numBooks: 3), Author(id: "a2", name: "Zelazny", numBooks: 1),
        ])

        model.apply(added(Author(id: "a3", name: "Le Guin", imagePath: "/a3.jpg", updatedAt: 7)))
        #expect(model.authors.map(\.id) == ["a1", "a2", "a3"])
        #expect(
            model.authors.last == AuthorSummary(id: "a3", name: "Le Guin", hasImage: true, imageUpdatedAt: 7))

        // An update replaces the author in place.
        model.apply(updated(Author(id: "a2", name: "Roger Zelazny", imagePath: "/a2.jpg", updatedAt: 9, numBooks: 2)))
        #expect(model.authors.map(\.name) == ["Asimov", "Roger Zelazny", "Le Guin"])
        #expect(
            model.authors[1]
                == AuthorSummary(id: "a2", name: "Roger Zelazny", bookCount: 2, hasImage: true, imageUpdatedAt: 9))

        // An author added again replaces the shown one, keeping its book count when the payload has none.
        model.apply(added(Author(id: "a1", name: "Isaac Asimov")))
        #expect(model.authors.map(\.id) == ["a1", "a2", "a3"])
        #expect(model.authors.first == AuthorSummary(id: "a1", name: "Isaac Asimov", bookCount: 3))

        model.apply(removed("a2"))
        #expect(model.authors.map(\.id) == ["a1", "a3"])
        model.apply(removed("gone"))
        #expect(model.authors.map(\.id) == ["a1", "a3"])
        #expect(!model.isEmpty)
    }

    @Test func theListIgnoresUnknownAuthorsOtherLibrariesAndChangesBeforeItLoads() async {
        let model = await loadedAuthors()
        let before = model.authors

        model.apply(updated(Author(id: "a9", name: "Hidden")))
        model.apply(added(Author(id: "a2", name: "Elsewhere"), in: "lib2"))
        model.apply(updated(Author(id: "a1", name: "Elsewhere"), in: "lib2"))
        model.apply(removed("a1", in: "lib2"))
        #expect(model.authors == before)

        let unloaded = AuthorsModel(libraryID: "lib1", service: FakeSeriesAuthorsService())
        unloaded.apply(added(Author(id: "a2", name: "Early")))
        #expect(unloaded.authors.isEmpty)
        #expect(!unloaded.hasLoaded)
    }

    @Test func theDetailFollowsItsAuthor() async {
        let service = FakeSeriesAuthorsService(authorDetailHandler: { id in
            AuthorDetailResponse(author: Author(id: id, name: "Asimov", description: "Old.", libraryId: "lib1"))
        })
        let model = AuthorDetailModel(authorID: "a1", libraryID: "lib1", service: service)
        model.apply(updated(Author(id: "a1", name: "Too early")))
        #expect(model.detail == nil)
        await model.load()

        model.apply(updated(Author(id: "a2", name: "Someone else")))
        model.apply(removed("a2"))
        #expect(model.detail?.name == "Asimov")

        model.apply(
            updated(Author(id: "a1", name: "Isaac Asimov", description: "New.", libraryId: "lib1", numBooks: 4)))
        #expect(model.detail?.name == "Isaac Asimov")
        #expect(model.detail?.bio == "New.")
        #expect(model.detail?.summary.bookCount == 4)
        #expect(model.phase == .loaded)

        model.apply(removed("a1"))
        #expect(model.phase == .notFound)
        #expect(model.detail == nil)
    }

    @Test func theStoreDeliversChangesToItsAccountsObservers() async throws {
        try await withLibrarySettings { settings in
            let store = LibraryStore(settings: settings)
            await store.connect(client: FakeLibraryService(), connectionKey: accountA)
            let model = await loadedAuthors()
            store.observeLibraryChanges(connectionKey: accountA, owner: model) { [weak model] in model?.apply($0) }
            let otherAccount = Locked(0)
            let otherOwner = NSObject()
            store.observeLibraryChanges(connectionKey: accountB, owner: otherOwner) { _ in otherAccount.value += 1 }

            store.applyLibraryChange(added(Author(id: "a2", name: "Le Guin")), connectionKey: accountA)

            #expect(model.authors.map(\.id) == ["a1", "a2"])
            #expect(otherAccount.value == 0)
        }
    }

    @Test func theStoreDropsChangesOfAStaleSession() async throws {
        try await withLibrarySettings { settings in
            let store = LibraryStore(settings: settings)
            await store.connect(client: FakeLibraryService(), connectionKey: accountA)
            let model = await loadedAuthors()
            store.observeLibraryChanges(connectionKey: accountA, owner: model) { [weak model] in model?.apply($0) }

            // A change from another session than the one the store serves.
            store.applyLibraryChange(removed("a1"), connectionKey: accountB)
            #expect(model.authors.map(\.id) == ["a1"])

            // After a switch, the first account's model lives on until its view goes, but its
            // session's late changes are dropped.
            await store.connect(client: FakeLibraryService(), connectionKey: accountB)
            store.applyLibraryChange(removed("a1"), connectionKey: accountA)
            #expect(model.authors.map(\.id) == ["a1"])

            // And after a sign-out.
            store.clear()
            store.applyLibraryChange(removed("a1"), connectionKey: accountA)
            #expect(model.authors.map(\.id) == ["a1"])
        }
    }

    @Test func releasedObserversAreForgotten() async throws {
        try await withLibrarySettings { settings in
            let store = LibraryStore(settings: settings)
            await store.connect(client: FakeLibraryService(), connectionKey: accountA)
            let calls = Locked(0)
            var owner: NSObject? = NSObject()
            store.observeLibraryChanges(connectionKey: accountA, owner: owner!) { _ in calls.value += 1 }

            store.applyLibraryChange(removed("a1"), connectionKey: accountA)
            owner = nil
            store.applyLibraryChange(removed("a1"), connectionKey: accountA)

            #expect(calls.value == 1)
        }
    }
}
