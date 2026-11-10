import Foundation
import Testing

@testable import ABSAppModel

@MainActor
@Suite struct RouterSceneTests {
    private let identity = SessionIdentity(
        connectionID: UUID(uuidString: "6F1E7C2A-3B4D-4E5F-8A9B-0C1D2E3F4A5B")!, userID: "user-1")

    /// A scene saved in regular width on Series, with a series screen open.
    private func regularWidthSnapshot(of identity: SessionIdentity) throws -> Data {
        let snapshot = Router.Snapshot(
            serverID: identity.connectionID.uuidString, userID: identity.userID, selectedTab: .series,
            libraryID: "books", libraryKind: .book, paths: [.series: [.series(id: "se_1")]])
        return try JSONEncoder().encode(snapshot)
    }

    @Test func identityBecomesTheServerAndUser() {
        let router = Router(identity: identity)
        #expect(router.serverID == "6F1E7C2A-3B4D-4E5F-8A9B-0C1D2E3F4A5B")
        #expect(router.userID == "user-1")
    }

    @Test func routerOfAnIdentityRestoresItsOwnSnapshot() throws {
        let saved = Router(identity: identity)
        saved.selectedTab = .downloads
        saved[path: .downloads] = [.localFolder(id: "lf_1")]
        saved.isQueueInspectorPresented = true

        let restored = Router(identity: identity)
        restored.restoreScene(from: saved.snapshotData, isCompact: false, opening: nil)

        #expect(restored.selectedTab == .downloads)
        #expect(restored[path: .downloads] == [.localFolder(id: "lf_1")])
        #expect(restored.isQueueInspectorPresented)
    }

    @Test func snapshotOfAnotherIdentityIsDiscarded() {
        let saved = Router(identity: SessionIdentity(connectionID: identity.connectionID, userID: "user-2"))
        saved.selectedTab = .downloads
        saved[path: .account] = [.settings]

        let restored = Router(identity: identity)
        restored.restoreScene(from: saved.snapshotData, isCompact: false, opening: nil)

        #expect(restored.selectedTab == .home)
        #expect(restored[path: .account].isEmpty)
    }

    @Test func compactWidthMovesARestoredSectionIntoLibrary() throws {
        let router = Router(identity: identity)
        router.restoreScene(from: try regularWidthSnapshot(of: identity), isCompact: true, opening: nil)

        #expect(router.selectedTab == .library)
        #expect(router.librarySection == .series)
        #expect(router[path: .library] == [.series(id: "se_1")])
        #expect(router[path: .series].isEmpty)
    }

    @Test func regularWidthKeepsARestoredSection() throws {
        let router = Router(identity: identity)
        router.restoreScene(from: try regularWidthSnapshot(of: identity), isCompact: false, opening: nil)

        #expect(router.selectedTab == .series)
        #expect(router.librarySection == nil)
        #expect(router[path: .series] == [.series(id: "se_1")])
    }

    @Test func linkOpensOnTheRestoredAndNormalizedScene() throws {
        let router = Router(identity: identity)
        let link = DeepLink(.item(id: "li_1", episodeID: nil))
        router.restoreScene(from: try regularWidthSnapshot(of: identity), isCompact: true, opening: link)

        // The section's screen is already in Library, so the item lands on top of it.
        #expect(router.selectedTab == .library)
        #expect(router[path: .library] == [.series(id: "se_1"), .item(id: "li_1")])
    }

    @Test func restoreDoesNotWipeTheLinkTheSceneOpens() {
        let router = Router(identity: identity)
        router.restoreScene(from: nil, isCompact: false, opening: DeepLink(.search(query: "dune")))

        #expect(router.selectedTab == .search)
        #expect(router.pendingSearchQuery == "dune")
    }

    @Test func linkOpensOnADefaultSceneWhenNothingWasSaved() {
        let router = Router(identity: identity)
        router.restoreScene(from: nil, isCompact: true, opening: DeepLink(.downloads))
        #expect(router.selectedTab == .downloads)
    }

    @Test func linkForAnotherServerWaitsForConfirmation() {
        let router = Router(identity: identity)
        let link = DeepLink(.downloads, serverID: "00000000-0000-0000-0000-000000000001")
        router.restoreScene(from: nil, isCompact: false, opening: link)

        #expect(router.pendingServerSwitch == link)
        #expect(router.selectedTab == .home)
    }

    @Test func noLinkChangesNothingAfterTheRestore() throws {
        let router = Router(identity: identity)
        router.restoreScene(from: try regularWidthSnapshot(of: identity), isCompact: false, opening: nil)

        #expect(router.pendingServerSwitch == nil)
        #expect(router.pendingPlayLink == nil)
        #expect(router.pendingSearchQuery == nil)
        #expect(!router.isFullPlayerPresented)
    }
}
