import Foundation
import Testing

@testable import ABSAppModel

@MainActor
@Suite struct SceneNavigationTests {
    private let identity = SessionIdentity(
        connectionID: UUID(uuidString: "6F1E7C2A-3B4D-4E5F-8A9B-0C1D2E3F4A5B")!, userID: "user-1")

    @Test func savesNothingBeforeTheRestore() {
        let scene = SceneNavigation(identity: identity)
        #expect(!scene.isRestored)
        #expect(scene.snapshotToSave == nil)

        scene.restoreOnce(from: nil, isCompact: false, opening: nil)
        #expect(scene.isRestored)
        #expect(scene.snapshotToSave != nil)
    }

    @Test func savesTheLinkThatLaunchedTheScene() {
        let scene = SceneNavigation(identity: identity)
        scene.restoreOnce(from: nil, isCompact: false, opening: DeepLink(.downloads))

        let saved = Router(identity: identity)
        saved.restore(from: scene.snapshotToSave)
        #expect(saved.selectedTab == .downloads)
    }

    @Test func restoresOnlyOnce() {
        let scene = SceneNavigation(identity: identity)
        #expect(scene.restoreOnce(from: nil, isCompact: false, opening: nil))
        scene.router.selectedTab = .downloads

        #expect(!scene.restoreOnce(from: nil, isCompact: false, opening: DeepLink(.search(query: "dune"))))
        #expect(scene.router.selectedTab == .downloads)
        #expect(scene.router.pendingSearchQuery == nil)
    }

    @Test func opensNoLinkBeforeTheRestore() {
        let scene = SceneNavigation(identity: identity)
        #expect(!scene.open(DeepLink(.downloads)))
        #expect(scene.router.selectedTab == .home)

        scene.restoreOnce(from: nil, isCompact: false, opening: nil)
        #expect(scene.open(DeepLink(.downloads)))
        #expect(scene.router.selectedTab == .downloads)
    }

    @Test func gateBecomesWhatTheRootShows() {
        let failure = SessionStoreError(CocoaError(.fileWriteOutOfSpace))
        #expect(SceneContent(.launching) == .loading)
        #expect(SceneContent(.signingOut(from: identity)) == .loading)
        #expect(SceneContent(.connect) == .connect)
        #expect(SceneContent(.storeUnavailable(failure)) == .storeUnavailable)
        #expect(SceneContent(.ready(identity, isOffline: false)) == .shell(identity, opensLinks: true))
        #expect(SceneContent(.ready(identity, isOffline: true)) == .shell(identity, opensLinks: true))
    }

    @Test func aSwitchKeepsTheShellButLeavesLinksForTheNextOne() {
        // The same case and identity as a ready session, so the root keeps the shell, and only
        // `opensLinks` differs.
        #expect(SceneContent(.switching(from: identity)) == .shell(identity, opensLinks: false))
    }

    @Test func linksWaitOnlyWhereASignedInSceneCanTakeThem() {
        let failure = SessionStoreError(CocoaError(.fileWriteOutOfSpace))
        let held: [AuthGate] = [
            .launching, .signingOut(from: identity), .ready(identity, isOffline: false),
            .switching(from: identity),
        ]
        for gate in held {
            #expect(SceneContent(gate).holdsLinks, "\(gate)")
        }
        #expect(!SceneContent(.connect).holdsLinks)
        #expect(!SceneContent(.storeUnavailable(failure)).holdsLinks)
    }
}
