import ABSCore
import Foundation
import Observation
import Testing

@testable import ABSAppModel

private let serverA = LibraryConnectionKey(
    connectionID: UUID(uuidString: "00000000-0000-0000-0000-00000000000A") ?? UUID(), userID: "user-1")
private let serverB = LibraryConnectionKey(
    connectionID: UUID(uuidString: "00000000-0000-0000-0000-00000000000B") ?? UUID(), userID: "user-1")

private let continueListening = Shelf(
    id: "continue-listening", label: "Continue Listening", type: .book,
    entities: .libraryItems([SampleLibrary.frankenstein, SampleLibrary.sherlock]))
private let recentlyAdded = Shelf(
    id: "recently-added", label: "Recently Added", type: .book,
    entities: .libraryItems([SampleLibrary.frankenstein, SampleLibrary.emma]))

/// A service whose shelves are `continueListening` and `recentlyAdded`, recording the requested
/// library IDs.
private func service(calls: Locked<[String]>? = nil, fail: Locked<Bool>? = nil) -> FakeLibraryService {
    var service = FakeLibraryService()
    service.shelvesHandler = { libraryID in
        calls?.value.append(libraryID)
        if fail?.value == true { throw TestError.offline }
        return [continueListening, recentlyAdded]
    }
    return service
}

private func progress(_ itemID: String, hidden: Bool = false, finished: Bool = false, lastUpdate: Int)
    -> MediaProgress
{
    MediaProgress(
        id: "p-\(itemID)", libraryItemId: itemID, progress: 0.5, isFinished: finished,
        hideFromContinueListening: hidden, lastUpdate: lastUpdate)
}

@MainActor
private func ids(_ model: HomeModel, _ sectionID: String) -> [String] {
    model.sections.first { $0.id == sectionID }?.entries.map(\.id) ?? []
}

@MainActor
@Suite struct HomeModelTests {
    @Test func loadsSectionsOnce() async throws {
        try await withLibrarySettings { settings in
            let calls = Locked<[String]>([])
            let store = LibraryStore(settings: settings)
            await store.connect(client: service(calls: calls), connectionKey: serverA)
            let model = HomeModel(store: store, libraryID: "books")
            #expect(model.sections.isEmpty)
            #expect(!model.hasLoaded)

            await model.load()
            #expect(model.sections.map(\.id) == ["continue-listening", "recently-added"])
            #expect(model.hasLoaded)
            #expect(!model.isLoading)
            #expect(model.error == nil)

            await model.load()
            #expect(calls.value == ["books"])
            await model.refresh()
            #expect(calls.value == ["books", "books"])
        }
    }

    @Test func progressChangesUpdateContinueListeningAtOnce() async throws {
        try await withLibrarySettings { settings in
            let store = LibraryStore(settings: settings)
            await store.connect(client: service(), connectionKey: serverA)
            let model = HomeModel(store: store, libraryID: "books")
            await model.load()
            let frankenstein = SampleLibrary.frankenstein.id
            let sherlock = SampleLibrary.sherlock.id

            // Hidden from Continue Listening: notified and gone without a reload.
            let hidden = Locked(false)
            withObservationTracking {
                _ = model.sections
            } onChange: {
                hidden.value = true
            }
            store.progress.apply(progress(frankenstein, hidden: true, lastUpdate: 1))
            #expect(hidden.value)
            #expect(ids(model, "continue-listening") == [sherlock])
            #expect(ids(model, "recently-added") == [frankenstein, SampleLibrary.emma.id])

            // Finished: the same.
            let finished = Locked(false)
            withObservationTracking {
                _ = model.sections
            } onChange: {
                finished.value = true
            }
            store.progress.apply(progress(sherlock, finished: true, lastUpdate: 2))
            #expect(finished.value)
            #expect(model.sections.map(\.id) == ["recently-added"])

            // Progress of an item only on other shelves isn't observed.
            let other = Locked(false)
            withObservationTracking {
                _ = model.sections
            } onChange: {
                other.value = true
            }
            store.progress.apply(progress(SampleLibrary.emma.id, finished: true, lastUpdate: 3))
            #expect(!other.value)

            // Unhiding brings the item back.
            store.progress.apply(progress(frankenstein, lastUpdate: 4))
            #expect(ids(model, "continue-listening") == [frankenstein])
        }
    }

    @Test func failedRefreshKeepsSections() async throws {
        try await withLibrarySettings { settings in
            let fail = Locked(false)
            let store = LibraryStore(settings: settings)
            await store.connect(client: service(fail: fail), connectionKey: serverA)
            let model = HomeModel(store: store, libraryID: "books")
            await model.load()

            fail.value = true
            await model.refresh()
            #expect(model.error is TestError)
            #expect(model.hasLoaded)
            #expect(model.sections.map(\.id) == ["continue-listening", "recently-added"])
        }
    }

    @Test func libraryChangeRecreatesTheShelves() async throws {
        try await withLibrarySettings { settings in
            let calls = Locked<[String]>([])
            let store = LibraryStore(settings: settings)
            await store.connect(client: service(calls: calls), connectionKey: serverA)
            let model = HomeModel(store: store, libraryID: "books")
            await model.load()

            let changed = Locked(false)
            withObservationTracking {
                _ = model.sections
            } onChange: {
                changed.value = true
            }
            model.libraryID = "pods"
            #expect(changed.value)
            // The other library's sections aren't shown for this one.
            #expect(model.sections.isEmpty)
            #expect(!model.hasLoaded)

            await model.load()
            #expect(calls.value == ["books", "pods"])
            #expect(model.hasLoaded)

            model.libraryID = nil
            await model.load()
            #expect(model.sections.isEmpty)
            #expect(calls.value == ["books", "pods"])
        }
    }

    @Test func accountChangeRecreatesTheShelves() async throws {
        try await withLibrarySettings { settings in
            let callsA = Locked<[String]>([])
            let callsB = Locked<[String]>([])
            let store = LibraryStore(settings: settings)
            await store.connect(client: service(calls: callsA), connectionKey: serverA)
            let model = HomeModel(store: store, libraryID: "books")
            await model.load()

            let changed = Locked(false)
            withObservationTracking {
                _ = model.sections
            } onChange: {
                changed.value = true
            }
            await store.connect(client: service(calls: callsB), connectionKey: serverB)
            #expect(changed.value)
            // Account A's shelves never show for account B.
            #expect(model.sections.isEmpty)
            #expect(!model.hasLoaded)

            await model.load()
            #expect(callsA.value == ["books"])
            #expect(callsB.value == ["books"])
            #expect(model.sections.map(\.id) == ["continue-listening", "recently-added"])

            // Signed out: nothing to show or load.
            store.clear()
            #expect(model.sections.isEmpty)
            await model.refresh()
            #expect(model.sections.isEmpty)
            #expect(callsB.value == ["books"])
        }
    }
}
