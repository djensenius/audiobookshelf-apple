import ABSAppModel
import ABSCore
import ABSUI
import Testing

@testable import Audiobookshelf

@Suite struct PlayerPresentationTests {
    /// At accessibility text sizes the regular accessory drops the cover, author and jumps but
    /// keeps close; the inline accessory keeps only play/pause.
    @Test func theMiniPlayerReducesAtAccessibilitySizes() {
        typealias Layout = MiniPlayerView.Layout
        #expect(Layout.pick(isInline: false, isAccessibilitySize: false) == .regular)
        #expect(Layout.pick(isInline: false, isAccessibilitySize: true) == .accessibility)
        #expect(Layout.pick(isInline: true, isAccessibilitySize: true) == .inline)
        #expect(Layout.pick(isInline: true, isAccessibilitySize: false) == .inline)
        #expect(Layout.accessibility.transportStyle == .playPauseOnly)
        #expect(!Layout.accessibility.showsCoverAndAuthor)
        #expect(Layout.accessibility.showsCloseAndProgress)
        #expect(Layout.regular.transportStyle == .compact)
        #expect(!Layout.inline.showsCloseAndProgress)
    }

    /// The players' covers (#336) take the playing item's library's setting, else the current library's.
    @Test func coverSettingsComeFromTheItemsLibraryElseTheCurrentOne() {
        let libraries = [
            Library(
                id: "lib_standard", name: "Standard", mediaType: .book,
                settings: LibrarySettings(coverAspectRatio: 0)),
            Library(
                id: "lib_square", name: "Square", mediaType: .book, settings: LibrarySettings(coverAspectRatio: 1)),
        ]
        func settings(_ libraryID: String?, current: String?) -> LibrarySettings? {
            LibraryCoverSettings.settings(forLibrary: libraryID, current: current) { id in
                libraries.first { $0.id == id }
            }
        }
        #expect(settings("lib_square", current: "lib_standard")?.coverAspectRatio == 1)
        #expect(settings("lib_gone", current: "lib_standard")?.coverAspectRatio == 0)
        #expect(settings(nil, current: "lib_square")?.coverAspectRatio == 1)
        #expect(settings(nil, current: nil) == nil)
    }

    @Test func theFullPlayerClosesOnlyWhenPresentedWithoutASession() {
        #expect(PlayerSlot.presentsWithoutSession(isPresented: true, hasSession: false))
        #expect(!PlayerSlot.presentsWithoutSession(isPresented: true, hasSession: true))
        #expect(!PlayerSlot.presentsWithoutSession(isPresented: false, hasSession: false))
        #expect(!PlayerSlot.presentsWithoutSession(isPresented: false, hasSession: true))
    }
}
