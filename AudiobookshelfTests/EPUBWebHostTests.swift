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

/// The reader page in a web view, with the events it posts.
@MainActor
private final class ReaderPage {
    let controller: EPUBReaderController
    private(set) var events: [[String: Any]] = []

    /// A page whose books come from `loadBook`, once it's `ready`.
    init(loadBook: @escaping EPUBSchemeHandler.BookLoader) async throws {
        controller = EPUBReaderController(loadBook: loadBook)
        controller.onEvent = { [weak self] data in
            if let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                self?.events.append(event)
            }
        }
        _ = try await next("ready")
    }

    func last(_ type: String) -> [String: Any]? { events.last { $0["type"] as? String == type } }

    /// The first `type` event, waiting for it if need be.
    func next(_ type: String) async throws -> [String: Any] {
        while true {
            if let event = events.first(where: { $0["type"] as? String == type }) { return event }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    /// Opens `absreader://book/<id>.epub`.
    func open(_ id: String, settings: [String: Any] = [:]) async throws {
        let command: [String: Any] = [
            "type": "open", "url": "absreader://book/\(id).epub",
            "settings": settings.merging(["themeRules": [:] as [String: Any]]) { mine, _ in mine },
        ]
        try await controller.send(JSONSerialization.data(withJSONObject: command))
    }

    /// Gives up on a table of contents after 100 ms rather than the page's 10 s, which WebKit's
    /// throttling of an off-screen page's timers stretches past the tests' time limit.
    func shortenNavigationDeadline() async throws {
        _ = try await controller.webView.evaluateJavaScript("window.absReaderNavigationTimeoutMs = 100; 1")
    }

    /// The JSON of what `expression` evaluates to in the page.
    func evaluate(_ expression: String) async throws -> String? {
        try await controller.webView.evaluateJavaScript("JSON.stringify(\(expression))") as? String
    }

    /// Replaces epub.js with a stand-in whose sections fail to display with `displayError`, if
    /// given, and whose table of contents never loads unless `navigation`.
    func fakeEPUBJS(displayError: String? = nil, navigation: Bool = true) async throws {
        let options = try JSONSerialization.data(withJSONObject: [
            "displayError": displayError ?? "", "navigation": navigation,
        ])
        _ = try await controller.webView.evaluateJavaScript(
            "window.fakeOptions = \(String(decoding: options, as: UTF8.self));\n\(Self.fakeEPUBJS)")
    }

    private static let fakeEPUBJS = """
        window.ePub = function () {
          const options = window.fakeOptions
          const never = new Promise(function () {})
          function emitter(target) {
            const listeners = {}
            target.on = function (type, f) { (listeners[type] = listeners[type] || []).push(f) }
            target.off = function (type, f) {
              listeners[type] = (listeners[type] || []).filter(function (g) { return g !== f })
            }
            target.emit = function (type, value) {
              (listeners[type] || []).slice().forEach(function (f) { f(value) })
            }
            return target
          }
          window.fakeOverrides = {}
          const rendition = emitter({
            settings: {},
            themes: {
              register: function () {}, select: function () {}, fontSize: function () {},
              font: function (family) { window.fakeOverrides['font-family'] = family },
              removeOverride: function (name) { delete window.fakeOverrides[name] }
            },
            spread: function () {},
            currentLocation: function () { return null },
            display: function () {
              if (!options.displayError) return Promise.resolve()
              setTimeout(function () { rendition.emit('displayerror', new Error(options.displayError)) }, 0)
              return never
            }
          })
          return emitter({
            opened: Promise.resolve(),
            ready: never,
            loaded: { navigation: options.navigation ? Promise.resolve({ toc: [] }) : never },
            spine: { get: function () { return null } },
            locations: {
              load: function () {}, length: function () { return 0 },
              generate: function () { return never }, save: function () { return '' }
            },
            renderTo: function () { return rendition },
            destroy: function () {}
          })
        }
        1
        """
}

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

    /// A book whose entries inflate past the limit is refused before epub.js inflates any of it,
    /// counting what an entry actually inflates to rather than the size its header claims.
    @Test(.timeLimit(.minutes(1))) func aBookThatInflatesTooFarIsRefused() async throws {
        let filler = TinyEPUB.Entry(
            name: "OEBPS/filler.bin", body: Data(count: 64 * 1024 * 1024 + 1), deflated: true, claimedSize: 1024,
            claimedCRC: 0)
        let page = try await ReaderPage(loadBook: { _ in TinyEPUB.data(extra: [filler]) })

        await #expect(throws: (any Error).self) { try await page.open("bomb") }

        let error = try #require(page.last("error"))
        #expect(error["phase"] as? String == "open")
        #expect((error["message"] as? String)?.contains("expands beyond") == true)
        #expect(page.last("toc") == nil)
    }

    /// epub.js only says `displayerror` when a section won't display; `open` and `display` fail.
    @Test(.timeLimit(.minutes(1))) func aSectionThatWontDisplayFailsTheCommand() async throws {
        let page = try await ReaderPage(loadBook: { _ in TinyEPUB.data })
        try await page.fakeEPUBJS(displayError: "No such section")

        await #expect(throws: (any Error).self) { try await page.open("tiny") }
        await #expect(throws: (any Error).self) {
            try await page.controller.send(Data(#"{"type":"display","target":"c1.xhtml"}"#.utf8))
        }

        let errors = page.events.filter { $0["type"] as? String == "error" }
        #expect(errors.map { $0["phase"] as? String } == ["display", "display"])
        #expect(errors.map { $0["message"] as? String } == ["No such section", "No such section"])
    }

    /// `open` doesn't wait for the table of contents, which epub.js never settles for a missing
    /// navigation document; the page reports it once its deadline passes.
    @Test(.timeLimit(.minutes(1))) func openDoesNotWaitForTheTableOfContents() async throws {
        let page = try await ReaderPage(loadBook: { _ in TinyEPUB.data })
        try await page.fakeEPUBJS(navigation: false)
        try await page.shortenNavigationDeadline()

        try await page.open("tiny")
        let error = try await page.next("error")

        #expect(error["phase"] as? String == "toc")
        #expect(page.last("toc") == nil)
    }

    /// With the real epub.js, a book missing its navigation document still opens, and says the
    /// table of contents didn't load.
    @Test(.timeLimit(.minutes(1))) func aMissingNavigationDocumentIsReported() async throws {
        let page = try await ReaderPage(loadBook: { _ in TinyEPUB.data(navigation: false) })
        try await page.shortenNavigationDeadline()
        let opening = Task { try await page.open("tiny") }
        defer { opening.cancel() }

        let error = try await page.next("error")

        #expect(error["phase"] as? String == "toc")
        #expect(page.events.filter { $0["type"] as? String == "error" }.count == 1)
    }

    /// When a book is opened while an earlier one is still loading, the earlier one's failure
    /// fails its own command and posts nothing into the new book's events.
    @Test(.timeLimit(.minutes(1))) func aSupersededOpensFailureStaysQuiet() async throws {
        let gate = BookGate()
        let page = try await ReaderPage(loadBook: { id in
            guard id == "slow" else { return TinyEPUB.data }
            _ = await gate.load(id)
            throw LoadFailed()
        })

        let first = Task { try await page.open("slow") }
        while await gate.requested.isEmpty { await Task.yield() }
        let second = Task { try await page.open("tiny") }
        defer { second.cancel() }
        _ = try await page.next("toc")
        await gate.open()

        await #expect(throws: (any Error).self) { try await first.value }
        #expect(page.last("error") == nil)
    }

    /// The font family overrides the book's, as the legacy reader's does; without one, the book's
    /// own font comes back.
    @Test(.timeLimit(.minutes(1))) func theFontFamilyOverridesTheBooks() async throws {
        let page = try await ReaderPage(loadBook: { _ in TinyEPUB.data })
        try await page.fakeEPUBJS()

        try await page.open("tiny", settings: ["fontFamily": "sans-serif"])
        #expect(try await page.evaluate("window.fakeOverrides") == #"{"font-family":"sans-serif"}"#)

        let serif = #"{"type":"applySettings","settings":{"themeRules":{},"fontFamily":"serif"}}"#
        try await page.controller.send(Data(serif.utf8))
        #expect(try await page.evaluate("window.fakeOverrides") == #"{"font-family":"serif"}"#)

        try await page.controller.send(Data(#"{"type":"applySettings","settings":{"themeRules":{}}}"#.utf8))
        #expect(try await page.evaluate("window.fakeOverrides") == "{}")
    }

    /// Only the reader's two font families are accepted.
    @Test(.timeLimit(.minutes(1))) func anUnknownFontFamilyIsRefused() async throws {
        let page = try await ReaderPage(loadBook: { _ in TinyEPUB.data })
        try await page.fakeEPUBJS()
        try await page.open("tiny", settings: ["fontFamily": "serif"])

        let comic = #"{"type":"applySettings","settings":{"themeRules":{},"fontFamily":"Comic Sans MS"}}"#
        await #expect(throws: (any Error).self) { try await page.controller.send(Data(comic.utf8)) }

        #expect(page.last("error")?["phase"] as? String == "applySettings")
        #expect(try await page.evaluate("window.fakeOverrides") == #"{"font-family":"serif"}"#)
    }

    @Test func aCommandMustBeAJSONObject() async {
        let controller = EPUBReaderController(loadBook: { _ in Data() })

        await #expect(throws: EPUBReaderController.CommandError.notAnObject) {
            try await controller.send(Data("[]".utf8))
        }
    }
}
