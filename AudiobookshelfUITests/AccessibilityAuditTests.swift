import XCTest

/// Runs `XCUIApplication.performAccessibilityAudit()` on each `FixtureScreen` (Home, Library,
/// Item detail, Player, Settings, Downloads) with the fixture data, at the default text size and
/// at AX5 (docs/accessibility.md, "Automated audits"). Each test walks every screen in one launch,
/// so an issue names its screen, and a screen's issues don't hide the next screen's.
final class AccessibilityAuditTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    /// Every audit type but the two that predict what larger text sizes will do (Dynamic Type
    /// support and clipped text): at this size they report text that does scale and doesn't clip,
    /// such as a `Form` row's label or the player's times, and ``testScreensAtAccessibilitySize()``
    /// audits the largest size itself.
    @MainActor
    func testScreens() {
        #if os(iOS)
            auditScreens(types: XCUIAccessibilityAuditType.all.subtracting([.dynamicType, .textClipped]))
        #else
            auditScreens(types: .all)
        #endif
    }

    /// AX5, the largest accessibility text size, with every audit type.
    @MainActor
    func testScreensAtAccessibilitySize() {
        auditScreens(
            types: .all,
            launchArguments: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"],
            textSize: "AX5")
    }

    @MainActor
    private func auditScreens(
        types: XCUIAccessibilityAuditType, launchArguments: [String] = [], textSize: String = "default text size"
    ) {
        let app = signIn(launchArguments: launchArguments)
        for screen in FixtureScreen.allCases {
            open(screen, in: app)
            audit(screen, for: types, in: app, textSize: textSize)
        }
    }

    /// Audits what's on screen and fails once for every issue that isn't a ``KnownAuditIssue``,
    /// naming the screen, the text size, the audit type, the element and the issue. An issue
    /// ``KnownAuditIssue/isUnnamedContrastUnderBottomBar(_:on:in:)`` defers is checked by
    /// ``auditMetadataAboveBottomBar(in:named:)``.
    @MainActor
    private func audit(
        _ screen: FixtureScreen, for types: XCUIAccessibilityAuditType, in app: XCUIApplication, textSize: String
    ) {
        var failures: [String] = []
        var deferred = false
        do {
            try app.performAccessibilityAudit(for: types) { issue in
                if KnownAuditIssue.all.contains(where: { $0.matches(issue, on: screen, in: app) }) { return true }
                if KnownAuditIssue.isUnnamedContrastUnderBottomBar(issue, on: screen, in: app) {
                    deferred = true
                    return true
                }
                failures.append("\(screen.name) (\(textSize)): \(Self.failure(issue))")
                // Reported below, with the screen's name.
                return true
            }
            if deferred {
                failures += try auditMetadataAboveBottomBar(in: app, named: "\(screen.name) (\(textSize))")
            }
        } catch {
            XCTFail("\(screen.name) (\(textSize)): the accessibility audit failed to run: \(error)")
        }
        guard !failures.isEmpty else { return }
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "audit-\(screen.rawValue)"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        // Every issue fails on its own; the walk then stops, as a navigation failure would.
        continueAfterFailure = true
        for failure in failures { XCTFail(failure) }
        continueAfterFailure = false
    }

    /// The audit type, the element and the issue. Without an element, the detailed description
    /// names the kind of node at least.
    @MainActor
    private static func failure(_ issue: XCUIAccessibilityAuditIssue) -> String {
        let description =
            issue.element == nil
            ? "\(issue.compactDescription) (\(issue.detailedDescription))" : issue.compactDescription
        return "\(auditTypeName(issue.auditType)) on \(elementName(issue.element)): \(description)"
    }

    /// Audits contrast on Item detail's metadata (`item.metadata`) above the bottom bar, after an
    /// issue was deferred while it was under the bar. Scrolls the content up by half the band
    /// between the navigation bar and the bar at a time, audits each step, and stops once the
    /// metadata ends above the bar. So every row that was under the bar (rows are shorter than half
    /// the band) is audited fully in the band, a block taller than the band (AX5) in overlapping
    /// segments; text scrolled off the top was audited in the band on the way. Only an issue with no
    /// element fails: named text the scroll brings on screen wasn't on screen for the first audit,
    /// so it isn't what was deferred.
    @MainActor
    private func auditMetadataAboveBottomBar(in app: XCUIApplication, named name: String) throws -> [String] {
        let metadata = app.descendants(matching: .any)["item.metadata"].firstMatch
        let navigationBar = app.navigationBars.firstMatch
        let margin: CGFloat = 44
        var failures: [String] = []
        for step in 1...10 {
            let barTop = KnownAuditIssue.bottomBarTop(in: app)
            if metadata.frame.maxY <= barTop { return failures }
            let top = navigationBar.exists ? navigationBar.frame.maxY : app.frame.minY
            let band = barTop - top
            guard band > 2 * margin else {
                XCTFail("\(name): no room between the navigation bar (\(top)) and the bottom bar (\(barTop))")
                return failures
            }
            let start = metadata.frame.minY
            let origin = app.coordinate(withNormalizedOffset: .zero)
            let x = app.frame.maxX - margin / 2
            // Held at the end, so the scroll view doesn't coast past the drag.
            origin.withOffset(CGVector(dx: x, dy: barTop - margin / 2)).press(
                forDuration: 0.1, thenDragTo: origin.withOffset(CGVector(dx: x, dy: barTop - margin / 2 - band / 2)),
                withVelocity: .slow, thenHoldForDuration: 0.3)
            XCTAssertLessThanOrEqual(
                start - metadata.frame.minY, band / 2 + 2, "\(name): step \(step) scrolled more than half the band")
            try app.performAccessibilityAudit(for: .contrast) { issue in
                if issue.element == nil {
                    failures.append("\(name), metadata above the bottom bar, step \(step): \(Self.failure(issue))")
                }
                return true
            }
        }
        if metadata.frame.maxY > KnownAuditIssue.bottomBarTop(in: app) {
            XCTFail("\(name): the metadata is still under the bottom bar after 10 steps")
        }
        return failures
    }

    private static func elementName(_ element: XCUIElement?) -> String {
        guard let element else { return "no element" }
        var parts = [typeName(element.elementType)]
        if !element.identifier.isEmpty { parts.append("identifier '\(element.identifier)'") }
        if !element.label.isEmpty { parts.append("label '\(element.label)'") }
        return parts.joined(separator: " ")
    }

    private static func typeName(_ type: XCUIElement.ElementType) -> String {
        switch type {
        case .button: "button"
        case .staticText: "text"
        case .image: "image"
        case .cell: "cell"
        case .other: "element"
        case .slider: "slider"
        case .switch, .toggle: "toggle"
        case .link: "link"
        case .textField: "text field"
        default: "element of type \(type.rawValue)"
        }
    }

    private static func auditTypeName(_ type: XCUIAccessibilityAuditType) -> String {
        var names: [String] = []
        #if os(iOS)
            if type.contains(.dynamicType) { names.append("dynamicType") }
            if type.contains(.textClipped) { names.append("textClipped") }
            if type.contains(.trait) { names.append("trait") }
        #else
            if type.contains(.action) { names.append("action") }
            if type.contains(.parentChild) { names.append("parentChild") }
        #endif
        if type.contains(.contrast) { names.append("contrast") }
        if type.contains(.elementDetection) { names.append("elementDetection") }
        if type.contains(.hitRegion) { names.append("hitRegion") }
        if type.contains(.sufficientElementDescription) { names.append("sufficientElementDescription") }
        return names.isEmpty ? "audit type \(type.rawValue)" : names.joined(separator: ", ")
    }
}

/// An audit issue that isn't the app's to fix, or that has its own issue: filtered by screen,
/// audit type, description and element. Each one says why, and names its issue.
struct KnownAuditIssue {
    /// `nil` for every screen.
    var screen: FixtureScreen?
    var type: XCUIAccessibilityAuditType
    /// Text the issue's compact description must contain; `nil` for any.
    var description: String? = nil
    /// Matches the issue's element (`nil` when the issue has none) in the app.
    var element: @MainActor (XCUIElement?, XCUIApplication) -> Bool

    @MainActor
    func matches(_ issue: XCUIAccessibilityAuditIssue, on screen: FixtureScreen, in app: XCUIApplication) -> Bool {
        (self.screen == nil || self.screen == screen) && issue.auditType == type
            && (description.map { issue.compactDescription.contains($0) } ?? true) && element(issue.element, app)
    }

    @MainActor static let all: [KnownAuditIssue] = {
        var all: [KnownAuditIssue] = [
            // "Potentially inaccessible text", with no element: the labels of the metadata's link
            // rows ("Author", "Narrator", "Genres"), hidden from VoiceOver on purpose because each
            // link speaks its label ("Jane Austen, Author, link"; VoiceOver often skips a
            // container's label). Bisected: shown to VoiceOver, there are no reports; the plain
            // rows' labels pass because their row's label is the same text. Not a gap: see
            // docs/accessibility.md, "Automated audits". #613
            KnownAuditIssue(
                screen: .item, type: .elementDetection, description: "Potentially inaccessible text"
            ) { element, _ in element == nil }
        ]
        #if os(iOS)
            all += [
                // Cards cut their title and author short at two lines and one (by design, like
                // Apple Books); the card, one element, speaks both in full. Only on the screens
                // of cards, and only in a card (`item.<id>`), not the item screen's own elements,
                // whose clipping isn't by design. #615
                KnownAuditIssue(screen: .home, type: .textClipped, element: isCardText),
                KnownAuditIssue(screen: .library, type: .textClipped, element: isCardText),
                // "Dynamic Type font sizes are partially unsupported" on Library's first card's
                // title and author, about one run in ten on the iPhone Duo, though they scale with
                // every text style. The audit steps the text size up to AX5 in about a second, and
                // where it crosses into the accessibility sizes the grid drops from two columns to
                // one (`ItemGridMetrics.minimumCellWidth`); a recording of a failing run shows the
                // app still drawing the first accessibility size about 0.3 seconds after that
                // relayout, so the audit measures the text not growing. The same card is audited on
                // Home, unfiltered, whose shelf has no columns to change. Only "partially", only in
                // a card. #622
                KnownAuditIssue(
                    screen: .library, type: .dynamicType, description: "partially unsupported",
                    element: isCardText),
                // "Contrast failed" on the chapter's remaining time ("-0:26") on a 6.3-inch iPhone,
                // every run, though its pixels measure 5.7:1 on the backdrop (4.5:1 needed), as do
                // the elapsed time's beside it (5.6:1), which pass in the same font and colour.
                // Like the whole-book remaining time's at `.caption2` (#614). Only the Player's
                // remaining times. #623
                KnownAuditIssue(screen: .player, type: .contrast, element: isRemainingTime),
            ]
            // Contrast on text that has scrolled under the bottom bar: the tab bar, which floats over
            // the content, and the mini player above it (`tabViewBottomAccessory`). The audit
            // measures the text through the bar's glass, as on a 6.3-inch iPhone with Item detail's
            // "Size" (y 818 to 836 of 874, under a tab bar from y 791) and Settings' last rows. It's
            // the system's bar over a scroll view at rest, not the text's own colours, which pass
            // above the bar. Only text whose frame overlaps the bar, and not the bar's own, on the
            // screens with the bar: the full player covers it. #623
            all += [FixtureScreen.home, .library, .item, .settings, .downloads].map {
                KnownAuditIssue(screen: $0, type: .contrast, element: isUnderBottomBar)
            }
        #endif
        return all
    }()

    /// Whether `issue` is contrast with no element on Item detail while its metadata is under the
    /// bottom bar. That's probably a metadata label under the bar's glass, as "Duration" was in one
    /// AX5 run in four on a 6.3-inch iPhone: the labels are hidden from VoiceOver (each value speaks
    /// its label, as in #613), so the audit can't name one. Deferred, not filtered: the test audits
    /// contrast again with the metadata above the bar, where an issue with no element fails. #623
    @MainActor
    static func isUnnamedContrastUnderBottomBar(
        _ issue: XCUIAccessibilityAuditIssue, on screen: FixtureScreen, in app: XCUIApplication
    ) -> Bool {
        screen == .item && issue.auditType == .contrast && issue.element == nil && metadataOverlapsBottomBar(in: app)
    }

    /// The top of the tab bar or the mini player, whichever is higher; the app's bottom without
    /// either.
    @MainActor
    static func bottomBarTop(in app: XCUIApplication) -> CGFloat {
        bottomBars(in: app).map(\.frame.minY).min() ?? app.frame.maxY
    }

    /// Whether Item detail's metadata (`item.metadata`) overlaps the tab bar or the mini player.
    @MainActor
    static func metadataOverlapsBottomBar(in app: XCUIApplication) -> Bool {
        let metadata = app.descendants(matching: .any)["item.metadata"].firstMatch
        return metadata.exists && bottomBars(in: app).contains { $0.frame.intersects(metadata.frame) }
    }

    /// Whether `element` is text in an item card (`item.<id>`), which the card speaks in full, not
    /// one of the item screen's `item.` elements.
    @MainActor
    private static func isCardText(_ element: XCUIElement?, in app: XCUIApplication) -> Bool {
        isShortened(
            element,
            inElementMatching:
                "identifier BEGINSWITH 'item.' AND NOT (identifier IN {'item.detail', 'item.title', 'item.play', 'item.metadata'})",
            in: app)
    }

    /// Whether `element` is text whose whole label is in the label of an element matching
    /// `predicate`: text cut short in a view that speaks it in full.
    @MainActor
    private static func isShortened(
        _ element: XCUIElement?, inElementMatching predicate: String, in app: XCUIApplication
    ) -> Bool {
        guard let element, element.elementType == .staticText, !element.label.isEmpty else { return false }
        let container = NSPredicate(format: "(\(predicate)) AND label CONTAINS %@", element.label)
        return app.descendants(matching: .any).matching(container).firstMatch.exists
    }

    /// Whether `element` is text in the content under the bottom bar: its frame overlaps the tab
    /// bar's or the mini player's (`player.mini`), and it isn't text of either.
    @MainActor
    private static func isUnderBottomBar(_ element: XCUIElement?, in app: XCUIApplication) -> Bool {
        guard let element, element.elementType == .staticText, !element.label.isEmpty else { return false }
        let bars = bottomBars(in: app)
        let ownText = NSPredicate(format: "label CONTAINS %@", element.label)
        return bars.contains { $0.frame.intersects(element.frame) }
            && !bars.contains {
                $0.label.contains(element.label) || $0.descendants(matching: .any).matching(ownText).firstMatch.exists
            }
    }

    /// The tab bar and the mini player, where they exist.
    @MainActor
    private static func bottomBars(in app: XCUIApplication) -> [XCUIElement] {
        [app.tabBars.firstMatch, app.buttons["player.mini"].firstMatch].filter(\.exists)
    }

    /// Whether `element` is one of the player's remaining times: text that's a minus and a
    /// timestamp, such as "-0:26" or "-1:02:03".
    @MainActor
    private static func isRemainingTime(_ element: XCUIElement?, in app: XCUIApplication) -> Bool {
        guard let element, element.elementType == .staticText else { return false }
        return NSPredicate(format: "SELF MATCHES %@", "-[0-9]+(:[0-9]{2})+").evaluate(with: element.label)
    }
}
