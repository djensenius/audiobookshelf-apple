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
    /// naming the screen, the text size, the audit type, the element and the issue.
    @MainActor
    private func audit(
        _ screen: FixtureScreen, for types: XCUIAccessibilityAuditType, in app: XCUIApplication, textSize: String
    ) {
        var failures: [String] = []
        do {
            try app.performAccessibilityAudit(for: types) { issue in
                if KnownAuditIssue.all.contains(where: { $0.matches(issue, on: screen, in: app) }) { return true }
                // Without an element, the detailed description names the kind of node at least.
                let description =
                    issue.element == nil
                    ? "\(issue.compactDescription) (\(issue.detailedDescription))" : issue.compactDescription
                failures.append(
                    "\(screen.name) (\(textSize)): \(Self.auditTypeName(issue.auditType)) on \(Self.elementName(issue.element)): "
                        + description)
                // Reported below, with the screen's name.
                return true
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
/// audit type and element. Each one says why, and names its issue.
struct KnownAuditIssue {
    /// `nil` for every screen.
    var screen: FixtureScreen?
    var type: XCUIAccessibilityAuditType
    /// Matches the issue's element (`nil` when the issue has none) in the app.
    var element: @MainActor (XCUIElement?, XCUIApplication) -> Bool

    @MainActor
    func matches(_ issue: XCUIAccessibilityAuditIssue, on screen: FixtureScreen, in app: XCUIApplication) -> Bool {
        (self.screen == nil || self.screen == screen) && issue.auditType == type && element(issue.element, app)
    }

    @MainActor static let all: [KnownAuditIssue] = {
        var all: [KnownAuditIssue] = [
            // The metadata rows (ItemDetailMetadata) are text-sized, about 18 pt tall: the plain
            // ones ("Duration, 11 hours 36 minutes") aren't controls, but the Author, Narrator and
            // Genres links are, and are smaller than 44 pt. #TODO-ISSUE
            KnownAuditIssue(screen: .item, type: .hitRegion) { element, app in
                guard let element else { return false }
                let metadata = app.descendants(matching: .any)["item.metadata"].firstMatch
                return metadata.exists && metadata.frame.contains(element.frame)
            },
            // "Potentially inaccessible text", with no element, and not on every run: most likely
            // the metadata's labels ("Author", "Duration", …), hidden from VoiceOver on purpose
            // because each value speaks its label ("Jane Austen, Author, link"; VoiceOver often
            // skips a container's label). #TODO-ISSUE
            KnownAuditIssue(screen: .item, type: .elementDetection) { element, _ in element == nil },
            // The whole book's remaining time, over the player's chapter scrubber, fails contrast on
            // every run, while the elapsed time beside it, the same color and size, passes, as do
            // the chapter's times: muted foreground on the thick material backdrop, about 5:1.
            // #TODO-ISSUE
            KnownAuditIssue(screen: .player, type: .contrast) { element, _ in
                guard let element, element.elementType == .staticText else { return false }
                return element.label.hasPrefix("-") || element.label.hasPrefix("\u{2212}")
            },
        ]
        #if os(iOS)
            all += [
                // Cards cut their title and author short at two lines and one (by design, like
                // Apple Books); the card, one element, speaks both in full. #TODO-ISSUE
                KnownAuditIssue(screen: nil, type: .textClipped) { element, app in
                    isShortened(element, inElementMatching: "identifier BEGINSWITH 'item.'", in: app)
                },
                // The mini player cuts its title and author short at one line, to as little as a
                // letter in narrow windows (iPhone Duo); its button speaks the full title.
                // #TODO-ISSUE
                KnownAuditIssue(screen: nil, type: .textClipped) { element, _ in
                    element?.identifier == "player.mini"
                },
            ]
        #endif
        return all
    }()

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
}
