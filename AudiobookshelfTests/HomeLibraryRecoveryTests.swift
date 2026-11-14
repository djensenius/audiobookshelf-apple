import ABSAPI
import ABSAppModel
import ABSCore
import Foundation
import Testing

@testable import Audiobookshelf

private let identity = SessionIdentity(connectionID: UUID(), userID: "u")
private let key = LibraryConnectionKey(connectionID: identity.connectionID, userID: identity.userID)
private let books = Library(id: "books", name: "Books", mediaType: .book)
private let other = Library(id: "other", name: "Other", mediaType: .book)

/// A server whose libraries can be deleted. Each libraries request gives the next scripted
/// answer (requests past the script fail), holding a `.held` one until ``answer(_:)``, and is
/// counted. A library's shelves are served while it exists, and refused with `refusal`
/// otherwise; the libraries asked for are recorded.
private actor LibrariesServer: LibraryService {
    enum Answer { case list([Library]), fails, held }
    struct Failure: Error {}
    struct Unused: Error {}

    private var answers: [Answer]
    private var existing: Set<String>
    private let refusal: APIError
    private(set) var requests = 0
    private(set) var shelvesRequests: [String] = []
    private let held: AsyncStream<[Library]?>
    private let heldContinuation: AsyncStream<[Library]?>.Continuation

    init(_ answers: [Answer], existing: Set<String>, refusal: APIError = .notFound) {
        self.answers = answers
        self.existing = existing
        self.refusal = refusal
        (held, heldContinuation) = AsyncStream.makeStream(of: [Library]?.self)
    }

    func libraries() async throws -> [Library] {
        requests += 1
        switch answers.isEmpty ? .fails : answers.removeFirst() {
        case .list(let libraries):
            return libraries
        case .fails:
            throw Failure()
        case .held:
            for await answer in held {
                guard let answer else { throw Failure() }
                return answer
            }
            throw Failure()
        }
    }

    func personalizedShelves(libraryID: String) async throws -> [Shelf] {
        shelvesRequests.append(libraryID)
        guard existing.contains(libraryID) else { throw refusal }
        return []
    }

    /// Deletes `libraryID`, or takes the user's access to it.
    func remove(_ libraryID: String) {
        existing.remove(libraryID)
    }

    /// Ends the held libraries request: with `libraries`, or a failure for `nil`.
    nonisolated func answer(_ libraries: [Library]?) {
        heldContinuation.yield(libraries)
    }

    func library(id: String) async throws -> LibraryWithFilterData { throw Unused() }
    func items(libraryID: String, query: LibraryQuery) async throws -> PagedResults<LibraryItem> { throw Unused() }
}

/// Runs `body` with a store serving `server` (not loaded yet) and a scene's router of the same
/// account, with `lastLibraryID` saved as the account's last library.
@MainActor
private func withScene(
    _ server: LibrariesServer, lastLibraryID: String? = nil,
    _ body: (LibraryStore, Router) async throws -> Void
) async throws {
    let suiteName = "HomeLibraryRecoveryTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let settings = AppSettings(defaults: defaults)
    if let lastLibraryID { settings.setLastLibraryID(lastLibraryID, serverID: key.serverID, userID: key.userID) }
    let store = LibraryStore(settings: settings)
    store.attach(client: server, connectionKey: key)
    try await body(store, Router(identity: identity))
}

/// What Home's update does after the shelves for `trigger`, with the server.
@MainActor
private func updateLibraries(of store: LibraryStore, after model: HomeModel, for trigger: HomeRefreshSchedule.Trigger)
    async
{
    await HomeRefreshSchedule.updateLibrariesAfterShelves(
        of: store, shelvesError: model.error, for: trigger, isConnected: { true })
}

/// A selected library that disappears from the server is replaced with the initial one (#569).
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct HomeLibraryRecoveryTests {
    /// Only the server refusing the library itself (404 deleted, 403 no access) says the selected
    /// library may be gone; other failures say nothing about the list.
    @Test func onlyANotFoundOrForbiddenShelvesFailureRefusesTheLibrary() {
        #expect(HomeRefreshSchedule.refusesLibrary(APIError.notFound))
        #expect(HomeRefreshSchedule.refusesLibrary(APIError.forbidden(message: nil)))
        #expect(HomeRefreshSchedule.refusesLibrary(APIError.forbidden(message: "No access")))
        #expect(!HomeRefreshSchedule.refusesLibrary(nil))
        #expect(!HomeRefreshSchedule.refusesLibrary(APIError.timedOut))
        #expect(!HomeRefreshSchedule.refusesLibrary(APIError.network(.notConnectedToInternet)))
        #expect(!HomeRefreshSchedule.refusesLibrary(APIError.http(status: 500, message: nil)))
        #expect(!HomeRefreshSchedule.refusesLibrary(APIError.unauthorized(message: nil)))
        #expect(!HomeRefreshSchedule.refusesLibrary(LibrariesServer.Failure()))
        #expect(!HomeRefreshSchedule.refusesLibrary(CancellationError()))
    }

    /// With a library selected, the load trigger and the user's refresh reload the list once
    /// after it failed or the server refused the library's shelves, waiting for a request in
    /// flight; never on scene activation, never without the server, and not on the normal path.
    @Test func theListIsReloadedAfterTheShelvesOnlyWhenItMayBeOutOfDate() {
        for trigger in HomeRefreshSchedule.Trigger.allCases {
            for failed in [false, true] {
                for loading in [false, true] {
                    for refused in [false, true] {
                        for connected in [false, true] {
                            let reloads = connected && trigger != .sceneActivation && (failed || refused)
                            let expected: HomeRefreshSchedule.LibrariesRequest? =
                                reloads ? (loading ? .afterInFlight : .now) : nil
                            #expect(
                                HomeRefreshSchedule.librariesRequestAfterShelves(
                                    for: trigger, librariesFailed: failed, librariesLoading: loading,
                                    shelvesRefused: refused, isConnected: connected) == expected,
                                "\(trigger), failed \(failed), loading \(loading), refused \(refused), connected \(connected)"
                            )
                        }
                    }
                }
            }
        }
    }

    /// The selected library is deleted while the app runs: its shelves are refused, one Retry
    /// reloads the list, the scene falls back to the initial library and Home loads its shelves.
    @Test func aSelectedLibraryDeletedOnTheServerIsReplacedAfterOneRetry() async throws {
        let server = LibrariesServer([.list([books, other]), .list([other])], existing: ["books", "other"])
        try await withScene(server) { store, router in
            await store.refresh()
            SceneLibrarySelection.reconcile(router, store: store)
            SceneLibrarySelection.select("books", router: router, store: store)
            let model = HomeModel(store: store, libraryID: router.libraryID)
            await model.load()
            #expect(model.hasLoaded && model.error == nil)

            await server.remove("books")
            // Retry: the shelves, refused, then the list.
            await model.refresh()
            #expect(model.error != nil)
            await updateLibraries(of: store, after: model, for: .userRefresh)
            #expect(await server.requests == 2)

            // The shell's selection sync, then Home's load trigger for the new library.
            SceneLibrarySelection.reconcile(router, store: store)
            #expect(router.libraryID == "other")
            model.libraryID = router.libraryID
            await model.load()
            #expect(model.hasLoaded && model.error == nil)
            await updateLibraries(of: store, after: model, for: .loadTrigger)
            #expect(await server.requests == 2)
            #expect(await server.shelvesRequests == ["books", "books", "other"])
        }
    }

    /// A confirming ping retries the selected library's shelves while a libraries request that
    /// predates the library's deletion succeeds: the refusal still reloads the list once, and the
    /// scene falls back to the initial library (#570). That request doesn't count as recovery.
    @Test func aListRequestBeforeTheRefusalDoesntStopAVerificationsReload() async throws {
        let server = LibrariesServer(
            [.list([books, other]), .list([books, other]), .list([other])], existing: ["books", "other"])
        try await withScene(server) { store, router in
            await store.refresh()
            SceneLibrarySelection.reconcile(router, store: store)
            SceneLibrarySelection.select("books", router: router, store: store)
            let model = HomeModel(store: store, libraryID: router.libraryID)
            await server.remove("books")
            await model.load()
            #expect(model.error != nil)

            await HomeRefreshSchedule.updateAfterVerification(
                of: model, store: store, isConnected: { true }, pollInterval: .milliseconds(5),
                retry: { listSince in
                    // A list request from before the deletion succeeds during the retry.
                    await store.refresh()
                    await model.refresh()
                    return await HomeRefreshSchedule.updateLibrariesAfterShelves(
                        of: store, shelvesError: model.error, for: .loadTrigger, isConnected: { true },
                        pollInterval: .milliseconds(5), since: listSince)
                },
                refreshed: { _ in false })
            #expect(await server.requests == 3)

            SceneLibrarySelection.reconcile(router, store: store)
            #expect(router.libraryID == "other")
        }
    }

    /// The launch's libraries request failed, so the saved library was restored unchecked, and
    /// it is gone: once the server answers again, Home's load trigger reloads the list once and
    /// the guess falls back to the initial library.
    @Test func aStaleSavedLibraryFallsBackOnceTheServerAnswersAgain() async throws {
        let server = LibrariesServer([.fails, .list([other])], existing: ["other"])
        try await withScene(server, lastLibraryID: "gone") { store, router in
            await store.refresh()
            SceneLibrarySelection.reconcile(router, store: store)
            #expect(router.libraryID == "gone" && !router.isLibraryChecked)
            let model = HomeModel(store: store, libraryID: router.libraryID)

            await model.load()
            await updateLibraries(of: store, after: model, for: .loadTrigger)
            #expect(await server.requests == 2)

            SceneLibrarySelection.reconcile(router, store: store)
            #expect(router.libraryID == "other")
            model.libraryID = router.libraryID
            await model.load()
            #expect(model.hasLoaded && model.error == nil)
            await updateLibraries(of: store, after: model, for: .loadTrigger)
            #expect(await server.requests == 2)
        }
    }

    /// After a failed launch libraries request, a saved library that still exists loads its
    /// shelves; the load trigger still reloads the list once, so the guess is checked.
    @Test func aSavedLibraryThatStillExistsIsCheckedOnceTheServerAnswersAgain() async throws {
        let server = LibrariesServer([.fails, .list([books, other])], existing: ["books", "other"])
        try await withScene(server, lastLibraryID: "books") { store, router in
            await store.refresh()
            SceneLibrarySelection.reconcile(router, store: store)
            #expect(router.libraryID == "books" && !router.isLibraryChecked)
            let model = HomeModel(store: store, libraryID: router.libraryID)

            await model.load()
            #expect(model.hasLoaded && model.error == nil)
            await updateLibraries(of: store, after: model, for: .loadTrigger)
            #expect(await server.requests == 2)

            SceneLibrarySelection.reconcile(router, store: store)
            #expect(router.libraryID == "books" && router.isLibraryChecked)
        }
    }

    /// A server whose libraries list keeps failing isn't polled: each Retry reloads it once.
    @Test func aListThatKeepsFailingIsReloadedOncePerRetry() async throws {
        let server = LibrariesServer([], existing: [])
        try await withScene(server, lastLibraryID: "gone") { store, router in
            await store.refresh()
            SceneLibrarySelection.reconcile(router, store: store)
            let model = HomeModel(store: store, libraryID: router.libraryID)
            for retry in 1...3 {
                await model.refresh()
                await updateLibraries(of: store, after: model, for: .userRefresh)
                #expect(await server.requests == 1 + retry)
            }
            SceneLibrarySelection.reconcile(router, store: store)
            #expect(router.libraryID == "gone")
        }
    }

    /// The normal path makes no libraries request: shelves that load, or that fail for another
    /// reason than a refusal (a server error), while the list is loaded.
    @Test func theListIsntReloadedAfterShelvesThatLoadOrFailForAnotherReason() async throws {
        let server = LibrariesServer(
            [.list([books, other])], existing: ["books"], refusal: .http(status: 500, message: nil))
        try await withScene(server) { store, _ in
            await store.refresh()
            for libraryID in ["books", "other"] {
                let model = HomeModel(store: store, libraryID: libraryID)
                await model.load()
                #expect((model.error == nil) == (libraryID == "books"))
                for trigger in HomeRefreshSchedule.Trigger.allCases {
                    await updateLibraries(of: store, after: model, for: trigger)
                }
            }
            #expect(await server.requests == 1)
        }
    }

    /// A trigger whose task was cancelled (it changed, and runs again) makes no request.
    @Test func aCancelledTriggerDoesntReloadTheList() async throws {
        let server = LibrariesServer([.list([other])], existing: ["other"])
        try await withScene(server) { store, _ in
            await store.refresh()
            let update = Task { @MainActor in
                await HomeRefreshSchedule.updateLibrariesAfterShelves(
                    of: store, shelvesError: APIError.notFound, for: .userRefresh, isConnected: { true })
            }
            update.cancel()
            await update.value
            #expect(await server.requests == 1)
        }
    }

    /// The libraries requests made in all when the shelves were refused while a libraries
    /// request is in flight, which then ends with a list or a failure. The first load is request
    /// 1, the one in flight request 2, so 3 is exactly one reload.
    private func librariesRequests(inFlightSucceeds succeeds: Bool) async throws -> Int {
        let server = LibrariesServer([.list([books, other]), .held, .list([other])], existing: ["other"])
        var requests = 0
        try await withScene(server) { store, _ in
            await store.refresh()
            let inFlight = Task { await store.refresh() }
            while !store.isLoading { await Task.yield() }
            // Runs until it waits, so it decides while the request is in flight.
            let update = Task.immediate { @MainActor in
                await HomeRefreshSchedule.updateLibrariesAfterShelves(
                    of: store, shelvesError: APIError.notFound, for: .userRefresh, isConnected: { true },
                    pollInterval: .milliseconds(5))
            }
            #expect(store.isLoading)
            server.answer(succeeds ? [other] : nil)
            await inFlight.value
            await update.value
            #expect(!store.isLoading && store.error == nil)
            requests = await server.requests
        }
        return requests
    }

    @Test func aLibrariesRequestInFlightThatFailsIsRetriedOnce() async throws {
        #expect(try await librariesRequests(inFlightSucceeds: false) == 3)
    }

    @Test func aLibrariesRequestInFlightThatSucceedsIsntRetried() async throws {
        #expect(try await librariesRequests(inFlightSucceeds: true) == 2)
    }
}
