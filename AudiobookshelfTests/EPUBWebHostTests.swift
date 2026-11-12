import Foundation
import Testing
import WebKit

@testable import Audiobookshelf

/// Records what the scheme handler tells WebKit about one request. The handler calls it on the main
/// actor, as WebKit does.
@MainActor
private final class FakeSchemeTask: NSObject, @preconcurrency WKURLSchemeTask {
    let request: URLRequest
    private(set) var response: URLResponse?
    private(set) var body = Data()
    private(set) var finished = false
    private(set) var error: (any Error)?
    private var done: CheckedContinuation<Void, Never>?

    init(_ url: String) {
        request = URLRequest(url: URL(string: url)!)
    }

    var status: Int? { (response as? HTTPURLResponse)?.statusCode }
    func header(_ name: String) -> String? { (response as? HTTPURLResponse)?.value(forHTTPHeaderField: name) }
    var isComplete: Bool { finished || error != nil }

    func didReceive(_ response: URLResponse) { self.response = response }
    func didReceive(_ data: Data) { body.append(data) }
    func didFinish() {
        finished = true
        resume()
    }
    func didFailWithError(_ error: any Error) {
        self.error = error
        resume()
    }

    /// Waits until the handler finishes or fails this task.
    func completion() async {
        if isComplete { return }
        await withCheckedContinuation { done = $0 }
    }

    private func resume() {
        done?.resume()
        done = nil
    }
}

/// A book load that waits until the test lets it finish.
private actor BookGate {
    private var waiting: CheckedContinuation<Void, Never>?
    private var opened = false
    private(set) var requested: [String] = []

    func load(_ id: String) async -> Data {
        requested.append(id)
        if !opened { await withCheckedContinuation { waiting = $0 } }
        return Data("book \(id)".utf8)
    }

    func open() {
        opened = true
        waiting?.resume()
        waiting = nil
    }
}

private struct LoadFailed: Error {}

@MainActor
@Suite struct EPUBWebHostTests {
    private let webView = WKWebView()

    /// A handler serving the bundled reader files and `loadBook`'s books.
    private func handler(
        loadBook: @escaping EPUBSchemeHandler.BookLoader = { Data("book \($0)".utf8) }
    ) -> EPUBSchemeHandler {
        EPUBSchemeHandler(loadBook: loadBook)
    }

    private func start(_ url: String, on handler: EPUBSchemeHandler) async -> FakeSchemeTask {
        let task = FakeSchemeTask(url)
        handler.webView(webView, start: task)
        await task.completion()
        return task
    }

    /// The bundled reader file's text.
    private func bundled(_ name: String) throws -> String {
        let url = try #require(EPUBSchemeHandler.bundledFile(name), "\(name) isn't in the app bundle")
        return try String(contentsOf: url, encoding: .utf8)
    }

    // MARK: Scheme handler

    @Test(arguments: [
        ("reader.html", "text/html; charset=utf-8"), ("reader.js", "text/javascript; charset=utf-8"),
        ("epub.min.js", "text/javascript; charset=utf-8"), ("jszip.min.js", "text/javascript; charset=utf-8"),
    ])
    func servesTheBundledReaderFiles(name: String, mimeType: String) async throws {
        let task = await start("absreader://app/\(name)", on: handler())

        #expect(task.status == 200)
        #expect(task.header("Content-Type") == mimeType)
        #expect(task.body == (try Data(contentsOf: #require(EPUBSchemeHandler.bundledFile(name)))))
        #expect(!task.body.isEmpty)
        #expect(task.finished)
    }

    @Test(arguments: [
        "absreader://app/missing.js", "absreader://app/LICENSE-epubjs", "absreader://app/",
        "absreader://app/Web/reader.html", "absreader://other/reader.html", "absreader://book/",
        "absreader://book/a.zip",
        "absreader://book/a/b.epub", "absreader://book/.epub",
    ])
    func refusesAnythingElseWith404(url: String) async throws {
        let task = await start(
            url,
            on: handler(loadBook: { _ in
                Issue.record("loaded a book"); return Data()
            }))

        #expect(task.status == 404)
        #expect(task.body.isEmpty)
        #expect(task.finished)
    }

    @Test func servesTheBookFromTheLoader() async {
        let task = await start("absreader://book/li_abc%20123.epub", on: handler())

        #expect(task.status == 200)
        #expect(task.header("Content-Type") == "application/epub+zip")
        #expect(task.header("Access-Control-Allow-Origin") == "absreader://app")
        #expect(task.body == Data("book li_abc 123".utf8))
        #expect(task.finished)
    }

    @Test func aFailedBookLoadFailsTheTask() async {
        let task = await start("absreader://book/x.epub", on: handler(loadBook: { _ in throw LoadFailed() }))

        #expect(task.error is LoadFailed)
        #expect(task.response == nil)
        #expect(!task.finished)
    }

    @Test func aStoppedBookLoadDeliversNothing() async {
        let gate = BookGate()
        let handler = handler(loadBook: { await gate.load($0) })
        let task = FakeSchemeTask("absreader://book/x.epub")

        handler.webView(webView, start: task)
        while await gate.requested.isEmpty { await Task.yield() }
        handler.webView(webView, stop: task)
        await gate.open()
        for _ in 0..<50 { await Task.yield() }

        #expect(task.response == nil)
        #expect(task.body.isEmpty)
        #expect(!task.isComplete)
    }

    // MARK: Message handler

    @Test func passesEventObjectsOnAsJSON() throws {
        let body: [String: Any] = ["type": "tap", "x": 0.5, "y": 0.25]
        let data = try #require(EPUBMessageHandler.json(from: body))
        let decoded = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(decoded["type"] as? String == "tap")
        #expect(decoded["x"] as? Double == 0.5)
        #expect(decoded["y"] as? Double == 0.25)
    }

    @Test func dropsBodiesThatAreNotJSONObjects() {
        #expect(EPUBMessageHandler.json(from: "ready") == nil)
        #expect(EPUBMessageHandler.json(from: [1, 2]) == nil)
        #expect(EPUBMessageHandler.json(from: ["type": Date()]) == nil)
    }

    // MARK: Bridge contract

    /// Every command and event the bridge contract names appears in `reader.js`, so a rename on
    /// either side shows up here.
    @Test func readerScriptImplementsTheContract() throws {
        let script = try bundled("reader.js")
        let commands = ["open", "display", "next", "prev", "applySettings"]
        let events = ["ready", "toc", "locationsReady", "relocated", "tap", "error"]
        for name in commands + events {
            #expect(script.contains("'\(name)'"), "reader.js doesn't name '\(name)'")
        }
        for field in [
            "startCfi", "endCfi", "progress", "href", "atStart", "atEnd", "locations", "items", "phase", "target",
        ] {
            #expect(script.contains(field), "reader.js doesn't use \(field)")
        }
        #expect(script.contains("window.absReader"))
        #expect(script.contains("messageHandlers.\(EPUBMessageHandler.name)"))
        #expect(script.contains("allowScriptedContent: false"))
    }

    @Test func readerPageHasAStrictPolicyAndLoadsTheScriptsInOrder() throws {
        let page = try bundled("reader.html")

        #expect(page.contains("Content-Security-Policy"))
        #expect(page.contains("default-src 'none'"))
        #expect(page.contains("script-src 'self'"))
        #expect(!page.contains("unsafe-eval"))
        let order = ["jszip.min.js", "epub.min.js", "reader.js"].compactMap { page.range(of: $0)?.lowerBound }
        #expect(order.count == 3)
        #expect(order == order.sorted())
    }

    // MARK: Web view

    @Test func navigationStaysOnTheReaderPage() {
        #expect(EPUBReaderController.allowsNavigation(to: EPUBSchemeHandler.readerURL, isMainFrame: true))
        #expect(!EPUBReaderController.allowsNavigation(to: URL(string: "https://example.com"), isMainFrame: true))
        #expect(!EPUBReaderController.allowsNavigation(to: URL(string: "absreader://book/x.epub"), isMainFrame: true))
        #expect(EPUBReaderController.allowsNavigation(to: URL(string: "about:srcdoc"), isMainFrame: false))
        #expect(EPUBReaderController.allowsNavigation(to: URL(string: "blob:absreader://app/1"), isMainFrame: false))
        #expect(!EPUBReaderController.allowsNavigation(to: URL(string: "https://example.com"), isMainFrame: false))
        #expect(!EPUBReaderController.allowsNavigation(to: nil, isMainFrame: false))
    }

    /// The page loads through the scheme handler with its policy, its scripts run, and the bridge
    /// answers: `ready` arrives, and a command the page rejects throws and posts `error`.
    @Test(.timeLimit(.minutes(1))) func thePageLoadsAndTheBridgeAnswers() async throws {
        let controller = EPUBReaderController(loadBook: { _ in Data() })
        var events: [[String: Any]] = []
        controller.onEvent = { data in
            if let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { events.append(event) }
        }
        while !events.contains(where: { $0["type"] as? String == "ready" }) {
            try await Task.sleep(for: .milliseconds(20))
        }

        let globals = try await controller.webView.evaluateJavaScript(
            "[typeof JSZip, typeof ePub, typeof window.absReader.handle].join()")
        #expect(globals as? String == "function,function,function")

        await #expect(throws: (any Error).self) { try await controller.send(Data(#"{"type":"next"}"#.utf8)) }
        let error = events.last { $0["type"] as? String == "error" }
        #expect(error?["phase"] as? String == "next")
        #expect(error?["message"] as? String == "No book is open")
    }

    /// A book opens through the bridge: the page fetches it through the scheme (cross-origin, under
    /// the page's policy), unzips it, and posts its contents. Laying out pages needs animation
    /// frames, which WebKit doesn't run for a page that isn't on screen, as in the test host, so
    /// this stops at `toc` rather than waiting for `open` to finish.
    @Test(.timeLimit(.minutes(1))) func aBookOpensThroughTheScheme() async throws {
        let controller = EPUBReaderController(loadBook: { id in
            guard id == "tiny" else { throw URLError(.fileDoesNotExist) }
            return TinyEPUB.data
        })
        var events: [[String: Any]] = []
        controller.onEvent = { data in
            if let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { events.append(event) }
        }
        func event(_ type: String) -> [String: Any]? { events.last { $0["type"] as? String == type } }
        while event("ready") == nil { try await Task.sleep(for: .milliseconds(20)) }

        let open: [String: Any] = [
            "type": "open", "url": "absreader://book/tiny.epub",
            "settings": [
                "theme": "light", "fontScale": 100, "lineSpacing": 115, "spread": "none", "gap": 0,
                "themeRules": ["body": ["color": "#000000", "background": "#ffffff"]],
            ],
        ]
        let command = try JSONSerialization.data(withJSONObject: open)
        let opening = Task { try await controller.send(command) }
        defer { opening.cancel() }
        while event("toc") == nil, event("error") == nil { try await Task.sleep(for: .milliseconds(20)) }

        #expect(event("error") == nil)
        let toc = try #require(event("toc")?["items"] as? [[String: Any]])
        #expect(toc.map { $0["label"] as? String } == [TinyEPUB.chapterTitle])
        #expect(toc.map { $0["href"] as? String } == ["c1.xhtml"])
    }

    /// A book the scheme can't serve fails `open` (rather than leaving it pending) and says so.
    @Test(.timeLimit(.minutes(1))) func aBookThatFailsToLoadFailsOpen() async throws {
        let controller = EPUBReaderController(loadBook: { _ in throw URLError(.fileDoesNotExist) })
        var events: [[String: Any]] = []
        controller.onEvent = { data in
            if let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { events.append(event) }
        }
        while !events.contains(where: { $0["type"] as? String == "ready" }) {
            try await Task.sleep(for: .milliseconds(20))
        }

        let open: [String: Any] = [
            "type": "open", "url": "absreader://book/missing.epub", "settings": ["themeRules": [:] as [String: Any]],
        ]
        await #expect(throws: (any Error).self) {
            try await controller.send(JSONSerialization.data(withJSONObject: open))
        }
        let error = events.last { $0["type"] as? String == "error" }
        #expect(error?["phase"] as? String == "open")
        #expect((error?["message"] as? String)?.isEmpty == false)
    }

    @Test func aCommandMustBeAJSONObject() async {
        let controller = EPUBReaderController(loadBook: { _ in Data() })

        await #expect(throws: EPUBReaderController.CommandError.notAnObject) {
            try await controller.send(Data("[]".utf8))
        }
    }
}
