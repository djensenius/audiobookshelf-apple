import ABSAPI
import ABSAppModel
import ABSCore
import ABSUI
import SwiftUI
import Testing

@testable import Audiobookshelf

#if canImport(AppKit)
    import AppKit
#elseif canImport(UIKit)
    import UIKit
#endif

/// A client that serves no libraries.
private struct EmptyLibraryService: LibraryService {
    struct Failure: Error {}
    func libraries() async throws -> [Library] { [] }
    func library(id: String) async throws -> LibraryWithFilterData { throw Failure() }
    func personalizedShelves(libraryID: String) async throws -> [Shelf] { [] }
    func items(libraryID: String, query: LibraryQuery) async throws -> PagedResults<ABSCore.LibraryItem> {
        throw Failure()
    }
}

private let account = LibraryConnectionKey(connectionID: UUID(), userID: "user-1")

/// What a probe screen inside the shell saw in its environment.
@MainActor
private final class ShellSighting {
    var store: LibraryStore?
    var itemActions: (any ItemActionPerforming)?
    var progress: ItemProgress?
}

/// Stands in for a screen in the shell and records its environment as it reads it.
private struct ShellProbe: View {
    let sighting: ShellSighting
    @Environment(\.libraryStore) private var store
    @Environment(\.itemActions) private var itemActions
    @Environment(\.itemProgressReader) private var progressReader

    var body: some View {
        let _ = record()
        Color.clear
    }

    private func record() {
        sighting.store = store
        sighting.itemActions = itemActions
        sighting.progress = progressReader(itemID: "li_1", episodeID: nil)
    }
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

/// A store connected to `account` with settings in a throwaway defaults suite, and `li_1` finished.
@MainActor
private func withStore(_ body: (LibraryStore) async throws -> Void) async throws {
    let suiteName = "AccountShellEnvironmentTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = LibraryStore(settings: AppSettings(defaults: defaults))
    await store.connect(client: EmptyLibraryService(), connectionKey: account)
    let progress = MediaProgress(id: "mp_1", libraryItemId: "li_1", progress: 1, isFinished: true)
    #expect(store.progress.seed([progress], token: store.progress.beginSeed()))
    try await body(store)
}

@MainActor
@Suite struct AccountShellEnvironmentTests {
    /// The signed-in shell gives its screens the account's store, its progress and real item
    /// actions on that store.
    @Test func signedInShellInjectsTheAccountsActions() async throws {
        try await withStore { store in
            let sighting = ShellSighting()
            render(AccountShell(store: store) { ShellProbe(sighting: sighting) })

            #expect(sighting.store === store)
            #expect(sighting.itemActions is ProgressItemActions)
            #expect(sighting.progress?.isFinished == true)
        }
    }

    /// Signed out, or a switch's outgoing shell once the store serves the next account: the
    /// signed-out defaults.
    @Test func signedOutShellInjectsNoActions() {
        let sighting = ShellSighting()
        render(AccountShell(store: nil) { ShellProbe(sighting: sighting) })

        #expect(sighting.store == nil)
        #expect(sighting.itemActions is NoOpItemActions)
        #expect(sighting.progress == nil)
    }

    /// The values are built once for the store and shared by every read, so the actions' per-item
    /// queue is one per session; another store gets its own.
    @Test func valuesAreBuiltOncePerStore() async throws {
        try await withStore { store in
            let cache = AccountShellValuesCache()
            #expect(cache.values(for: nil) == nil)
            let values = try #require(cache.values(for: store))
            #expect(cache.values(for: store) === values)
            #expect(cache.values(for: store)?.itemActions as AnyObject === values.itemActions as AnyObject)

            try await withStore { other in
                #expect(cache.values(for: other)?.store === other)
            }
        }
    }
}
