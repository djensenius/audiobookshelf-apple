import XCTest

/// The download queue indicator (#75): while a download is under way, every tab root's bar but the Downloads root's
/// shows it, as a ring around the count (#686), even on the compact Library root, whose bar is crowded (#685). The
/// fixture server stalls the download halfway (`-ABSStallDownloads`, `FixtureServer.stallDownloadsArgument`), so it
/// stays in the queue.
final class DownloadQueueIndicatorTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testIndicatorIsInEveryTabRootsBar() {
        let app = signIn(launchArguments: ["-ABSStallDownloads"])
        open(.item, in: app)
        let download = app.buttons["item.download"].firstMatch
        XCTAssertTrue(download.waitForEnabled(timeout: Self.fixtureTimeout), "The item's Download button isn't enabled")
        download.press()

        let indicator = app.buttons["downloads.queueIndicator"].firstMatch
        for screen in [FixtureScreen.home, .library] {
            open(screen, in: app)
            // A bar's overflow menu isn't in the hierarchy until it opens, so an item moved there doesn't exist.
            let exists = indicator.waitForExistence(timeout: Self.fixtureTimeout)
            let screenshot = XCTAttachment(screenshot: app.screenshot())
            screenshot.name = "queue-\(screen.rawValue)"
            screenshot.lifetime = .keepAlways
            add(screenshot)
            XCTAssertTrue(exists, "\(screen.name)'s bar has no queue indicator")
            XCTAssertTrue(indicator.isHittable, "\(screen.name)'s queue indicator can't be pressed")
            // The ring's count is hidden from accessibility: the label names the button, and the value has the
            // count and progress (`LabelDownloadQueueAccessibility`), such as "1 download, 50% done" in English.
            XCTAssertFalse(indicator.label.isEmpty, "\(screen.name)'s queue indicator has no label")
            XCTAssertNotEqual(indicator.label, "1", "\(screen.name)'s queue indicator is labelled with its count")
            let value = indicator.value as? String ?? ""
            XCTAssertTrue(
                value.contains("1") && value.contains("%"),
                "\(screen.name)'s queue indicator's value (\(value)) doesn't give the count and progress")
        }

        // The Library root opens the queue on its own stack.
        indicator.press()
        let queue = app.descendants(matching: .any)["downloads.list"].firstMatch
        XCTAssertTrue(queue.waitForExistence(timeout: Self.fixtureTimeout), "The download queue didn't open")

        // The Downloads root lists the downloads under way itself.
        open(.downloads, in: app)
        XCTAssertFalse(indicator.exists, "The Downloads root's bar has the queue indicator")
    }
}
