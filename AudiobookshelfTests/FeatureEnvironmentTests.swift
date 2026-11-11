import ABSAppModel
import ABSUI
import SwiftUI
import Testing

@testable import Audiobookshelf

#if canImport(AppKit)
    import AppKit
#elseif canImport(UIKit)
    import UIKit
#endif

/// What a probe screen saw in its environment.
@MainActor
private final class Sighting {
    var router: Router?
    var libraryID: String?
    var libraryKind: LibraryKind?
}

/// Stands in for a tab's root screen and records the scene's router as a screen reads it.
private struct RouterProbe: View {
    let sighting: Sighting
    @Environment(Router.self) private var router: Router?

    var body: some View {
        let _ = record()
        Color.clear
    }

    private func record() {
        sighting.router = router
        sighting.libraryID = router?.libraryID
        sighting.libraryKind = router?.libraryKind
    }
}

@MainActor
@Suite struct FeatureEnvironmentTests {
    @Test func defaultsAreSignedOut() {
        let values = EnvironmentValues()

        #expect(values.libraryStore == nil)
        #expect(values.serverID == nil)
        #expect(values.itemActions is NoOpItemActions)
        #expect(values.playItem == nil)
        // Declared in ABSUI; listed in `FeatureEnvironment.swift`.
        #expect(values.imagePipeline == nil)
        #expect(values.itemProgressReader(itemID: "li_1", episodeID: nil) == nil)
    }

    @Test func screensInTheTabsSeeTheScenesRouter() {
        let router = Router()
        router.selectLibrary(id: "lib_1", kind: .podcast, supportedSections: [])
        let sighting = Sighting()
        let view = MainTabView(router: router, player: PlaceholderPlayerState()) { _, _ in
            RouterProbe(sighting: sighting)
        }

        #if canImport(AppKit)
            let host = NSHostingView(rootView: view)
            host.frame = CGRect(x: 0, y: 0, width: 800, height: 600)
            host.layoutSubtreeIfNeeded()
        #else
            let host = UIHostingController(rootView: view)
            host.view.frame = CGRect(x: 0, y: 0, width: 800, height: 600)
            host.view.layoutIfNeeded()
        #endif

        #expect(sighting.router === router)
        #expect(sighting.libraryID == "lib_1")
        #expect(sighting.libraryKind == .podcast)
    }
}
