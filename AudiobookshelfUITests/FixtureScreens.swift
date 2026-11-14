import XCTest

/// The screens a fixture test can open from the signed-in app (`signIn(launchArguments:screenshotPrefix:)`),
/// with `open(_:in:)`. Accessibility audits and screenshots walk them in this order.
enum FixtureScreen: String, CaseIterable {
    case home, library, item, player, settings, downloads

    /// The screen's accessibility identifier: `<screen>.screen`, or `item.detail` for the item.
    var identifier: String { self == .item ? "item.detail" : "\(rawValue).screen" }

    /// The screen's name in failure messages.
    var name: String {
        switch self {
        case .home: "Home"
        case .library: "Library"
        case .item: "Item detail"
        case .player: "Player"
        case .settings: "Settings"
        case .downloads: "Downloads"
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
    ///
    /// Tabs keep their navigation stacks, so before leaving a screen (other than for the player)
    /// and after selecting a tab, the helper goes back to the tab's root.
    ///
    /// On iOS the full player covers the tabs, so it's minimized before any other screen opens; on
    /// macOS the Now Playing and Settings windows are closed instead.
    @MainActor
    @discardableResult
    func open(_ screen: FixtureScreen, in app: XCUIApplication) -> XCUIElement {
        let element = app.descendants(matching: .any)[screen.identifier].firstMatch
        // Settings is reused if it's open; Player checks below.
        if screen == .settings && element.exists { return element }
        if screen != .player {
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
            // The first card of `fixture-items.json`.
            waitForCard("item.li_pride", in: element, of: screen.name, failure: "The library's items didn't appear")
        case .item:
            let card = app.descendants(matching: .any)[FixtureScreen.library.identifier]
                .descendants(matching: .any)["item.li_pride"].firstMatch
            if !(card.exists && card.isHittable) { open(.library, in: app) }
            card.press()
            XCTAssertTrue(element.waitForExistence(timeout: Self.fixtureTimeout), "The item screen didn't appear")
            let title = element.descendants(matching: .any)["item.title"]
            XCTAssertTrue(title.waitForExistence(timeout: Self.fixtureTimeout), "The item didn't load")
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
                // isn't in the hierarchy until it's scrolled to.
                if !link.waitForExistence(timeout: 5) {
                    for _ in 0..<6 where !link.exists { app.collectionViews.firstMatch.swipeUp() }
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
            XCTAssertTrue(content.waitForExistence(timeout: Self.fixtureTimeout), "The downloads didn't load")
        }
        return element
    }

    /// The tabs `open(_:in:)` uses, by their `tab.<AppTab raw value>` identifiers.
    private enum FixtureTab: String {
        case home, library, downloads, account

        /// The identifier of the tab's root screen.
        var rootIdentifier: String { "\(rawValue).screen" }

        /// The tab's SF Symbol (`AppTab.systemImage`), which names its row in the tab bar's More list.
        var systemImage: String {
            switch self {
            case .home: "house"
            case .library: "books.vertical"
            case .downloads: "arrow.down.circle"
            case .account: "person.crop.circle"
            }
        }
    }

    /// Selects `tab`. A tab bar too short for every tab moves the last ones into its More tab
    /// (its symbol is `ellipsis`, which the app doesn't use), a list whose rows have no
    /// identifiers, so the row is found by the tab's symbol (`<symbol>` or `<symbol>.fill`), which
    /// isn't localized.
    @MainActor
    private func openTab(_ tab: FixtureTab, in app: XCUIApplication) {
        // Any type: sidebar tabs aren't buttons on macOS.
        let home = app.descendants(matching: .any)["tab.home"].firstMatch
        XCTAssertTrue(home.waitForExistence(timeout: Self.fixtureTimeout), "The tab bar didn't appear")
        let button = app.descendants(matching: .any)["tab.\(tab.rawValue)"].firstMatch
        let more = app.buttons.containing(.image, identifier: "ellipsis").firstMatch
        defer { popToRoot(in: app) }
        if button.exists {
            revealTab(button, in: app, more: more)
            button.press()
            return
        }
        XCTAssertTrue(more.exists, "The \(tab.rawValue) tab isn't in the tab bar, and there's no More tab")
        revealTab(more, in: app, more: more)
        more.press()
        let symbol = NSPredicate(
            format: "elementType == %lu AND (identifier == %@ OR identifier == %@)",
            XCUIElement.ElementType.image.rawValue, tab.systemImage, "\(tab.systemImage).fill")
        let row = app.cells.containing(symbol).firstMatch
        // The More tab shows the last tab opened from it; selecting it again goes back to its list.
        if !row.waitForExistence(timeout: 3) { more.press() }
        XCTAssertTrue(row.waitForExistence(timeout: Self.fixtureTimeout), "The More tab has no \(tab.rawValue) row")
        row.press()
    }

    /// Goes back, with the navigation bar's Back button, until a tab's root (`FixtureTab/rootIdentifier`) shows.
    /// No-op at a root, or where there's no Back button (macOS sidebars, the More tab's list).
    @MainActor
    private func popToRoot(in app: XCUIApplication) {
        let roots = [FixtureTab.home, .library, .downloads, .account].map(\.rootIdentifier)
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
    private func revealTab(_ tab: XCUIElement, in app: XCUIApplication, more: XCUIElement) {
        guard !tab.isHittable else { return }
        let selected = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'tab.' AND selected == true")).firstMatch
        let expander = selected.exists && selected.isHittable ? selected : more
        XCTAssertTrue(expander.exists && expander.isHittable, "The tab bar is hidden")
        expander.press()
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
    private func wait(for condition: () -> Bool, timeout: TimeInterval) -> Bool {
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
