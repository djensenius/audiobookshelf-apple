import XCTest

/// The screens a fixture test can open from the signed-in app (`signIn(launchArguments:screenshotPrefix:)`),
/// with `open(_:in:)`. Accessibility audits and screenshots walk them in this order.
enum FixtureScreen: String, CaseIterable {
    case home, library, item, player, settings, downloads
    /// Screens with an accent-filled button (`ABSColor.onAccent` labels, #645), which only the dark
    /// and black audits walk (``accentButtonScreens``): an item the fixtures don't have (a 404, so
    /// `ErrorStateView`'s Retry), the Player's bookmarks (Create Bookmark) and *Barsoom* (Continue
    /// Series). They're iOS only.
    case missingItem, bookmarks, series

    /// The screens with an accent-filled button, after the others: Series last, since it leaves
    /// the Library tab on its Series section. None on macOS, where they aren't wired up.
    static var accentButtonScreens: [FixtureScreen] {
        #if os(iOS)
            [.missingItem, .bookmarks, .series]
        #else
            []
        #endif
    }

    /// The screens an audit walks, in order: the accent-filled buttons' screens only in a dark
    /// theme, where their labels changed colour (#645).
    static func audited(inDarkTheme: Bool) -> [FixtureScreen] {
        [.home, .library, .item, .player, .settings, .downloads] + (inDarkTheme ? accentButtonScreens : [])
    }

    /// The screen's accessibility identifier: `<screen>.screen`, `item.detail` for the item (found
    /// or missing), or the accent-filled button of Bookmarks and Series.
    var identifier: String {
        switch self {
        case .item, .missingItem: "item.detail"
        case .bookmarks: "bookmarks.create"
        case .series: "series.continue"
        default: "\(rawValue).screen"
        }
    }

    /// The screen's name in failure messages.
    var name: String {
        switch self {
        case .home: "Home"
        case .library: "Library"
        case .item: "Item detail"
        case .player: "Player"
        case .settings: "Settings"
        case .downloads: "Downloads"
        case .missingItem: "Missing item"
        case .bookmarks: "Bookmarks"
        case .series: "Series"
        }
    }
}

extension XCTestCase {
    /// Opens `screen` in the signed-in `app` and waits for its loaded content, then returns the
    /// screen's element (`FixtureScreen/identifier`). Any screen can follow any other:
    ///
    /// - Home, Library and Downloads are their tabs; Home waits for its shelves, Library for
    ///   *Pride and Prejudice*'s card and Downloads for its list or empty state.
    /// - Item detail opens *Pride and Prejudice* from Library, opening Library first unless its
    ///   card is on screen, and waits for its title.
    /// - Player plays *Pride and Prejudice* (the one fixture item that plays; see
    ///   docs/testing/ui-tests.md) from its screen, opened as above unless it's on screen, then
    ///   opens the full player from the mini player, and pauses, so the times hold still (a
    ///   changing label can fail an audit's contrast check). The mini player stays after it's
    ///   minimized.
    /// - Settings is pushed from the Account tab on iOS, and is the Settings window (⌘,) on macOS;
    ///   it's reused if it's already open.
    /// - Missing item opens *Emma* from Library, as Item detail does: it has no item fixture, so
    ///   its screen is the not-found error, and waits for its Retry button (`state.retry`).
    /// - Bookmarks opens the Player as above, then its bookmarks sheet (`player.bookmarks`, in the
    ///   overflow menu of a vertical bar), and waits for Create Bookmark.
    /// - Series chooses the Series section (the sidebar's tab, or the Library root's section menu
    ///   in compact width), then *Barsoom*, and waits for Continue Series. Library switches the
    ///   Library root back to the grid.
    ///
    /// Tabs keep their navigation stacks, so before leaving a screen (other than for the player)
    /// and after selecting a tab, the helper goes back to the tab's root.
    ///
    /// On iOS the full player covers the tabs, so it's minimized before any other screen opens, and
    /// the bookmarks sheet, which covers the player, is closed first; on macOS the Now Playing and
    /// Settings windows are closed instead.
    @MainActor
    @discardableResult
    func open(_ screen: FixtureScreen, in app: XCUIApplication) -> XCUIElement {
        let element = app.descendants(matching: .any)[screen.identifier].firstMatch
        // Settings and Bookmarks are reused if they're open; Player checks below.
        if [.settings, .bookmarks].contains(screen) && element.exists { return element }
        closeBookmarks(in: app)
        if screen != .player && screen != .bookmarks {
            closePlayer(in: app)
            // Tabs keep their stacks: leave this one at its root, so coming back to it shows the root.
            popToRoot(in: app)
        }
        #if os(macOS)
            if screen != .settings { closeWindow(containing: FixtureScreen.settings.identifier, in: app) }
        #endif
        switch screen {
        case .home:
            openTab(.home, in: app)
            // `home.screen` is there while the shelves load; the first card of the first shelf (Continue Listening) in
            // `fixture-personalized.json` once they have.
            waitForCard("item.li_frankenstein", in: element, of: screen.name, failure: "Home's shelves didn't appear")
        case .library:
            openTab(.library, in: app)
            // Series (below) leaves the compact Library root on its Series section.
            if app.descendants(matching: .any)["series.screen"].exists {
                chooseSection(symbol: "books.vertical", in: app)
            }
            // The first card of `fixture-items.json`.
            waitForCard("item.li_pride", in: element, of: screen.name, failure: "The library's items didn't appear")
        case .item, .missingItem:
            // Emma, the second card of `fixture-items.json`, has no `fixture-item-li_emma.json`: a 404.
            let id = screen == .item ? "item.li_pride" : "item.li_emma"
            let card = app.descendants(matching: .any)[FixtureScreen.library.identifier]
                .descendants(matching: .any)[id].firstMatch
            if !(card.exists && card.isHittable) { open(.library, in: app) }
            card.press()
            XCTAssertTrue(element.waitForExistence(timeout: Self.fixtureTimeout), "The item screen didn't appear")
            let loaded = element.descendants(matching: .any)[screen == .item ? "item.title" : "state.retry"]
            XCTAssertTrue(
                loaded.waitForExistence(timeout: Self.fixtureTimeout),
                screen == .item ? "The item didn't load" : "The missing item's Retry didn't appear")
        case .player:
            // Already open: just make sure it's paused (pausing is idempotent).
            guard !element.exists else {
                pause(in: app)
                break
            }
            let play = app.buttons["item.play"].firstMatch
            if !(play.exists && play.isHittable) { open(.item, in: app) }
            XCTAssertTrue(play.waitForEnabled(timeout: Self.fixtureTimeout), "The item's Play button isn't enabled")
            play.press()
            let mini = app.buttons["player.mini"].firstMatch
            XCTAssertTrue(mini.waitForExistence(timeout: Self.fixtureTimeout), "The mini player didn't appear")
            mini.press()
            XCTAssertTrue(element.waitForExistence(timeout: Self.fixtureTimeout), "The full player didn't appear")
            pause(in: app)
        case .settings:
            #if os(macOS)
                app.typeKey(",", modifierFlags: .command)
            #else
                openTab(.account, in: app)
                let link = app.descendants(matching: .any)["account.settings"].firstMatch
                // The list is lazy: at large text sizes the Settings row is below the fold, and
                // isn't in the hierarchy until it's scrolled to. Swipe the Account list itself: the
                // first collection view is a regular-width iPad's sidebar.
                if !link.waitForExistence(timeout: 5) {
                    let list = app.descendants(matching: .any)["account.screen"].firstMatch
                    for _ in 0..<6 where !link.exists { list.swipeUp() }
                }
                XCTAssertTrue(
                    link.waitForExistence(timeout: Self.fixtureTimeout), "The Account tab has no Settings row")
                link.press()
            #endif
            XCTAssertTrue(element.waitForExistence(timeout: Self.fixtureTimeout), "The Settings screen didn't appear")
        case .downloads:
            openTab(.downloads, in: app)
            XCTAssertTrue(element.waitForExistence(timeout: Self.fixtureTimeout), "The Downloads screen didn't appear")
            // The fixtures' download stack starts empty (`FixtureServer.downloadsDirectory`): the empty state, or the
            // list once a test has downloaded something, replaces the loading indicator once the downloads are read.
            let content = element.descendants(matching: .any)
                .matching(NSPredicate(format: "identifier IN %@", ["downloads.empty", "downloads.list"])).firstMatch
            // The screen's identifier replaces the list's (`downloads.list`), so the loaded list is the screen itself.
            let lists: [XCUIElement.ElementType] = [.collectionView, .table, .outline]
            XCTAssertTrue(
                wait(for: { content.exists || lists.contains(element.elementType) }, timeout: Self.fixtureTimeout),
                "The downloads didn't load")
        case .bookmarks:
            #if os(iOS)
                open(.player, in: app)
                var button = app.buttons["player.bookmarks"].firstMatch
                // A vertical bar (the iPhone Duo's outer display) has it in its overflow menu, whose
                // entries have no identifiers: found by symbol, as in `chooseSection`.
                if !(button.waitForExistence(timeout: 3) && button.isHittable) {
                    let overflow = app.buttons["BottomOverflowBarButtonItem"].firstMatch
                    XCTAssertTrue(overflow.exists, "The player has no bookmarks button, and no overflow menu")
                    overflow.press()
                    button =
                        app.collectionViews.buttons.containing(
                            NSPredicate(format: "identifier IN %@", ["bookmark", "bookmark.fill"])
                        ).firstMatch
                }
                XCTAssertTrue(button.waitForEnabled(timeout: Self.fixtureTimeout), "The bookmarks button isn't enabled")
                button.press()
                XCTAssertTrue(
                    element.waitForExistence(timeout: Self.fixtureTimeout),
                    "The bookmarks' Create Bookmark didn't appear")
                // At the medium detent the sheet is glass over the player, and the audit fails its white
                // text (Done, "No Bookmarks") though the pixels measure 8.5:1 and 12.6:1; at the large
                // detent it's opaque. Dragged up by its navigation bar.
                let bar = app.navigationBars.containing(.button, identifier: "player.sheet.done").firstMatch
                if bar.exists {
                    bar.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.5)).press(
                        forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.05)))
                }
                // The sheet slides: let it settle, so the audit measures it at rest.
                var frame = CGRect.null
                XCTAssertTrue(
                    wait(
                        for: {
                            defer { frame = element.frame }
                            return element.frame == frame
                        }, timeout: Self.fixtureTimeout),
                    "The bookmarks sheet didn't settle")
            #else
                XCTFail("Bookmarks is iOS only (FixtureScreen.accentButtonScreens)")
            #endif
        case .series:
            #if os(iOS)
                openTab(.library, in: app)
                // A sidebar (regular width) has a Series tab; a compact Library root has its section menu.
                // A regular-width iPad's top tab bar leaves Series to its sidebar, and its Library root
                // has no section menu, so it's chosen from the sidebar there. #698
                let tab = app.descendants(matching: .any)["tab.series"].firstMatch
                if tab.exists && tab.isHittable {
                    tab.press()
                } else if app.buttons["ToggleSideBar"].exists {
                    chooseFromSidebar("tab.series", in: app)
                } else {
                    chooseSection(symbol: "rectangle.stack", in: app)
                }
                let card = app.descendants(matching: .any)["series.ser_barsoom"].firstMatch
                XCTAssertTrue(
                    card.waitForExistence(timeout: Self.fixtureTimeout), "The Barsoom series card didn't appear")
                card.press()
                XCTAssertTrue(
                    element.waitForExistence(timeout: Self.fixtureTimeout), "Barsoom's Continue Series didn't appear")
            #else
                XCTFail("Series is iOS only (FixtureScreen.accentButtonScreens)")
            #endif
        }
        return element
    }

    /// Chooses the entry with `symbol` (its `AppTab.systemImage`; `books.vertical` is the grid)
    /// from the Library root's section menu (`library.sectionPicker`). SwiftUI gives a menu's
    /// entries no identifiers, so they're found by symbol, which isn't localized. A crowded
    /// vertical bar (the Duo's outer display) moves the menu into its overflow menu, titled with
    /// the section shown: on the grid, the Library tab's title.
    @MainActor
    func chooseSection(symbol: String, in app: XCUIApplication) {
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

    /// Closes the player's bookmarks sheet with its Done button (`player.sheet.done`), if it's open.
    @MainActor
    private func closeBookmarks(in app: XCUIApplication) {
        let sheet = app.descendants(matching: .any)[FixtureScreen.bookmarks.identifier].firstMatch
        let done = app.buttons["player.sheet.done"].firstMatch
        guard sheet.exists, done.exists else { return }
        done.press()
        XCTAssertTrue(sheet.waitForNonExistence(timeout: Self.fixtureTimeout), "The bookmarks sheet didn't close")
    }

    /// The tabs `open(_:in:)` uses, by their `tab.<AppTab raw value>` identifiers.
    private enum FixtureTab: String {
        case home, library, downloads, account

        /// The identifier of the tab's root screen.
        var rootIdentifier: String { "\(rawValue).screen" }
    }

    /// Selects `tab`. Every tab bar has it, with no More tab, even on the iPhone Duo's outer
    /// display (#617, `TabBarTests`).
    @MainActor
    private func openTab(_ tab: FixtureTab, in app: XCUIApplication) {
        // Any type: sidebar tabs aren't buttons on macOS.
        let home = app.descendants(matching: .any)["tab.home"].firstMatch
        expandTabBar(in: app, showing: home)
        XCTAssertTrue(home.waitForExistence(timeout: Self.fixtureTimeout), "The tab bar didn't appear")
        let button = app.descendants(matching: .any)["tab.\(tab.rawValue)"].firstMatch
        XCTAssertTrue(button.exists, "The tab bar has no \(tab.rawValue) tab")
        defer { popToRoot(in: app) }
        revealTab(button, in: app)
        button.press()
        #if os(iOS)
            chooseFromSidebar("tab.\(tab.rawValue)", in: app)
        #endif
    }

    #if os(iOS)
        /// Selects the tab with `identifier` from the sidebar if pressing it in the tab bar didn't: at
        /// accessibility text sizes a regular-width iPad's top tab bar pages, and a later tab
        /// (Account) sits behind the next one and the Next Page button, where its press lands; and
        /// Series is only in the sidebar.
        /// It shows the sidebar (`ToggleSideBar`), presses the tab's sidebar cell (the tab bar's
        /// copies are buttons), and hides the sidebar again (`ToggleSidebar`), leaving the layout as
        /// it was. No-op once the tab is selected, or where there's no sidebar toggle (iPhone). A tab
        /// only in the sidebar (Series) isn't in the tree while it's hidden, nor once choosing it has
        /// hidden it again, so then the screen it opens is the check.
        @MainActor
        private func chooseFromSidebar(_ identifier: String, in app: XCUIApplication) {
            let tab = app.descendants(matching: .any)[identifier].firstMatch
            let show = app.buttons["ToggleSideBar"].firstMatch
            guard show.exists, !wait(for: { tab.exists && tab.isSelected }, timeout: 3) else { return }
            show.press()
            let entry = app.collectionViews.cells.matching(identifier: identifier).firstMatch
            guard wait(for: { entry.exists && entry.isHittable }, timeout: Self.fixtureTimeout) else {
                return XCTFail("The sidebar has no \(identifier) tab")
            }
            entry.press()
            XCTAssertTrue(
                wait(for: { !tab.exists || tab.isSelected }, timeout: Self.fixtureTimeout),
                "\(identifier) isn't selected")
            // Choosing a tab usually dismisses the sidebar; hide it if it's still there.
            let hide = app.buttons["ToggleSidebar"].firstMatch
            if hide.exists && hide.isHittable { hide.press() }
            XCTAssertTrue(
                wait(for: { !(entry.exists && entry.isHittable) }, timeout: Self.fixtureTimeout),
                "The sidebar didn't close")
        }
    #endif

    /// Goes back, with the navigation bar's Back button, until a tab's root (`FixtureTab/rootIdentifier`, or the
    /// Library root's Series section) shows. No-op at a root, or where there's no Back button (macOS sidebars).
    @MainActor
    private func popToRoot(in app: XCUIApplication) {
        let roots = [FixtureTab.home, .library, .downloads, .account].map(\.rootIdentifier) + ["series.screen"]
        let root = app.descendants(matching: .any).matching(NSPredicate(format: "identifier IN %@", roots)).firstMatch
        let back = app.buttons["BackButton"].firstMatch
        for _ in 0..<5 where !root.exists && back.exists && back.isHittable {
            back.press()
            _ = root.waitForExistence(timeout: 3)
        }
    }

    /// Expands the tab bar if it has minimized as the content scrolled (`tabBarMinimizeBehavior`,
    /// iOS), leaving `tab` off screen: selecting the selected tab, all that's left of it, expands it.
    @MainActor
    private func revealTab(_ tab: XCUIElement, in app: XCUIApplication) {
        guard !tab.isHittable else { return }
        let selected = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'tab.' AND selected == true")).firstMatch
        XCTAssertTrue(selected.exists && selected.isHittable, "The tab bar is hidden")
        selected.press()
        let hittable = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true"), object: tab)
        XCTAssertEqual(
            XCTWaiter().wait(for: [hittable], timeout: Self.fixtureTimeout), .completed, "The tab bar didn't expand")
    }

    @MainActor
    private func waitForCard(_ identifier: String, in screen: XCUIElement, of name: String, failure: String) {
        XCTAssertTrue(screen.waitForExistence(timeout: Self.fixtureTimeout), "The \(name) screen didn't appear")
        let card = screen.descendants(matching: .any)[identifier].firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: Self.fixtureTimeout), failure)
    }

    /// Expands the tab bar (iOS) if it has minimized as the content scrolled so far that only the
    /// selected tab's button is left, without `home`: on a 6.3-inch iPhone at AX5, scrolling
    /// Account to its Settings row does this. Selecting that tab again expands the bar.
    @MainActor
    private func expandTabBar(in app: XCUIApplication, showing home: XCUIElement) {
        guard !home.exists else { return }
        let selected = app.tabBars.buttons.matching(NSPredicate(format: "selected == true")).firstMatch
        if selected.exists && selected.isHittable { selected.press() }
    }

    /// Pauses with the full player's play/pause button, the hittable one: the mini player's is
    /// under the full player on iOS. Its identifier says its state in any language: `player.pause`
    /// while playback is requested, `player.play` once it isn't. It's pressed only while it says
    /// `player.pause`, so playback that has already stopped (the fixture audio is a minute long)
    /// isn't started again.
    @MainActor
    private func pause(in app: XCUIApplication) {
        let buttons = app.buttons.matching(NSPredicate(format: "identifier IN %@", ["player.play", "player.pause"]))
        func hittable() -> XCUIElement? { buttons.allElementsBoundByIndex.first(where: \.isHittable) }
        guard wait(for: { hittable() != nil }, timeout: Self.fixtureTimeout) else {
            return XCTFail("The player's play/pause button isn't on screen")
        }
        // It shows Pause as soon as playback is requested; a moment's grace in case the full
        // player draws first.
        _ = wait(for: { hittable()?.identifier == "player.pause" }, timeout: 3)
        if let button = hittable(), button.identifier == "player.pause" { button.press() }
        XCTAssertTrue(
            wait(for: { hittable()?.identifier == "player.play" }, timeout: Self.fixtureTimeout),
            "Playback didn't pause: the play/pause button still says \(hittable()?.identifier ?? "nothing")")
    }

    /// Polls `condition` on the main run loop until it's true or `timeout` passes.
    @MainActor
    func wait(for condition: () -> Bool, timeout: TimeInterval) -> Bool {
        let deadline = Date.now.addingTimeInterval(timeout)
        while !condition() {
            guard Date.now < deadline else { return false }
            RunLoop.current.run(until: .now.addingTimeInterval(0.25))
        }
        return true
    }

    /// Minimizes the full player (iOS) or closes its window (macOS), if it's open.
    @MainActor
    private func closePlayer(in app: XCUIApplication) {
        #if os(macOS)
            closeWindow(containing: FixtureScreen.player.identifier, in: app)
        #else
            let player = app.descendants(matching: .any)[FixtureScreen.player.identifier].firstMatch
            guard player.exists else { return }
            app.buttons["player.minimize"].firstMatch.press()
            XCTAssertTrue(player.waitForNonExistence(timeout: Self.fixtureTimeout), "The full player didn't close")
        #endif
    }

    #if os(macOS)
        /// Closes the window holding the element `identifier`, if one is open.
        @MainActor
        private func closeWindow(containing identifier: String, in app: XCUIApplication) {
            let window = app.windows.containing(.any, identifier: identifier).firstMatch
            guard window.exists else { return }
            window.buttons[XCUIIdentifierCloseWindow].press()
            XCTAssertTrue(window.waitForNonExistence(timeout: Self.fixtureTimeout), "A window didn't close")
        }
    #endif
}

extension XCUIElement {
    /// Waits for the element to exist and be enabled.
    func waitForEnabled(timeout: TimeInterval) -> Bool {
        let enabled = NSPredicate(format: "exists == true AND enabled == true")
        let expectation = XCTNSPredicateExpectation(predicate: enabled, object: self)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }
}
