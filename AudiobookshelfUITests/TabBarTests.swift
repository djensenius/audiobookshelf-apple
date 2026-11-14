import XCTest

/// The compact tab bar (#617): Home, Library, Downloads, Account and Search, with no More tab. The
/// library's sections are sidebar-only tabs; in compact width the Library root's section menu
/// (`library.sectionPicker`) reaches them instead. A Mac and a regular-width iPad show the sidebar,
/// so these tests skip there.
final class TabBarTests: XCTestCase {
    /// The section tabs' identifiers (`tab.<AppTab raw value>`), none of which is in the tab bar.
    private static let sectionTabs = ["series", "collections", "authors", "playlists", "latest", "addPodcast"]
        .map { "tab.\($0)" }

    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testTabBarHasEveryTabAndNoMore() throws {
        let app = try signInCompact()
        for tab in ["home", "library", "downloads", "account", "search"] {
            let button = app.buttons["tab.\(tab)"].firstMatch
            XCTAssertTrue(button.exists && button.isHittable, "The tab bar has no \(tab) tab")
        }
        let section = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier IN %@", Self.sectionTabs)).firstMatch
        XCTAssertFalse(section.exists, "A library section (\(section.identifier)) is in the tab bar")
        // The More tab's symbol, which the app doesn't use.
        XCTAssertFalse(
            app.buttons.containing(.image, identifier: "ellipsis").firstMatch.exists, "The tab bar has a More tab")
    }

    @MainActor
    func testSectionPickerSwitchesTheLibraryRoot() throws {
        let app = try signInCompact()
        let library = open(.library, in: app)
        let series = app.descendants(matching: .any)["series.screen"].firstMatch
        chooseSection(symbol: "rectangle.stack", in: app)
        XCTAssertTrue(series.waitForExistence(timeout: Self.fixtureTimeout), "The Series section didn't appear")
        XCTAssertTrue(library.waitForNonExistence(timeout: Self.fixtureTimeout), "The library grid didn't go")
        chooseSection(symbol: "books.vertical", in: app)
        XCTAssertTrue(library.waitForExistence(timeout: Self.fixtureTimeout), "The library grid didn't come back")
        XCTAssertTrue(series.waitForNonExistence(timeout: Self.fixtureTimeout), "The Series section didn't go")
    }

    /// Signs in, and skips unless the window is compact width, where there's a tab bar.
    @MainActor
    private func signInCompact() throws -> XCUIApplication {
        #if os(iOS)
            let app = signIn()
            try XCTSkipUnless(
                app.windows.firstMatch.horizontalSizeClass == .compact, "A regular-width window shows the sidebar")
            return app
        #else
            throw XCTSkip("A Mac shows the sidebar")
        #endif
    }

    /// Chooses the entry with `symbol` (its `AppTab.systemImage`; `books.vertical` is the grid)
    /// from the Library root's section menu (`library.sectionPicker`). SwiftUI gives a menu's
    /// entries no identifiers, so they're found by symbol, which isn't localized. A crowded
    /// vertical bar (the Duo's outer display) moves the menu into its overflow menu, titled with
    /// the section shown: on the grid, the Library tab's title.
    @MainActor
    private func chooseSection(symbol: String, in app: XCUIApplication) {
        var picker = app.buttons["library.sectionPicker"].firstMatch
        if !picker.waitForExistence(timeout: 3) {
            let overflow = app.buttons["BottomOverflowBarButtonItem"].firstMatch
            XCTAssertTrue(overflow.exists, "The Library root has no section menu, and its bar has no overflow menu")
            overflow.press()
            let title = app.buttons["tab.library"].firstMatch.label
            picker = app.collectionViews.buttons.matching(NSPredicate(format: "label == %@", title)).firstMatch
            XCTAssertTrue(
                picker.waitForExistence(timeout: Self.fixtureTimeout), "The overflow menu has no section menu")
        }
        picker.press()
        let entries = app.collectionViews.buttons.containing(.image, identifier: symbol)
        XCTAssertTrue(
            entries.firstMatch.waitForExistence(timeout: Self.fixtureTimeout),
            "The section menu has no \(symbol) entry")
        // A submenu opened from the overflow menu starts with its own title row.
        entries.element(boundBy: entries.count - 1).press()
    }
}
