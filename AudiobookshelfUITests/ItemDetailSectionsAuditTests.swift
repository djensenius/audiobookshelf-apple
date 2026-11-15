import XCTest

/// Audits the contrast of Item detail's Chapters and Audio Tracks headers, with their counts, on
/// iOS. They're below the metadata, so `AccessibilityAuditTests`, which audits the screen as it
/// opens, never has them on screen. #638
final class ItemDetailSectionsAuditTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    #if os(iOS)
        /// The section headers *Pride and Prejudice* has: Chapters and Audio Tracks.
        private static let headerIdentifiers = ["item.chapters", "item.tracks"]

        /// Scrolls the headers clear of the tab bar, audits contrast and fails for every issue on a
        /// header. Issues elsewhere on screen are `AccessibilityAuditTests`'.
        @MainActor
        func testSectionHeadersContrast() {
            let app = signIn()
            let detail = open(.item, in: app)
            let headers = Self.headerIdentifiers.map { detail.descendants(matching: .any)[$0].firstMatch }
            scrollIntoView(headers, of: detail, in: app)
            let frames = headers.map(\.frame)
            var failures: [String] = []
            do {
                try app.performAccessibilityAudit(for: .contrast) { issue in
                    if let element = issue.element, frames.contains(where: { $0.intersects(element.frame) }) {
                        failures.append(
                            "Item detail's sections: contrast on '\(element.label)': \(issue.compactDescription)")
                    }
                    return true
                }
            } catch {
                XCTFail("Item detail's sections: the accessibility audit failed to run: \(error)")
            }
            guard !failures.isEmpty else { return }
            let screenshot = XCTAttachment(screenshot: app.screenshot())
            screenshot.name = "audit-item-sections"
            screenshot.lifetime = .keepAlways
            add(screenshot)
            continueAfterFailure = true
            for failure in failures { XCTFail(failure) }
        }

        /// Swipes Item detail up until every header is on screen and clear of the tab bar.
        @MainActor
        private func scrollIntoView(_ headers: [XCUIElement], of detail: XCUIElement, in app: XCUIApplication) {
            let window = app.windows.firstMatch.frame
            let tabBar = app.tabBars.firstMatch
            func isClear(_ header: XCUIElement) -> Bool {
                header.exists && header.isHittable && window.contains(header.frame)
                    && !(tabBar.exists && tabBar.frame.intersects(header.frame))
            }
            for _ in 0..<8 where !headers.allSatisfy(isClear) {
                detail.swipeUp(velocity: .slow)
            }
            for (identifier, header) in zip(Self.headerIdentifiers, headers) {
                XCTAssertTrue(
                    isClear(header), "Item detail's \(identifier) header isn't on screen clear of the tab bar")
            }
        }
    #endif
}
