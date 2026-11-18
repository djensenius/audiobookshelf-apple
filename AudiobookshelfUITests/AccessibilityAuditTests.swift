import XCTest

/// Runs `XCUIApplication.performAccessibilityAudit()` on each `FixtureScreen` (Home, Library,
/// Item detail, Player, Settings, Downloads) with the fixture data, at the default text size and
/// at AX5, and in the dark and black themes (docs/accessibility.md, "Automated audits"). Each test
/// walks every screen in one launch, so an issue names its screen, and a screen's issues don't hide
/// the next screen's. The dark and black themes also walk the screens with accent-filled buttons
/// (`FixtureScreen.accentButtonScreens`, #645).
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
        auditScreens(types: Self.defaultSizeTypes)
    }

    /// The default text size's audits in the dark theme (`-ABSTheme dark`), which a newly created
    /// simulator can't be switched to without a reboot. #641
    @MainActor
    func testScreensInDarkTheme() {
        auditScreens(types: Self.defaultSizeTypes, theme: .dark)
    }

    /// The default text size's audits in the black theme: true black backgrounds and its own muted
    /// text and borders (`ABSColor`). #641
    @MainActor
    func testScreensInBlackTheme() {
        auditScreens(types: Self.defaultSizeTypes, theme: .black)
    }

    /// Every audit type but the two that predict larger sizes, on iOS (see ``testScreens()``).
    private static var defaultSizeTypes: XCUIAccessibilityAuditType {
        #if os(iOS)
            XCUIAccessibilityAuditType.all.subtracting([.dynamicType, .textClipped])
        #else
            .all
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

    /// Walks every screen in one launch with `launchArguments` and `theme`'s, checking the theme
    /// shows (``assertAppearance(of:_:in:)``) before each audit.
    @MainActor
    private func auditScreens(
        types: XCUIAccessibilityAuditType, launchArguments: [String] = [], textSize: String = "default text size",
        theme: FixtureTheme? = nil
    ) {
        let app = signIn(launchArguments: launchArguments + (theme?.launchArguments ?? []))
        let condition = theme.map { "\(textSize), \($0.rawValue) theme" } ?? textSize
        for screen in FixtureScreen.audited(inDarkTheme: theme != nil) {
            open(screen, in: app)
            if let theme { assertAppearance(of: screen, theme, in: app) }
            audit(screen, for: types, in: app, textSize: condition)
        }
    }

    /// Audits what's on screen and fails once for every issue that isn't a ``KnownAuditIssue``,
    /// naming the screen, the text size, the audit type, the element and the issue. An issue
    /// ``KnownAuditIssue/isUnnamedContrastUnderBottomBar(_:on:in:)`` or
    /// ``KnownAuditIssue/namedContrastUnderBottomBar(_:on:in:)`` defers is checked by
    /// ``auditAboveBottomBar(_:deferring:namedDeferrals:hasUnnamed:on:in:named:)``, and one
    /// ``KnownAuditIssue/contentButtonUnderBottomBar(_:on:in:)`` defers by
    /// ``auditButtonsAboveBottomBar(_:on:in:named:)``.
    @MainActor
    private func audit(
        _ screen: FixtureScreen, for types: XCUIAccessibilityAuditType, in app: XCUIApplication, textSize: String
    ) {
        var failures: [String] = []
        var deferred: [String] = []
        var named: [KnownAuditIssue.NamedDeferral] = []
        var buttons: [(label: String, failure: String)] = []
        var hasUnnamed = false
        let name = "\(screen.name) (\(textSize))"
        // "Dynamic Type font sizes are partially unsupported (User will not be able to change the
        // font size of this UILabel)" with no element at AX5 on a 13-inch iPad, every run, on every
        // screen with the tab bar along the top: two to four per audit, no more than the tab titles
        // it shows. The system's UIKit labels are capped at the bar's height, as a navigation bar's
        // items are (#647); the app's own text, a menu picker's UIKit value included, comes with its
        // element. None on the full player, which covers the bar. So per audit, at most as many as
        // the bar's row of hittable tab buttons (`KnownAuditIssue.topTabBarButtonCount`), never on
        // the Player or Bookmarks, and only "partially" (a fixed font size is "unsupported"); any
        // more fail. #698
        #if os(iOS)
            let tabBarLabels =
                types.contains(.dynamicType) && ![FixtureScreen.player, .bookmarks].contains(screen)
                ? KnownAuditIssue.topTabBarButtonCount(in: app) : 0
        #else
            let tabBarLabels = 0
        #endif
        var tabBarIssues = 0
        do {
            try app.performAccessibilityAudit(for: types) { issue in
                if KnownAuditIssue.all.contains(where: { $0.matches(issue, on: screen, in: app) }) { return true }
                if tabBarIssues < tabBarLabels, KnownAuditIssue.isUnnamedUILabelDynamicType(issue) {
                    tabBarIssues += 1
                    return true
                }
                // Reported below, with the screen's name.
                if KnownAuditIssue.isUnnamedContrastUnderBottomBar(issue, on: screen, in: app) {
                    deferred.append("\(name): \(Self.failure(issue))")
                    hasUnnamed = true
                } else if let text = KnownAuditIssue.namedContrastUnderBottomBar(issue, on: screen, in: app) {
                    let failure = "\(name): \(Self.failure(issue))"
                    deferred.append(failure)
                    named.append(.init(label: text.label, occurrence: text.occurrence, failure: failure))
                } else if let label = KnownAuditIssue.contentButtonUnderBottomBar(issue, on: screen, in: app) {
                    buttons.append((label, "\(name): \(Self.failure(issue))"))
                } else {
                    failures.append("\(name): \(Self.failure(issue))")
                }
                return true
            }
            if !deferred.isEmpty {
                failures += try auditAboveBottomBar(
                    KnownAuditIssue.contentUnderBottomBar(on: screen, in: app), deferring: deferred,
                    namedDeferrals: named, hasUnnamed: hasUnnamed, on: screen, in: app, named: name)
            }
            if !buttons.isEmpty {
                failures += try auditButtonsAboveBottomBar(buttons, on: screen, in: app, named: name)
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

    /// Checks the contrast issues that ``KnownAuditIssue/isUnnamedContrastUnderBottomBar(_:on:in:)``
    /// and ``KnownAuditIssue/namedContrastUnderBottomBar(_:on:in:)`` deferred (`deferred`, their
    /// failures) while the `content` (``KnownAuditIssue/contentUnderBottomBar(on:in:)``: the content
    /// text under the bottom bar, and Item detail's metadata) was under the bottom bar, and returns
    /// what fails. `namedDeferrals` are the deferred issues that name their text, and `hasUnnamed` is
    /// whether one had no element.
    ///
    /// For an issue with no element, it first rules out the text on screen in the band between the
    /// navigation bar and the bottom bar (``KnownAuditIssue/textInView(in:)``, ``BottomBarAttribution``),
    /// text partly under the navigation bar included, which can't scroll further out. That text can't
    /// be on screen with the content clear of the bar when the content is at its top, as Settings
    /// opens, so it audits contrast in place (step 0), then after steps toward clear of the bar
    /// that keep that text in the band, until the issue goes away. A failure on that text's own
    /// background doesn't go away while it's in view: at AX5 on an iPhone 17 a low-contrast
    /// "User Interface Settings" header, reported with no element, was named in place every time.
    /// If the issue persists until that text would have to leave, or once the content is clear,
    /// the deferred failures stand, as they do if the app can't be snapshotted to find that text.
    /// The bars' own text and buttons (``KnownAuditIssue/barLabels(in:)``: the tab bar's, the
    /// navigation bar's and the mini player's) are ruled out too: an issue naming one while
    /// attributing fails, and the deferred failures stand. In practice the deferred issue hasn't
    /// come back in place. Issues that all name their text have nothing to rule out, so they skip
    /// this.
    ///
    /// Then it audits the content above the bar: it scrolls up by half the band at a time, audits
    /// each step, and stops once the content ends above the bar. So every row that was under the
    /// bar (rows are shorter than half the band) is audited fully in the band, a block taller than
    /// the band (AX5) in overlapping segments. In both, an issue with no element fails, and so
    /// does one on text, by label, that was in the band or under the bar at first (the metadata's
    /// rows included), unless it's a ``KnownAuditIssue``; other named text the scroll brings on
    /// screen wasn't on screen for the first audit. The bars' own text and buttons aren't judged
    /// here, on purpose: they were ruled out in place, and now they're over other content than
    /// they were then. In every audit here, as in the first, an issue naming content text that's
    /// under the bar at the time (``KnownAuditIssue/contentTextUnderBottomBar(_:in:)``) is
    /// deferred again, not judged: a later step audits it above the bar. In these steps neither is
    /// text the scroll has taken up under the navigation bar
    /// (``BottomBarAttribution/isUnderNavigationBar(_:bandTop:)``), measured through that bar's
    /// glass: the first audit judged it where it was, or an earlier step in the band. Each step is
    /// an activity named with what it measured.
    ///
    /// So each text a deferred issue names must be audited at least once wholly between the bars
    /// (``BottomBarAttribution/isWhollyInBand(_:band:)``), at any step: text taller than half the
    /// band could go from under the bottom bar to under the navigation bar in one step. If it never
    /// is, its deferred failure stands. So does that of an issue deferred again here, in any audit,
    /// that names content text under the bar: the same holds for its text from then on.
    @MainActor
    private func auditAboveBottomBar(
        _ content: (name: String, elements: [XCUIElement]), deferring deferred: [String],
        namedDeferrals: [KnownAuditIssue.NamedDeferral], hasUnnamed: Bool, on screen: FixtureScreen,
        in app: XCUIApplication, named name: String
    ) throws -> [String] {
        let margin: CGFloat = 44
        guard let first = content.elements.first else {
            XCTFail("\(name): an issue was deferred, but no \(content.name) is under the bottom bar")
            return deferred
        }
        // The content's labels include its texts', as Item detail's metadata is their container.
        guard let view = KnownAuditIssue.textInView(in: app),
            let contentLabels = KnownAuditIssue.textLabels(of: content.elements),
            let barLabels = KnownAuditIssue.barLabels(in: app)
        else { return deferred.map { "\($0) (kept: couldn't snapshot the view to attribute it)" } }
        let labels = Set(view.keys.map(\.label)).union(contentLabels)
        let bottom = { content.elements.map(\.frame.maxY).max() ?? 0 }
        let x = Self.dragX(for: first, in: app, margin: margin)
        var failures: [String] = []
        // The named deferrals, from the first audit and from the audits here, and those whose text
        // has been wholly between the bars at an audited step.
        var pending = namedDeferrals
        var covered = Set<Int>()
        func markCovered() {
            guard !pending.isEmpty, let (texts, band) = KnownAuditIssue.snapshotTexts(in: app) else { return }
            for (index, deferral) in pending.enumerated() where !covered.contains(index) {
                let text = texts.first { $0.label == deferral.label && $0.occurrence == deferral.occurrence }
                if let text, BottomBarAttribution.isWhollyInBand(text.frame, band: band) { covered.insert(index) }
            }
        }
        // The failures of the named deferrals never covered, for the paths that return without `deferred`.
        func uncovered() -> [String] {
            pending.indices.filter { !covered.contains($0) }.map {
                "\(pending[$0].failure) (kept: never wholly between the bars at an audited step)"
            }
        }
        // Audits contrast: counts issues with no element and the named ones on `labels` (and on
        // `barLabels` while attributing), adding the named ones to `failures`, and the ones with no
        // element too once attributed. While attributing they aren't kept: they're the deferred
        // issue persisting, which `deferred` already holds if it isn't attributed. Named content
        // text under the bottom bar now is deferred again, not counted, and added to `pending` (once
        // per text, with its first failure) to be audited between the bars; once attributed, so is
        // text scrolled up under the navigation bar, judged where it was in the first audit or in
        // the band at an earlier step.
        let navigationBar = app.navigationBars.firstMatch
        func auditContrast(_ step: String, attributing: Bool) throws -> (unnamed: Int, named: Int) {
            var counts = (unnamed: 0, named: 0)
            try app.performAccessibilityAudit(for: .contrast) { issue in
                if KnownAuditIssue.all.contains(where: { $0.matches(issue, on: screen, in: app) }) { return true }
                if let element = issue.element {
                    guard labels.contains(element.label) || attributing && barLabels.contains(element.label)
                    else { return true }
                    if let text = KnownAuditIssue.contentTextUnderBottomBar(element, in: app) {
                        if !pending.contains(where: { $0.label == text.label && $0.occurrence == text.occurrence }) {
                            pending.append(
                                .init(
                                    label: text.label, occurrence: text.occurrence,
                                    failure: "\(name), \(step): \(Self.failure(issue))"))
                        }
                        return true
                    }
                    let bandTop = navigationBar.exists ? navigationBar.frame.maxY : app.frame.minY
                    if !attributing && BottomBarAttribution.isUnderNavigationBar(element.frame, bandTop: bandTop) {
                        return true
                    }
                    counts.named += 1
                } else {
                    counts.unnamed += 1
                    guard !attributing else { return true }
                }
                failures.append("\(name), \(step): \(Self.failure(issue))")
                return true
            }
            markCovered()
            return counts
        }
        // Scrolls the content up by `distance`, held at the end so it doesn't coast past the drag.
        func drag(_ distance: CGFloat) {
            let y = KnownAuditIssue.bottomBarTop(in: app) - margin / 2
            let origin = app.coordinate(withNormalizedOffset: .zero)
            origin.withOffset(CGVector(dx: x, dy: y)).press(
                forDuration: 0.1, thenDragTo: origin.withOffset(CGVector(dx: x, dy: y - distance)),
                withVelocity: .slow, thenHoldForDuration: 0.3)
        }

        // Step 0 audits in place. Then each step scrolls toward clear of the bar, at least 16
        // points, as far as the headroom over the text in view allows: the headroom stays the
        // same while a large title collapses, so it's measured again after each step.
        var outcome = BottomBarAttribution.Outcome.undecided
        if !hasUnnamed {
            outcome = .attributed
            XCTContext.runActivity(
                named: "\(name): every deferred contrast issue names its text: not attributing; the "
                    + "\(content.name) \(bottom() - KnownAuditIssue.bottomBarTop(in: app)) points under the bar"
            ) { _ in }
        }
        let steps = 8
        for step in 0...steps where outcome == .undecided {
            let before = KnownAuditIssue.state(of: view, in: app)
            let under = bottom() - KnownAuditIssue.bottomBarTop(in: app)
            let distance = step == 0 ? 0 : min(max(under, 0) + 4, max(before.headroom - 4, 16))
            if distance > 0 { drag(distance) }
            let found = try auditContrast("attributing the deferred contrast, step \(step)", attributing: true)
            let after = KnownAuditIssue.state(of: view, in: app)
            let underAfter = bottom() - KnownAuditIssue.bottomBarTop(in: app)
            let moved = step == 0 || under - underAfter >= 1
            outcome = BottomBarAttribution.outcome(
                after: .init(
                    unnamedIssues: found.unnamed, namedFailures: found.named, originalViewVisible: after.visible),
                canScrollFurther: step < steps && moved && underAfter > 0)
            XCTContext.runActivity(
                named: "\(name): attributing the deferred contrast, step \(step): dragged \(distance) points; the "
                    + "\(content.name) \(under) then \(underAfter) points under the bar; headroom \(before.headroom) "
                    + "then \(after.headroom); \(view.count) texts in view, all still in view: \(after.visible); "
                    + "\(labels.count) labels judged and \(barLabels.count) of the bars; "
                    + "\(found.unnamed) issues with no element, \(found.named) named: \(outcome)"
            ) { _ in }
        }
        switch outcome {
        case .attributed: break
        case .failed: return failures + deferred
        case .notAttributed(.viewLeft):
            return failures
                + deferred.map { "\($0) (kept: still there when text on screen at first left the view)" }
        case .notAttributed(.persisted), .undecided:
            return failures
                + deferred.map {
                    "\($0) (kept: still there as far as the \(content.name) could scroll with that text on screen)"
                }
        }

        for step in 1...10 {
            let barTop = KnownAuditIssue.bottomBarTop(in: app)
            if bottom() <= barTop { return failures + uncovered() }
            let top = navigationBar.exists ? navigationBar.frame.maxY : app.frame.minY
            let band = barTop - top
            // An empty band means no bar along the bottom edge was found (#648), so the drag below
            // would go nowhere.
            guard band > 2 * margin else {
                XCTFail(
                    "\(name): no room to audit the \(content.name) above the bottom bar: the band between the "
                        + "navigation bar (\(top)) and the bottom bar (\(barTop)) is \(band) points")
                return failures + uncovered()
            }
            let start = first.frame.minY
            drag(band / 2)
            XCTAssertLessThanOrEqual(
                start - first.frame.minY, band / 2 + 2, "\(name): step \(step) scrolled more than half the band")
            let found = try auditContrast("\(content.name) above the bottom bar, step \(step)", attributing: false)
            XCTContext.runActivity(
                named:
                    "\(name): \(content.name) above the bottom bar, step \(step): scrolled \(start - first.frame.minY) "
                    + "points; \(found.unnamed) issues with no element, \(found.named) named"
            ) { _ in }
        }
        if bottom() > KnownAuditIssue.bottomBarTop(in: app) {
            XCTFail("\(name): the \(content.name) is still under the bottom bar after 10 steps")
        }
        return failures + uncovered()
    }

    /// Checks the contrast issues ``KnownAuditIssue/contentButtonUnderBottomBar(_:on:in:)`` deferred
    /// (`buttons`: each button's label and failure) and returns what fails. It scrolls each button
    /// up (or, if the text's pass scrolled it under the navigation bar, down) until it's wholly between
    /// the bars (``BottomBarAttribution/isWhollyInBand(_:band:)``), as
    /// ``auditAboveBottomBar(_:deferring:namedDeferrals:hasUnnamed:on:in:named:)`` does for text, and
    /// audits contrast there: an issue naming the button, or naming no element, fails. If it never
    /// gets there, as when the content stops scrolling, its deferred failure stands. #698
    @MainActor
    private func auditButtonsAboveBottomBar(
        _ buttons: [(label: String, failure: String)], on screen: FixtureScreen, in app: XCUIApplication,
        named name: String
    ) throws -> [String] {
        let margin: CGFloat = 44
        let navigationBar = app.navigationBars.firstMatch
        var failures: [String] = []
        for button in buttons {
            let element = app.buttons.matching(NSPredicate(format: "label == %@", button.label)).firstMatch
            let x = Self.dragX(for: element, in: app, margin: margin)
            var audited = false
            for step in 0...10 {
                let barTop = KnownAuditIssue.bottomBarTop(in: app)
                let top = navigationBar.exists ? navigationBar.frame.maxY : app.frame.minY
                let frame = element.frame
                if BottomBarAttribution.isWhollyInBand(frame, band: top...max(top, barTop)) {
                    try app.performAccessibilityAudit(for: .contrast) { issue in
                        if KnownAuditIssue.all.contains(where: { $0.matches(issue, on: screen, in: app) }) {
                            return true
                        }
                        // One with no element could be the button's, so it fails too.
                        if let found = issue.element {
                            if found.elementType == .button, found.label == button.label {
                                failures.append(
                                    "\(name), '\(button.label)' above the bottom bar: \(Self.failure(issue))")
                            }
                        } else {
                            failures.append(
                                "\(name), auditing '\(button.label)' above the bottom bar: \(Self.failure(issue))")
                        }
                        return true
                    }
                    XCTContext.runActivity(
                        named: "\(name): '\(button.label)' audited above the bottom bar at step \(step), at \(frame)"
                    ) { _ in }
                    audited = true
                    break
                }
                guard step < 10, barTop - top > 2 * margin else { break }
                // Up into the band from under the bottom bar or, if the text pass
                // (`auditAboveBottomBar`) scrolled it up under the navigation bar, back down.
                let up = frame.minY >= top
                let distance =
                    up
                    ? max(16, min(frame.maxY - barTop + 4, (barTop - top) / 2))
                    : -max(16, min(top - frame.minY + 4, (barTop - top) / 2))
                let y = up ? barTop - margin / 2 : top + margin / 2
                let origin = app.coordinate(withNormalizedOffset: .zero)
                origin.withOffset(CGVector(dx: x, dy: y)).press(
                    forDuration: 0.1, thenDragTo: origin.withOffset(CGVector(dx: x, dy: y - distance)),
                    withVelocity: .slow, thenHoldForDuration: 0.3)
                // The content can't scroll any further.
                if abs(element.frame.minY - frame.minY) < 1 { break }
            }
            if !audited { failures.append("\(button.failure) (kept: never wholly between the bars)") }
        }
        return failures
    }

    /// Where ``auditAboveBottomBar(_:deferring:namedDeferrals:hasUnnamed:on:in:named:)`` drags: `margin / 2` in from the right edge of the
    /// scroll view holding `element` (Settings' form, Item detail's scroll view), and clear of a
    /// side tab bar (``KnownAuditIssue/contentMaxX(in:)``), so the drag scrolls the content, not the
    /// bar. The app's right edge, clear of a side bar, without a scroll view under `element`.
    @MainActor
    private static func dragX(for element: XCUIElement, in app: XCUIApplication, margin: CGFloat) -> CGFloat {
        var maxX = KnownAuditIssue.contentMaxX(in: app)
        var minX = app.frame.minX
        let frame = element.frame
        let point = CGPoint(x: frame.midX, y: frame.midY)
        // The widest scroll view under the element: the screen's own, not one nested in its content.
        let scrollers = [app.collectionViews, app.scrollViews, app.tables].flatMap(\.allElementsBoundByIndex)
        if let scroller = scrollers.map(\.frame).filter({ $0.contains(point) }).max(by: { $0.width < $1.width }) {
            maxX = min(maxX, scroller.maxX)
            minX = scroller.minX
        }
        return max(minX + margin / 2, maxX - margin / 2)
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
                // "Dynamic Type font sizes are partially unsupported" on the Library section menu's
                // title ("Library") in a horizontal navigation bar at AX5, every run on a 6.3-inch
                // iPhone. The bar caps its items' text: it's 20 points tall at the default size and
                // 25 at AX5, beside the 72-point large title, which scales. The menu shows the Large
                // Content Viewer instead, as Apple's bar items do. Not on the iPhone Duo, whose
                // vertical bar shows the menu's symbol only. Only "partially" (a fixed font size is
                // "unsupported", and fails), only text in the menu (`library.sectionPicker`) in a
                // navigation bar. #647
                KnownAuditIssue(
                    screen: .library, type: .dynamicType, description: "partially unsupported",
                    element: isSectionMenuText),
                // The top tab bar's element-less labels at AX5 on a 13-inch iPad aren't filtered
                // here but counted, per audit, against the tab buttons in the row
                // (`AccessibilityAuditTests.audit`, `topTabBarButtonCount`). #698
                //
                // "Dynamic Type font sizes are partially unsupported" on Settings' toggle and menu
                // picker rows at AX5 on a 13-inch iPad, every full walk: the toggles' titles ("Use
                // bookshelf view", "Disable auto rewind") and the pickers' values ("System", "10s"),
                // whichever rows are in view; none on the iPhone Duo. They're the system's `Toggle`
                // and `Picker` rows with no font of the app's, and they scale at every size: "Use
                // bookshelf view" is 27.5, 33.5, 39.5, 48, 56.5 and 63.5 points tall from XXXL to AX5
                // (probed), the values likewise, and AX5 shows them whole. An audit of only Dynamic
                // Type on Settings at AX5 reports none of them, and at XXXL or AX1 it reports the
                // rows in view, so it's the audit's measurement, as for the cards (#622). Only
                // "partially" (a fixed font size is "unsupported", and fails), only text in a
                // Settings row's switch or button, and only while it's at least one AX5 body line
                // (63.5 points) tall, so text drawn at a smaller size still fails. #698
                KnownAuditIssue(
                    screen: .settings, type: .dynamicType, description: "partially unsupported",
                    element: isScaledSettingsRowText),
                // "Contrast failed" on the chapter's remaining time ("-0:26") on a 6.3-inch iPhone,
                // every run, though its pixels measure 5.7:1 on the backdrop (4.5:1 needed), as do
                // the elapsed time's beside it (5.6:1), which pass in the same font and colour.
                // Like the whole-book remaining time's at `.caption2` (#614). Only the Player's
                // remaining times, and only while a screenshot measures 4.5:1 or more around text
                // in their colour, as for the elapsed times. #623, #655
                KnownAuditIssue(screen: .player, type: .contrast) { element, app in
                    guard let element, isRemainingTime(element, in: app) else { return false }
                    return measuresReadable(element, in: app)
                },
                // "Contrast failed" on the chapter's elapsed time ("0:02") at the default text
                // size on an iPhone 17, now and then: the first run on a new simulator, while it
                // ticks. A screenshot taken as the issue arrives measures 5.5:1 for its pixels, in
                // `ABSColor.mutedForeground` (rgb(91, 99, 108)), on the backdrop's rgb(247, 244,
                // 242), and the frame matches the text; the remaining time beside it measures the
                // same. Only the Player's elapsed times, and only while a screenshot measures 4.5:1
                // or more around text in that colour (`MeasuredContrast`), as for the mini player.
                // #653
                KnownAuditIssue(screen: .player, type: .contrast) { element, app in
                    guard let element, isElapsedTime(element) else { return false }
                    return measuresReadable(element, in: app)
                },
                // "Contrast failed" on the chapter's title ("Chapter 1") over the full player's
                // backdrop on a 13-inch iPad in the dark and black themes, every run. A screenshot
                // measures 5.6:1 for its pixels, in `ABSColor.mutedForeground` (rgb(156, 161, 167)),
                // on the backdrop's rgb(49, 39, 39), and the frame matches the text; the author below
                // it, in the same colour, passes. Only the Player's chapter title
                // (`player.chapter`), and only while a screenshot measures 4.5:1 or more around text in
                // that colour, as for the times. Not limited to dark and black: being measured, it
                // filters only text that reads at 4.5:1 or more, in any theme. #698
                KnownAuditIssue(screen: .player, type: .contrast) { element, app in
                    guard let element, element.identifier == "player.chapter" else { return false }
                    return measuresReadable(element, in: app)
                },
            ]
            // Contrast on content text under the bottom bar isn't filtered but deferred
            // (`namedContrastUnderBottomBar`, #650), and audited again above the bar.

            // "Potentially inaccessible text" with no element on Settings in the dark theme, while
            // a row's text is under the mini player: the dark glass shows the text through, and
            // the audit finds the mini player, not the row, on top of it. Probed on a 6.3-inch
            // iPhone: none without the mini player; with it, the issue comes and goes with "Allow
            // position seeking on media notification controls" under it, as Settings scrolls; the
            // row's toggle speaks that text. Only while content text overlaps the tab bar or the mini
            // player, not merely in the region below them (as in the iPhone Duo's gap). #641
            all.append(
                KnownAuditIssue(
                    screen: .settings, type: .elementDetection, description: "Potentially inaccessible text"
                ) { element, app in element == nil && !textUnderBottomBar(in: app, overlappingBars: true).isEmpty })
            // "Contrast failed" on the mini player's text on the iPhone Duo in the dark and black
            // themes, every run: the title on Downloads and the author on Settings (dark). A
            // screenshot taken as each issue arrives measures 16.3:1 (white on the glass's
            // rgb(32,32,32)) and 5.9:1 (rgb(214,218,222) on rgb(78,79,79)), the frames match the
            // text, and the issues stay after waiting for the screen to be still for a second. Not
            // on a 6.3-inch iPhone, whose mini player sits over the tab bar, not floating. Only the
            // mini player's text, and only while a screenshot taken now measures 4.5:1 or more
            // between the text's pixels and the background 2 to 4 pixels around them (the 10th
            // percentile; `MeasuredContrast`). The text's pixels are those in the colour the app
            // draws it in for the theme (`FixtureTheme.miniPlayerTitle`, `.miniPlayerSecondaryText`),
            // not guessed from the image, and measured in the colour they're actually drawn in.
            // So text that really fails, as the author's 2.7:1 did, or text over a lighter patch
            // of glass, still fails; without the expected colour, or with over a quarter of its
            // pixels unmeasurable, the issue fails, unfiltered. #641
            //
            // The same in light on a 13-inch iPad, every run: the author ("Jane Austen") on Settings,
            // whose rgb(91,99,108) measures 6.0:1 on the floating mini player's light glass. In light
            // only at regular width, with the tab bar along the top (`topTabBarButtonCount`), so
            // compact light runs keep the check they had. #698
            all.append(
                KnownAuditIssue(type: .contrast) { element, app in
                    guard let element, isMiniPlayerText(element, in: app) else { return false }
                    let theme = FixtureTheme(launchArguments: app.launchArguments)
                    guard theme != nil || topTabBarButtonCount(in: app) > 0 else { return false }
                    let text =
                        element.identifier == "player.mini.title"
                        ? FixtureTheme.miniPlayerTitle(theme) : FixtureTheme.miniPlayerSecondaryText(theme)
                    let ratio = MeasuredContrast.ratio(in: element.frame, of: XCUIScreen.main.screenshot(), text: text)
                    return ratio.map { $0 >= 4.5 } ?? false
                })
            // "Contrast failed" on the bookmarks sheet's Done (`player.sheet.done`) in the dark
            // theme, every run on a 6.3-inch iPhone: the system's glass button in the sheet's
            // navigation bar, whose white label measures 12.2:1 on the glass's rgb(49, 55, 47). Only
            // that button on Bookmarks, and only while a screenshot measures 4.5:1 or more around
            // its white text, as for the mini player's. #645
            all.append(
                KnownAuditIssue(screen: .bookmarks, type: .contrast) { element, app in
                    guard let element, element.identifier == "player.sheet.done",
                        FixtureTheme(launchArguments: app.launchArguments) != nil
                    else { return false }
                    let white = MeasuredContrast.RGB(red: 255, green: 255, blue: 255)
                    let ratio = MeasuredContrast.ratio(in: element.frame, of: XCUIScreen.main.screenshot(), text: white)
                    return ratio.map { $0 >= 4.5 } ?? false
                })
        #endif
        return all
    }()

    /// Whether `issue` is contrast with no element on Item detail while its metadata is under the
    /// bottom bar. That's probably a metadata label under the bar's glass, as "Duration" was in one
    /// AX5 run in four on a 6.3-inch iPhone: the labels are hidden from VoiceOver (each value speaks
    /// its label, as in #613), so the audit can't name one. Deferred, not filtered: the test audits
    /// contrast again with the metadata above the bar, where an issue with no element fails. #623
    ///
    /// The same on Settings while its text is under the bar, as the "Playback Settings" header was
    /// at AX5 on a 6.3-inch iPhone (#647): in four runs of five the audit reports it with no
    /// element, in the fifth by name. The test audits again with that text above the bar, where an
    /// issue with no element or naming it fails.
    ///
    /// Either way, the deferred failures stand unless the issue goes away while the rest of the
    /// text on screen is still in view: it could be that text's (``BottomBarAttribution``).
    @MainActor
    static func isUnnamedContrastUnderBottomBar(
        _ issue: XCUIAccessibilityAuditIssue, on screen: FixtureScreen, in app: XCUIApplication
    ) -> Bool {
        guard issue.auditType == .contrast, issue.element == nil else { return false }
        switch screen {
        case .item: return metadataOverlapsBottomBar(in: app)
        case .settings: return !textUnderBottomBar(in: app).isEmpty
        default: return false
        }
    }

    /// Whether `issue` is contrast on content text under the bottom bar (``isContentTextUnderBottomBar(_:in:)``)
    /// on a screen with the bar. The tab bar floats over the content, with the mini player above it
    /// (`tabViewBottomAccessory`), so a screen at rest has text under the bar's glass, and the audit
    /// measures it through the glass, as on a 6.3-inch iPhone with Item detail's "Size" (y 818 to
    /// 836 of 874, under a tab bar from y 791) and Settings' last rows (#623), or text cut off by
    /// the window's bottom edge below the iPhone Duo's floating mini player, as Settings' "Allow
    /// position seeking on media notification controls" in the dark and black themes. Deferred, not
    /// filtered: the test audits contrast again with the text above the bar, where an issue naming
    /// it fails. Not the bars' own text or controls, which are judged where they are, nor on the
    /// Player, whose full player covers the bar. The text it names, by label and occurrence among
    /// the app's texts with that label, or `nil` if it isn't deferred. #650
    @MainActor
    static func namedContrastUnderBottomBar(
        _ issue: XCUIAccessibilityAuditIssue, on screen: FixtureScreen, in app: XCUIApplication
    ) -> (label: String, occurrence: Int)? {
        guard issue.auditType == .contrast, let element = issue.element,
            [FixtureScreen.home, .library, .item, .settings, .downloads, .series].contains(screen)
        else { return nil }
        return contentTextUnderBottomBar(element, in: app)
    }

    /// Whether `issue` is contrast on a content button under the bottom bar, on the screens
    /// ``namedContrastUnderBottomBar(_:on:in:)`` defers text on: the button's label, or `nil` if it
    /// isn't deferred. A button labelled by its own text has no text element to defer, as Settings'
    /// "Open Settings" on a 13-inch iPad, opened at its top: its row starts 6 points above the
    /// window's bottom edge, under the floating mini player, and the audit measures that sliver
    /// through the glass. Deferred, not filtered: the test audits it again above the bar
    /// (`auditButtonsAboveBottomBar`). Not the bars' own buttons, and only a label no other button
    /// has, so the re-audit finds this one. #698
    @MainActor
    static func contentButtonUnderBottomBar(
        _ issue: XCUIAccessibilityAuditIssue, on screen: FixtureScreen, in app: XCUIApplication
    ) -> String? {
        guard issue.auditType == .contrast, let element = issue.element, element.elementType == .button,
            !element.label.isEmpty, !element.identifier.hasPrefix("player.mini"),
            !miniPlayerTransport.contains(element.identifier),
            [FixtureScreen.home, .library, .item, .settings, .downloads, .series].contains(screen),
            BottomBarAttribution.isUnderBottomBar(element.frame, region: bottomBarRegion(in: app)),
            !bottomBars(in: app).contains(where: { $0.frame.contains(element.frame) }),
            app.buttons.matching(NSPredicate(format: "label == %@", element.label)).count == 1
        else { return nil }
        return element.label
    }

    /// A contrast issue ``namedContrastUnderBottomBar(_:on:in:)`` deferred: its text, by label and
    /// occurrence among the app's texts with that label, and its failure.
    struct NamedDeferral {
        var label: String
        var occurrence: Int
        var failure: String
    }

    /// Whether `element` is content text under the bottom bar (``contentTextUnderBottomBar(_:in:)``).
    @MainActor
    static func isContentTextUnderBottomBar(_ element: XCUIElement, in app: XCUIApplication) -> Bool {
        contentTextUnderBottomBar(element, in: app) != nil
    }

    /// The text of ``textUnderBottomBar(in:overlappingBars:)`` that `element` is, by label and
    /// frame, so not the bars' own text, nor text elsewhere with the same label; `nil` if none.
    @MainActor
    static func contentTextUnderBottomBar(
        _ element: XCUIElement, in app: XCUIApplication
    ) -> (label: String, occurrence: Int)? {
        guard element.elementType == .staticText, !element.label.isEmpty else { return nil }
        let frame = element.frame
        return textUnderBottomBar(in: app).first {
            $0.label == element.label && $0.frame.insetBy(dx: -0.5, dy: -0.5).contains(frame)
                && frame.insetBy(dx: -0.5, dy: -0.5).contains($0.frame)
        }
        .map { ($0.label, $0.occurrence) }
    }

    /// What ``isUnnamedContrastUnderBottomBar(_:on:in:)`` and ``namedContrastUnderBottomBar(_:on:in:)``
    /// deferred `screen`'s issues for, with a name for failures: the content text under the bottom
    /// bar, after Item detail's metadata if it's under the bar too.
    @MainActor
    static func contentUnderBottomBar(
        on screen: FixtureScreen, in app: XCUIApplication
    ) -> (name: String, elements: [XCUIElement]) {
        let region = bottomBarRegion(in: app)
        let texts = textUnderBottomBar(in: app).map { text in
            let element = app.staticTexts.matching(NSPredicate(format: "label == %@", text.label))
                .element(boundBy: text.occurrence)
            // The occurrence must be the text the snapshot found under the bar, or the re-audit
            // would scroll for, and judge, some other text.
            if !BottomBarAttribution.isUnderBottomBar(element.frame, region: region) {
                XCTFail(
                    "Text '\(text.label)' (occurrence \(text.occurrence)) was under the bottom bar in the "
                        + "snapshot, but resolves to \(element.frame), clear of the region under it \(region)")
            }
            return element
        }
        if screen == .item && metadataOverlapsBottomBar(in: app) {
            return ("metadata", [app.descendants(matching: .any)["item.metadata"].firstMatch] + texts)
        }
        return ("deferred text", texts)
    }

    /// The top of the tab bar along the bottom edge or the mini player, whichever is higher; the
    /// app's bottom without either.
    @MainActor
    static func bottomBarTop(in app: XCUIApplication) -> CGFloat {
        bottomBars(in: app).map(\.frame.minY).min() ?? app.frame.maxY
    }

    /// The region under the bottom bar: the app's width, from ``bottomBarTop(in:)`` down to the
    /// window's bottom edge (``BottomBarAttribution/isUnderBottomBar(_:region:)``); empty without
    /// a bottom bar. #650
    @MainActor
    static func bottomBarRegion(in app: XCUIApplication) -> CGRect {
        let frame = app.frame
        let top = min(bottomBarTop(in: app), frame.maxY)
        return CGRect(x: frame.minX, y: top, width: frame.width, height: frame.maxY - top)
    }

    /// Whether Item detail's metadata (`item.metadata`) is under the bottom bar, in part.
    @MainActor
    static func metadataOverlapsBottomBar(in app: XCUIApplication) -> Bool {
        let metadata = app.descendants(matching: .any)["item.metadata"].firstMatch
        return metadata.exists
            && BottomBarAttribution.isUnderBottomBar(metadata.frame, region: bottomBarRegion(in: app))
    }

    /// Whether `element` is text in the Library section menu (`library.sectionPicker`) in a
    /// navigation bar.
    @MainActor
    private static func isSectionMenuText(_ element: XCUIElement?, in app: XCUIApplication) -> Bool {
        guard let element, element.elementType == .staticText else { return false }
        let menu = app.navigationBars.descendants(matching: .any)["library.sectionPicker"].firstMatch
        return menu.exists && menu.frame.contains(element.frame)
    }

    /// How many tab buttons (`tab.home`, ...) the tab bar floating along the top shows, as on a
    /// regular-width iPad: hittable ones near the window's top (within 120 points) in one row (their
    /// tops within 2 points), counted by identifier, since the bar reports most tabs twice, and at
    /// least two, so a sidebar's rows don't count; `0` with a `TabBar` element or without such a
    /// row. #698
    @MainActor
    static func topTabBarButtonCount(in app: XCUIApplication) -> Int {
        guard !app.tabBars.firstMatch.exists else { return 0 }
        let top = app.windows.firstMatch.frame.minY
        let tabs = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'tab.'")).allElementsBoundByIndex
            .filter { $0.isHittable && $0.frame.maxY < top + 120 }
            .map { (identifier: $0.identifier, minY: $0.frame.minY) }
        let row =
            tabs.map { tab in Set(tabs.filter { abs($0.minY - tab.minY) <= 2 }.map(\.identifier)).count }.max() ?? 0
        return row >= 2 ? row : 0
    }

    /// Whether `issue` is "Dynamic Type font sizes are partially unsupported" with no element, of a
    /// UIKit label: what the top tab bar's titles report at AX5 (``topTabBarButtonCount(in:)``).
    /// Never on macOS, which has no Dynamic Type audit. #698
    static func isUnnamedUILabelDynamicType(_ issue: XCUIAccessibilityAuditIssue) -> Bool {
        #if os(iOS)
            issue.auditType == .dynamicType && issue.element == nil
                && issue.compactDescription.contains("partially unsupported")
                && issue.detailedDescription.contains("UILabel")
        #else
            false
        #endif
    }

    /// Whether `element` is text in a Settings row's switch or button (a `Toggle` or menu `Picker`
    /// row, at least half the form's width), at least 60 points tall: one line of body text at AX5
    /// is 63.5. #698
    @MainActor
    private static func isScaledSettingsRowText(_ element: XCUIElement?, in app: XCUIApplication) -> Bool {
        guard let element, element.elementType == .staticText else { return false }
        let frame = element.frame
        guard frame.height >= 60 else { return false }
        let form = app.descendants(matching: .any)["settings.screen"].firstMatch
        let width = form.frame.width
        let rows = form.switches.allElementsBoundByIndex + form.buttons.allElementsBoundByIndex
        return rows.contains { $0.frame.width >= width / 2 && $0.frame.contains(frame) }
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

    /// Content text, not the bars' or the navigation bar's own, under the bottom bar
    /// (``bottomBarRegion(in:)``, down to the window's bottom edge): each one's label, its
    /// occurrence among the app's texts with that label, in the order of `app.staticTexts` (depth
    /// first, counting the bars' texts too), since Settings repeats values such as "10 seconds",
    /// and its frame. One snapshot of the app, so it's quick however many rows the screen has.
    /// With `overlappingBars`, only text whose frame overlaps a bar's (``bottomBars(in:)``), not
    /// text in the region below them, such as the gap under the iPhone Duo's floating mini player.
    @MainActor
    private static func textUnderBottomBar(
        in app: XCUIApplication, overlappingBars: Bool = false
    ) -> [(label: String, occurrence: Int, frame: CGRect)] {
        let region = bottomBarRegion(in: app)
        let bars = overlappingBars ? bottomBars(in: app).map(\.frame) : []
        guard region.height > 0, let texts = snapshotTexts(in: app)?.texts else { return [] }
        return texts.filter {
            !$0.inBar && !$0.label.isEmpty
                && (overlappingBars
                    ? bars.contains(where: $0.frame.intersects)
                    : BottomBarAttribution.isUnderBottomBar($0.frame, region: region))
        }
        .map { ($0.label, $0.occurrence, $0.frame) }
    }

    /// A text in one snapshot of the app.
    struct SnapshotText {
        /// Its label.
        var label: String
        /// Its occurrence among the app's texts with that label, in the order of `app.staticTexts`.
        var occurrence: Int
        /// Its occurrence among the content's texts with that label, not counting the bars' and
        /// the navigation bar's, whose titles change as the content scrolls.
        var key: ViewText
        var frame: CGRect
        /// Whether it's the tab bar's, the mini player's or the navigation bar's own.
        var inBar: Bool
    }

    /// Content text, by label and occurrence among the content's texts with that label.
    struct ViewText: Hashable {
        var label: String
        var occurrence: Int
    }

    /// Every text in one snapshot of the app, depth first, and the band between the navigation
    /// bar (or the app's top) and the bottom bar.
    @MainActor
    static func snapshotTexts(in app: XCUIApplication) -> (texts: [SnapshotText], band: ClosedRange<CGFloat>)? {
        guard let snapshot = try? app.snapshot() else { return nil }
        var seen: [String: Int] = [:]
        var seenInContent: [String: Int] = [:]
        var texts: [SnapshotText] = []
        var top = app.frame.minY
        func visit(_ node: XCUIElementSnapshot, inBar: Bool) {
            if node.elementType == .navigationBar { top = max(top, node.frame.maxY) }
            let inBar = inBar || startsBar(node)
            if node.elementType == .staticText {
                let occurrence = seen[node.label, default: 0]
                seen[node.label] = occurrence + 1
                let contentOccurrence = seenInContent[node.label, default: 0]
                if !inBar { seenInContent[node.label] = contentOccurrence + 1 }
                texts.append(
                    SnapshotText(
                        label: node.label, occurrence: occurrence,
                        key: ViewText(label: node.label, occurrence: contentOccurrence), frame: node.frame,
                        inBar: inBar))
            }
            for child in node.children { visit(child, inBar: inBar) }
        }
        visit(snapshot, inBar: false)
        return (texts, top...max(top, bottomBarTop(in: app)))
    }

    /// The content's text on screen in the band between the navigation bar and the bottom bar,
    /// with each one's top: the view ``BottomBarAttribution`` keeps on screen. Text partly under
    /// the navigation bar is part of it too, as it's partly on screen. `nil` if the app can't be
    /// snapshotted, so that isn't taken for a view with no text.
    @MainActor
    static func textInView(in app: XCUIApplication) -> [ViewText: CGFloat]? {
        guard let (texts, band) = snapshotTexts(in: app) else { return nil }
        let inView = texts.filter {
            !$0.inBar && !$0.label.isEmpty && !$0.frame.isEmpty && $0.frame.maxY > band.lowerBound + 0.5
                && $0.frame.maxY <= band.upperBound + 0.5
        }
        return Dictionary(inView.map { ($0.key, $0.frame.minY) }, uniquingKeysWith: { a, _ in a })
    }

    /// Whether `node` is a bar whose text isn't the content's: the tab bar, the navigation bar,
    /// or the mini player (`player.mini`) and its controls beside it (`player.mini.close`, ...,
    /// and the transport controls, ``miniPlayerTransport``).
    private static func startsBar(_ node: XCUIElementSnapshot) -> Bool {
        node.elementType == .tabBar || node.elementType == .navigationBar || node.identifier.hasPrefix("player.mini")
            || miniPlayerTransport.contains(node.identifier)
    }

    /// The mini player's transport controls (`TransportControls`). The full player's controls
    /// share these identifiers, but it isn't open on the screens whose bars this is for: Settings
    /// and Item detail. Listed rather than `player.` as a prefix, which would take in the full
    /// player's other elements too.
    private static let miniPlayerTransport: Set<String> = [
        "player.play", "player.pause", "player.jumpBackward", "player.jumpForward",
    ]

    /// The labels of everything in a bar (``startsBar(_:)``): the bars' own text and buttons, such
    /// as the tab items and the mini player's, which ``textInView(in:)`` leaves out. From one
    /// snapshot of the app; `nil` if it can't be snapshotted.
    @MainActor
    static func barLabels(in app: XCUIApplication) -> Set<String>? {
        guard let snapshot = try? app.snapshot() else { return nil }
        var labels: Set<String> = []
        func visit(_ node: XCUIElementSnapshot, inBar: Bool) {
            let inBar = inBar || startsBar(node)
            if inBar && !node.label.isEmpty { labels.insert(node.label) }
            for child in node.children { visit(child, inBar: inBar) }
        }
        visit(snapshot, inBar: false)
        return labels
    }

    /// The labels of `elements` that are texts and of the texts they contain, from one snapshot
    /// of each; `nil` if one can't be snapshotted.
    @MainActor
    static func textLabels(of elements: [XCUIElement]) -> Set<String>? {
        var labels: Set<String> = []
        func visit(_ node: XCUIElementSnapshot) {
            if node.elementType == .staticText && !node.label.isEmpty { labels.insert(node.label) }
            node.children.forEach(visit)
        }
        for element in elements {
            guard let snapshot = try? element.snapshot() else { return nil }
            visit(snapshot)
        }
        return labels
    }

    /// Whether every text in `view` (its first tops) is still in view
    /// (``BottomBarAttribution/isStillInView(_:firstMinY:band:)``), and how far the content can
    /// scroll up before one isn't (the band's height without `view`).
    @MainActor
    static func state(of view: [ViewText: CGFloat], in app: XCUIApplication) -> (visible: Bool, headroom: CGFloat) {
        guard let (texts, band) = snapshotTexts(in: app) else { return (false, 0) }
        let frames = Dictionary(texts.filter { !$0.inBar }.map { ($0.key, $0.frame) }, uniquingKeysWith: { a, _ in a })
        let inView = view.compactMap { key, firstMinY in frames[key].map { ($0, firstMinY) } }
        let visible =
            inView.count == view.count
            && inView.allSatisfy { BottomBarAttribution.isStillInView($0, firstMinY: $1, band: band) }
        let headroom =
            inView.map { BottomBarAttribution.headroom($0, firstMinY: $1, band: band) }.min()
            ?? (band.upperBound - band.lowerBound)
        return (visible, headroom)
    }

    /// Whether `element` is text of the mini player (`player.mini`): its title, or other text the
    /// mini player contains.
    @MainActor
    private static func isMiniPlayerText(_ element: XCUIElement, in app: XCUIApplication) -> Bool {
        guard element.elementType == .staticText, !element.label.isEmpty else { return false }
        if element.identifier.hasPrefix("player.mini") { return true }
        let mini = app.buttons["player.mini"].firstMatch
        return mini.exists && mini.frame.contains(element.frame)
            && mini.descendants(matching: .staticText).matching(NSPredicate(format: "label == %@", element.label))
                .firstMatch.exists
    }

    /// The tab bar, if it's along the bottom edge, and the mini player, where they exist. A tab bar
    /// that's a vertical pill at the side, as on the iPhone Duo's outer display, isn't a bottom bar:
    /// its frame starts at the top, and the mini player floats at the bottom instead. #648
    @MainActor
    private static func bottomBars(in app: XCUIApplication) -> [XCUIElement] {
        let tabBar = app.tabBars.firstMatch
        let mini = app.buttons["player.mini"].firstMatch
        var bars = mini.exists ? [mini] : []
        if tabBar.exists {
            let frame = tabBar.frame
            if !isSideBar(frame) && frame.maxY >= app.frame.maxY - 4 { bars.append(tabBar) }
        }
        return bars
    }

    /// The right edge of the content no side bar covers: the left edge of a tab bar that's a
    /// vertical pill on the right, as on the iPhone Duo's outer display (x 397 of 466), or the
    /// app's right edge. #648
    @MainActor
    static func contentMaxX(in app: XCUIApplication) -> CGFloat {
        let tabBar = app.tabBars.firstMatch
        guard tabBar.exists else { return app.frame.maxX }
        let frame = tabBar.frame
        guard isSideBar(frame), frame.minX > app.frame.midX else { return app.frame.maxX }
        return min(app.frame.maxX, frame.minX)
    }

    /// Whether a tab bar's `frame` is a vertical pill at the side (taller than wide), not a bar
    /// along the bottom edge.
    private static func isSideBar(_ frame: CGRect) -> Bool {
        frame.height > frame.width
    }

    /// Whether `element` is one of the player's remaining times: text that's a minus and a
    /// timestamp, such as "-0:26" or "-1:02:03".
    @MainActor
    private static func isRemainingTime(_ element: XCUIElement?, in app: XCUIApplication) -> Bool {
        guard let element, element.elementType == .staticText else { return false }
        return NSPredicate(format: "SELF MATCHES %@", "-[0-9]+(:[0-9]{2})+").evaluate(with: element.label)
    }

    /// Whether a screenshot taken now measures 4.5:1 or more around the player's time or chapter
    /// title `element`, in the colour the app draws them in for the theme (`FixtureTheme.playerTimes`).
    /// No measurement is false. #653, #655, #698
    @MainActor
    private static func measuresReadable(_ element: XCUIElement, in app: XCUIApplication) -> Bool {
        let text = FixtureTheme.playerTimes(FixtureTheme(launchArguments: app.launchArguments))
        let ratio = MeasuredContrast.ratio(in: element.frame, of: XCUIScreen.main.screenshot(), text: text)
        return ratio.map { $0 >= 4.5 } ?? false
    }

    /// Whether `element` is one of the player's elapsed times: text that's a timestamp, such as
    /// "0:02" or "1:02:03".
    @MainActor
    private static func isElapsedTime(_ element: XCUIElement) -> Bool {
        guard element.elementType == .staticText else { return false }
        return NSPredicate(format: "SELF MATCHES %@", "[0-9]+(:[0-9]{2})+").evaluate(with: element.label)
    }
}
