import ABSAPI
import ABSCore
import ABSRealtime
import Foundation
import Testing

@testable import ABSAppModel

/// An ``RssFeedService`` that records requests and answers from closures.
private final class FakeRssFeedService: RssFeedService {
    enum Request: Sendable, Equatable {
        case current(RssFeedTarget)
        case open(RssFeedTarget, RssFeedOpenRequest)
        case close(String)
    }

    let server: URL
    let requests = Locked<[Request]>([])
    let current: @Sendable () async throws -> RssFeed?
    let open: @Sendable (RssFeedOpenRequest) async throws -> RssFeed
    let close: @Sendable () async throws -> Void

    init(
        server: String = "https://abs.example/abs/",
        current: @escaping @Sendable () async throws -> RssFeed? = { nil },
        open: @escaping @Sendable (RssFeedOpenRequest) async throws -> RssFeed = { feed(slug: $0.slug) },
        close: @escaping @Sendable () async throws -> Void = {}
    ) {
        self.server = URL(string: server)!
        self.current = current
        self.open = open
        self.close = close
    }

    func serverURL() async -> URL { server }

    func currentFeed(for target: RssFeedTarget) async throws -> RssFeed? {
        requests.value.append(.current(target))
        return try await current()
    }

    func openFeed(for target: RssFeedTarget, _ request: RssFeedOpenRequest) async throws -> RssFeed {
        requests.value.append(.open(target, request))
        return try await open(request)
    }

    func closeFeed(id: String) async throws {
        requests.value.append(.close(id))
        try await close()
    }
}

private func feed(slug: String) -> RssFeed {
    RssFeed(id: "feed-\(slug)", entityType: "series", entityId: "series-1", feedUrl: "/feed/\(slug)")
}

@MainActor
@Suite struct RssFeedModelTests {
    private let target = RssFeedTarget(.series, id: "series-1")

    @Test(arguments: [
        (UserType.root, true), (.admin, true), (.user, false), (.guest, false), (.unknown("custom"), false),
    ])
    func onlyAdminsAndRootManageFeeds(type: UserType, expected: Bool) {
        #expect(RssFeedModel.canManageFeeds(type) == expected)
    }

    @Test func offlineHasNoUserTypeAndCantManageFeeds() {
        #expect(!RssFeedModel.canManageFeeds(nil))
    }

    @Test(arguments: [
        ("  My Series ", "my-series"), ("Ça.va/bien:ok", "ca-va-bien-ok"), ("a.b.c", "a-b-c"),
        ("snake_case--slug", "snake_case-slug"), ("what?#&=", "what"), ("Ünïcödé ñ", "unicode-n"),
        ("e\u{301}te\u{301}", "ete"), ("日本語", ""), ("already-clean_1", "already-clean_1"),
    ])
    func sanitizeSlugKeepsOneSafePathSegment(input: String, expected: String) {
        #expect(RssFeedModel.sanitizeSlug(input) == expected)
    }

    @Test func loadReadsTheOpenFeedAndItsAddress() async {
        let open = RssFeed(
            id: "feed-1", entityType: "series", entityId: "series-1", feedUrl: "/feed/my-feed",
            meta: .init(preventIndexing: false, ownerEmail: "owner@example.com"))
        let service = FakeRssFeedService(current: { open })
        let model = RssFeedModel(target: target, service: service)
        #expect(model.slug == "series-1")
        await model.load()
        #expect(model.loadState == .loaded)
        #expect(model.feed == open)
        #expect(model.feedURL?.absoluteString == "https://abs.example/abs/feed/my-feed")
        #expect(service.requests.value == [.current(target)])
    }

    @Test func loadFailureIsReportedUntilARetrySucceeds() async {
        let fails = Locked(true)
        let model = RssFeedModel(
            target: target,
            service: FakeRssFeedService(current: {
                if fails.value { throw TestError.offline }
                return nil
            }))
        await model.load()
        #expect(model.loadState == .failed)
        #expect(model.feed == nil)
        #expect(model.error == .loadFailed)
        fails.value = false
        await model.load()
        #expect(model.loadState == .loaded)
        #expect(model.error == nil)
    }

    @Test func openSendsTheTrimmedFieldsAndTheServerAddress() async {
        let service = FakeRssFeedService()
        let model = RssFeedModel(target: target, service: service)
        await model.load()
        model.slug = "my-feed"
        model.preventIndexing = false
        model.ownerName = "  Ada  "
        model.ownerEmail = " ada@example.com "
        #expect(model.previewURL == "https://abs.example/abs/feed/my-feed")
        #expect(await model.open())
        #expect(model.feed == feed(slug: "my-feed"))
        #expect(model.feedURL?.absoluteString == "https://abs.example/abs/feed/my-feed")
        #expect(model.error == nil)
        let request = RssFeedOpenRequest(
            serverAddress: "https://abs.example/abs", slug: "my-feed",
            metadataDetails: .init(preventIndexing: false, ownerName: "Ada", ownerEmail: "ada@example.com"))
        #expect(service.requests.value == [.current(target), .open(target, request)])
    }

    @Test func emptySlugIsRequiredAndSendsNothing() async {
        let service = FakeRssFeedService()
        let model = RssFeedModel(target: target, service: service)
        for slug in ["", " ?? "] {
            model.slug = slug
            #expect(await !model.open())
            #expect(model.error == .slugRequired)
        }
        #expect(service.requests.value.isEmpty)
    }

    /// Legacy: "Slug had to be modified - Run again". The second open sends the cleaned slug.
    @Test func aSlugThatNeedsCleaningIsReplacedAndMustBeConfirmed() async {
        let service = FakeRssFeedService()
        let model = RssFeedModel(target: target, service: service)
        model.slug = "My Feed!"
        #expect(await !model.open())
        #expect(model.error == .slugChanged)
        #expect(model.slug == "my-feed")
        #expect(service.requests.value.isEmpty)
        #expect(await model.open())
        #expect(model.feed?.feedUrl == "/feed/my-feed")
    }

    @Test(arguments: ["ada", "ada@", "@example.com", "ada@example", "a b@example.com", "ada@example..com"])
    func aMalformedOwnerEmailSendsNothing(email: String) async {
        let service = FakeRssFeedService()
        let model = RssFeedModel(target: target, service: service)
        model.ownerEmail = email
        #expect(await !model.open())
        #expect(model.error == .invalidOwnerEmail)
        #expect(service.requests.value.isEmpty)
    }

    @Test func theServersReasonIsKeptWhenOpenFails() async {
        let model = RssFeedModel(
            target: target,
            service: FakeRssFeedService(open: { _ in throw APIError.http(status: 400, message: "Slug already in use") })
        )
        #expect(await !model.open())
        #expect(model.error == .openFailed(message: "Slug already in use"))
        #expect(model.feed == nil)
        #expect(!model.isWorking)

        let offline = RssFeedModel(target: target, service: FakeRssFeedService(open: { _ in throw TestError.offline }))
        #expect(await !offline.open())
        #expect(offline.error == .openFailed(message: nil))
    }

    @Test func closeSendsTheFeedIDAndClearsIt() async {
        let service = FakeRssFeedService(current: { feed(slug: "open") })
        let model = RssFeedModel(target: target, service: service)
        await model.load()
        #expect(await !model.open())
        #expect(await model.close())
        #expect(model.feed == nil)
        #expect(service.requests.value == [.current(target), .close("feed-open")])
    }

    @Test func aFeedTheServerNoLongerHasClosesWithoutAnError() async {
        let service = FakeRssFeedService(current: { feed(slug: "open") }, close: { throw APIError.notFound })
        let model = RssFeedModel(target: target, service: service)
        await model.load()
        #expect(await model.close())
        #expect(model.feed == nil)
        #expect(model.error == nil)
        #expect(service.requests.value == [.current(target), .close("feed-open")])
    }

    @Test func aRepeatedFailureIsCountedAgain() async {
        let model = RssFeedModel(target: target, service: FakeRssFeedService())
        model.ownerEmail = "ada"
        #expect(model.failureCount == 0)
        await model.open()
        await model.open()
        #expect(model.error == .invalidOwnerEmail)
        #expect(model.failureCount == 2)
    }

    @Test func aFailedCloseKeepsTheFeed() async {
        let model = RssFeedModel(
            target: target,
            service: FakeRssFeedService(
                current: { feed(slug: "open") }, close: { throw APIError.forbidden(message: nil) }))
        #expect(await !model.close())
        await model.load()
        #expect(await !model.close())
        #expect(model.error == .closeFailed)
        #expect(model.feed == feed(slug: "open"))
    }

    @Test func aSecondOpenWhileOneIsRunningSendsNothing() async throws {
        let gate = GatedCalls<String, RssFeed>()
        let service = FakeRssFeedService(open: { try await gate.call($0.slug) })
        let model = RssFeedModel(target: target, service: service)
        let first = Task { await model.open() }
        var calls = gate.calls.makeAsyncIterator()
        let call = try #require(await calls.next())
        #expect(model.isWorking)
        #expect(await !model.open())
        #expect(await !model.close())
        call.reply.resume(returning: feed(slug: call.request))
        #expect(await first.value)
        #expect(!model.isWorking)
        #expect(service.requests.value.count == 1)
    }

    @Test(arguments: [("http://10.0.0.2:13378", true), ("https://abs.example", false), ("HTTP://abs.local", true)])
    func plainHTTPServersAreFlagged(server: String, insecure: Bool) async {
        let model = RssFeedModel(target: target, service: FakeRssFeedService(server: server))
        #expect(!model.isInsecureServer)
        await model.load()
        #expect(model.isInsecureServer == insecure)
    }

    // MARK: Live changes

    @Test func aLiveOpenOrCloseOfThisEntityIsShown() async {
        let model = RssFeedModel(target: target, service: FakeRssFeedService())
        await model.load()
        let opened = feed(slug: "elsewhere")
        model.apply(.opened(opened))
        #expect(model.feed == opened)
        model.apply(.closed(opened))
        #expect(model.feed == nil)
    }

    @Test func otherEntitiesChangesAreIgnored() async {
        let model = RssFeedModel(target: target, service: FakeRssFeedService(current: { feed(slug: "open") }))
        await model.load()
        // Same ID, another kind of entity; then this kind, another ID.
        let collection = RssFeed(id: "feed-col", entityType: "collection", entityId: "series-1", feedUrl: "/feed/c")
        let otherSeries = RssFeed(id: "feed-other", entityType: "series", entityId: "series-2", feedUrl: "/feed/o")
        for change in [
            RssFeedChange.opened(collection), .closed(collection), .opened(otherSeries), .closed(otherSeries),
        ] {
            model.apply(change)
        }
        #expect(model.feed == feed(slug: "open"))
    }

    @Test func theCloseOfAnotherFeedKeepsTheOneShown() async {
        let model = RssFeedModel(target: target, service: FakeRssFeedService(current: { feed(slug: "open") }))
        await model.load()
        model.apply(.closed(feed(slug: "older")))
        #expect(model.feed == feed(slug: "open"))
    }

    @Test(arguments: [RssFeedTarget.Kind.item, .collection, .series])
    func eachKindMatchesTheServersEntityType(kind: RssFeedTarget.Kind) {
        let model = RssFeedModel(target: RssFeedTarget(kind, id: "id-1"), service: FakeRssFeedService())
        let type = ["item": "libraryItem", "collection": "collection", "series": "series"][kind.rawValue]!
        let opened = RssFeed(id: "feed-1", entityType: type, entityId: "id-1", feedUrl: "/feed/one")
        model.apply(.opened(opened))
        #expect(model.feed == opened)
    }

    /// The fetch started before the change, so its answer is older and doesn't replace it.
    @Test(arguments: [true, false])
    func aLoadThatStartedBeforeALiveChangeKeepsTheChange(opens: Bool) async throws {
        let gate = GatedCalls<Void, RssFeed?>()
        let model = RssFeedModel(target: target, service: FakeRssFeedService(current: { try await gate.call(()) }))
        let load = Task { await model.load() }
        var calls = gate.calls.makeAsyncIterator()
        let call = try #require(await calls.next())
        let live = feed(slug: "live")
        model.apply(opens ? .opened(live) : .closed(live))
        call.reply.resume(returning: opens ? nil : live)
        await load.value
        #expect(model.loadState == .loaded)
        #expect(model.feed == (opens ? live : nil))
    }

    /// The open was sent, then the feed closed elsewhere before its answer came back.
    @Test func anOpenAnsweredAfterALiveCloseKeepsTheClose() async throws {
        let gate = GatedCalls<String, RssFeed>()
        let model = RssFeedModel(target: target, service: FakeRssFeedService(open: { try await gate.call($0.slug) }))
        let open = Task { await model.open() }
        var calls = gate.calls.makeAsyncIterator()
        let call = try #require(await calls.next())
        let opened = feed(slug: call.request)
        model.apply(.closed(opened))
        call.reply.resume(returning: opened)
        #expect(await open.value)
        #expect(model.feed == nil)
        #expect(model.hasKnownState)
    }

    /// The close was sent, then another feed opened for the entity before its answer came back.
    @Test(arguments: [false, true])
    func aCloseAnsweredAfterALiveReplacementKeepsTheReplacement(notFound: Bool) async throws {
        let gate = GatedCalls<Void, Void>()
        let model = RssFeedModel(
            target: target,
            service: FakeRssFeedService(current: { feed(slug: "open") }, close: { try await gate.call(()) }))
        await model.load()
        let close = Task { await model.close() }
        var calls = gate.calls.makeAsyncIterator()
        let call = try #require(await calls.next())
        let replacement = feed(slug: "replacement")
        model.apply(.opened(replacement))
        if notFound {
            call.reply.resume(throwing: APIError.notFound)
        } else {
            call.reply.resume(returning: ())
        }
        #expect(await close.value)
        #expect(model.feed == replacement)
    }

    @Test func aLoadThatStartedBeforeAnOpenKeepsTheOpenFeed() async throws {
        let gate = GatedCalls<Void, RssFeed?>()
        let model = RssFeedModel(target: target, service: FakeRssFeedService(current: { try await gate.call(()) }))
        let load = Task { await model.load() }
        var calls = gate.calls.makeAsyncIterator()
        let call = try #require(await calls.next())
        model.slug = "mine"
        #expect(await model.open())
        call.reply.resume(returning: nil)
        await load.value
        #expect(model.feed == feed(slug: "mine"))
    }

    /// Before a load answers, `nil` means unknown; a live close makes it known, and a failed load
    /// after it keeps that.
    @Test func aLiveCloseMakesTheStateKnownWithoutALoad() async {
        let model = RssFeedModel(target: target, service: FakeRssFeedService(current: { throw TestError.offline }))
        #expect(!model.hasKnownState)
        model.apply(.closed(feed(slug: "open")))
        #expect(model.hasKnownState)
        await model.load()
        #expect(model.loadState == .failed)
        #expect(model.hasKnownState)
        #expect(model.feed == nil)
    }

    @Test func aNewModelStartsFromWhatTheLastOneKnew() async {
        let closed = RssFeedModel(target: target, service: FakeRssFeedService(current: { feed(slug: "open") }))
        await closed.load()
        #expect(await closed.close())

        let next = RssFeedModel(target: target, service: FakeRssFeedService())
        next.seed(from: closed)
        #expect(next.hasKnownState)
        #expect(next.feed == nil)

        let unknown = RssFeedModel(target: target, service: FakeRssFeedService())
        let other = RssFeedModel(target: RssFeedTarget(.series, id: "series-2"), service: FakeRssFeedService())
        other.apply(.opened(RssFeed(id: "f2", entityType: "series", entityId: "series-2", feedUrl: "/feed/two")))
        for previous in [unknown, other] {
            let fresh = RssFeedModel(target: target, service: FakeRssFeedService())
            fresh.seed(from: previous)
            #expect(!fresh.hasKnownState)
        }
    }
}
