import ABSAPI
import ABSAppModel
import ABSCore
import ABSUI
import Foundation
import SwiftUI
import Testing

@testable import Audiobookshelf

#if canImport(AppKit)
    import AppKit
#elseif canImport(UIKit)
    import UIKit
#endif

/// A client that serves no libraries, and isn't an `APIClient`.
private struct NoLibraries: LibraryService {
    struct Failure: Error {}
    func libraries() async throws -> [Library] { [] }
    func library(id: String) async throws -> LibraryWithFilterData { throw Failure() }
    func personalizedShelves(libraryID: String) async throws -> [Shelf] { [] }
    func items(libraryID: String, query: LibraryQuery) async throws -> PagedResults<ABSCore.LibraryItem> {
        throw Failure()
    }
}

/// `/ping` is unauthenticated; the client still asks.
private struct NoTokens: TokenProvider {
    func tokens() async -> AuthTokens? { nil }
    func replaceTokens(expected: AuthTokens, with new: AuthTokens) async -> Bool { false }
    func expireSession(ifCurrent rejected: AuthTokens) async -> Bool { false }
}

/// Reports one path and stays open.
private struct OnePath: NetworkPathSource {
    let path: NetworkPath
    func paths() -> AsyncStream<NetworkPath> {
        AsyncStream { $0.yield(path) }
    }
}

private let account = LibraryConnectionKey(connectionID: UUID(), userID: "user-1")

@MainActor
@Suite(.timeLimit(.minutes(1))) struct ConnectionBannerHostTests {
    /// A store serving `account` through `client`, with settings in a throwaway defaults suite.
    private func withStore(client: any LibraryService, _ body: (LibraryStore) async throws -> Void) async throws {
        let suiteName = "ConnectionBannerHostTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = LibraryStore(settings: AppSettings(defaults: defaults))
        store.attach(client: client, connectionKey: account)
        try await body(store)
    }

    private func fixtureClient() throws -> APIClient {
        APIClient(
            configuration: try APIClientConfiguration(baseURL: try #require(URL(string: FixtureServer.address))),
            tokenProvider: NoTokens(), sessionConfiguration: FixtureServer.sessionConfiguration())
    }

    /// Runs `session` until its banner shows a status that satisfies `expected`, and returns whether it did.
    private func runs(
        _ session: ConnectionBannerSession, until expected: (ConnectionBannerStatus?) -> Bool
    ) async throws -> Bool {
        let task = Task { await session.run() }
        defer { task.cancel() }
        for _ in 0..<500 {
            if expected(ConnectionBannerPresentation.status(for: session.model.state)) { return true }
            try await Task.sleep(for: .milliseconds(10))
        }
        return false
    }

    @Test func statesMapToBannerStatuses() {
        let date = Date(timeIntervalSince1970: 1_000)
        #expect(ConnectionBannerPresentation.status(for: .online) == nil)
        #expect(ConnectionBannerPresentation.status(for: .offline(.noNetwork)) == .offline)
        #expect(ConnectionBannerPresentation.status(for: .serverUnreachable(retryAt: nil)) == .checking)
        #expect(
            ConnectionBannerPresentation.status(for: .serverUnreachable(retryAt: date))
                == .serverUnreachable(retryAt: date))
    }

    /// The ping goes through the store's `APIClient`: the fixture server answers, so it stays hidden.
    @Test func pingsThroughTheStoresClient() async throws {
        try await withStore(client: try fixtureClient()) { store in
            try await ConnectionBannerSession.ping(store: store, account: account)()
        }
    }

    /// Without an `APIClient` the ping fails; once the store serves another account it's cancelled,
    /// which the banner ignores.
    @Test func pingFailsWithoutAClientAndCancelsForAnotherAccount() async throws {
        try await withStore(client: NoLibraries()) { store in
            await #expect(throws: ConnectionBannerSession.PingError.self) {
                try await ConnectionBannerSession.ping(store: store, account: account)()
            }
            let other = LibraryConnectionKey(connectionID: UUID(), userID: "user-2")
            await #expect(throws: CancellationError.self) {
                try await ConnectionBannerSession.ping(store: store, account: other)()
            }
        }
    }

    /// The shell's session follows its monitor and pings the store: no network shows offline; a
    /// network without a usable client shows the server as unreachable, with Retry.
    @Test func sessionFollowsTheNetworkAndThePing() async throws {
        try await withStore(client: NoLibraries()) { store in
            let offline = ConnectionBannerSession(
                store: store,
                monitor: NetworkMonitor(source: OnePath(path: NetworkPath(isOnline: false, interface: nil))))
            let showedOffline = try await runs(offline) { $0 == .offline }
            #expect(showedOffline)

            let online = ConnectionBannerSession(
                store: store,
                monitor: NetworkMonitor(source: OnePath(path: NetworkPath(isOnline: true, interface: .wifi))))
            let showedUnreachable = try await runs(online) { $0?.offersRetry == true }
            #expect(showedUnreachable)
        }
    }

    /// The signed-in shell gives its screens its banner session; signed out there is none.
    @Test func shellInjectsItsBannerSession() async throws {
        try await withStore(client: NoLibraries()) { store in
            let seen = SeenSession()
            render(AccountShell(store: store) { BannerProbe(seen: seen) })
            #expect(seen.session != nil)

            let signedOut = SeenSession()
            render(AccountShell(store: nil) { BannerProbe(seen: signedOut) })
            #expect(signedOut.session == nil)
        }
    }
}

/// What ``BannerProbe`` read from its environment.
@MainActor
private final class SeenSession {
    var session: ConnectionBannerSession?
}

/// Stands in for a screen in the shell and records the banner session it reads.
private struct BannerProbe: View {
    let seen: SeenSession
    @Environment(\.connectionBanner) private var session

    var body: some View {
        let _ = record()
        Color.clear
    }

    private func record() { seen.session = session }
}

/// Renders `view` once, so its body reads the environment.
@MainActor
private func render(_ view: some View) {
    #if canImport(AppKit)
        let host = NSHostingView(rootView: view)
        host.frame = CGRect(x: 0, y: 0, width: 400, height: 300)
        host.layoutSubtreeIfNeeded()
    #else
        let host = UIHostingController(rootView: view)
        host.view.frame = CGRect(x: 0, y: 0, width: 400, height: 300)
        host.view.layoutIfNeeded()
    #endif
}
