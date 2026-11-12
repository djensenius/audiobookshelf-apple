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

    /// Opens `absreader://book/<id>.epub`, with cached `locations` if given.
    func open(_ id: String, settings: [String: Any] = [:], locations: String? = nil) async throws {
        var command: [String: Any] = [
            "type": "open", "url": "absreader://book/\(id).epub",
            "settings": settings.merging(["themeRules": [:] as [String: Any]]) { mine, _ in mine },
        ]
        command["locations"] = locations
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
    /// given, or never finish displaying while `window.fakeOptions.displayHangs`; whose books never
    /// open while `window.fakeOptions.openedHangs`; and whose table of contents is `toc`, from a
    /// navigation document at `navPath`, but never loads unless `navigation`; whose spine is
    /// `spineLength` long, with CFI bases `cfiBase` characters long; and whose locations never finish,
    /// once one section's are parsed as `locationCharacters` characters, if given. Its starting rendition takes the spread `true`, as
    /// epub.js's does for a book whose metadata says `both`. The latest book and rendition are
    /// `window.fakeBook` and `window.fakeRendition`; the sections it shows, `window.fakeContents`.
    func fakeEPUBJS(
        displayError: String? = nil, displayHangs: Bool = false, openedHangs: Bool = false, navigation: Bool = true,
        toc: [[String: Any]] = [], navPath: String? = nil, packageDirectory: String = "/", failTarget: String = "",
        spineLength: Int = 0, cfiBase: Int = 0, locationCharacters: Int = 0
    ) async throws {
        let options = try JSONSerialization.data(withJSONObject: [
            "displayError": displayError ?? "", "displayHangs": displayHangs, "openedHangs": openedHangs,
            "navigation": navigation, "toc": toc, "navPath": navPath ?? "", "packageDirectory": packageDirectory,
            "failTarget": failTarget, "spineLength": spineLength, "cfiBase": cfiBase,
            "locationCharacters": locationCharacters,
        ])
        _ = try await controller.webView.evaluateJavaScript(
            "window.fakeOptions = \(String(decoding: options, as: UTF8.self));\n\(Self.fakeEPUBJS)")
    }

    private static let fakeEPUBJS = """
        window.ePub = function () {
          const options = window.fakeOptions
          const never = new Promise(function () {})
          let queue = Promise.resolve()
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
          window.fakeContents = []
          // As epub.js's themes do: overrides go on each section's body.
          const css = function (name, value) {
            window.fakeContents.forEach(function (contents) {
              if (value) contents.content.style.setProperty(name, value, 'important')
              else contents.content.style.removeProperty(name)
            })
          }
          const rendition = window.fakeRendition = emitter({
            settings: {},
            themes: {
              register: function () {}, select: function () {}, fontSize: function () {},
              font: function (family) { window.fakeOverrides['font-family'] = family; css('font-family', family) },
              removeOverride: function (name) {
                window.fakeRemovals = (window.fakeRemovals || 0) + 1
                delete window.fakeOverrides[name]
                css(name)
              }
            },
            spread: function (value) { window.fakeSpread = value },
            started: new Promise(function (resolve) {
              setTimeout(function () { window.fakeSpread = true; resolve() }, 0)
            }),
            getContents: function () { return window.fakeContents },
            currentLocation: function () { return null },
            display: function (target) {
              window.fakeDisplays = (window.fakeDisplays || 0) + 1
              // Held, as epub.js's queue holds it: WebKit fails a call whose promise it collects.
              if (window.fakeOptions.displayHangs) {
                return new Promise(function (resolve) { (window.fakeHeld = window.fakeHeld || []).push(resolve) })
              }
              if (!options.displayError) return Promise.resolve()
              // As epub.js's queue does: one display at a time, and a failed one holds the queue until
              // `displaying` settles. Only `failTarget` fails, if given, once the test calls `fakeFail`.
              return (queue = queue.then(function () {
                if (options.failTarget && target !== options.failTarget) return
                return new Promise(function (resolve) {
                  rendition.displaying = {
                    resolve: function () { window.fakeReleased = (window.fakeReleased || 0) + 1; resolve() }
                  }
                  window.fakeFail = function () { rendition.emit('displayerror', new Error(options.displayError)) }
                  if (!options.failTarget) setTimeout(window.fakeFail, 0)
                })
              }))
            }
          })
          return window.fakeBook = emitter({
            opened: options.openedHangs ? new Promise(function (resolve) { window.fakeHeldOpen = resolve }) : Promise.resolve(),
            ready: never,
            packaging: { navPath: options.navPath },
            path: { directory: options.packageDirectory },
            loaded: { navigation: options.navigation ? Promise.resolve({ toc: options.toc }) : never },
            spine: {
              length: options.spineLength,
              spineItems: [{ cfiBase: 'x'.repeat(options.cfiBase) }],
              get: function () { return null },
              hooks: { content: { register: function (hook) { window.fakeSpineHook = hook } } }
            },
            locations: {
              load: function (locations) { window.fakeLoadedLocations = locations },
              length: function () { return window.fakeLoadedLocations ? 1 : 0 },
              parse: function () { return ['c'.repeat(options.locationCharacters)] },
              generate: function () {
                window.fakeGenerated = true
                if (options.locationCharacters) window.fakeParsed = this.parse()
                return never
              },
              q: { stop: function () { window.fakeStopped = true } },
              save: function () { return '' }
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

    @Test func aBookOverTheLimitFailsTheTask() async {
        let task = await start(
            "absreader://book/x.epub", on: EPUBSchemeHandler(maxBookBytes: 5) { _ in Data(count: 6) })

        #expect((task.error as? URLError)?.code == .dataLengthExceedsMaximum)
        #expect(task.response == nil)
        #expect(task.body.isEmpty)
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

    /// A ZIP64 record whose length points back at itself, which would hang JSZip and the page, is
    /// refused before JSZip reads it.
    @Test(.timeLimit(.minutes(1))) func aLoopingZIP64RecordIsRefused() async throws {
        let page = try await ReaderPage(loadBook: { _ in TinyEPUB.loopingZIP64 })

        await #expect(throws: (any Error).self) { try await page.open("loop") }

        let error = try #require(page.last("error"))
        #expect(error["phase"] as? String == "open")
        #expect((error["message"] as? String)?.contains("not an archive the reader can open") == true)
    }

    /// Entries sharing one long local name are refused once the names they'd decode pass 8 MiB.
    @Test(.timeLimit(.minutes(1))) func namesSharedAcrossEntriesAreBounded() async throws {
        let page = try await ReaderPage(loadBook: { _ in TinyEPUB.sharingOneName(nameLength: 60000, count: 150) })

        await #expect(throws: (any Error).self) { try await page.open("names") }

        #expect((page.last("error")?["message"] as? String)?.contains("not an archive the reader can open") == true)
    }

    /// Clearing the reader's font leaves a section's own inline font alone, or puts it back.
    @Test(.timeLimit(.minutes(1))) func theBooksOwnFontSurvivesTheReaders() async throws {
        let page = try await ReaderPage(loadBook: { _ in TinyEPUB.data })
        try await page.fakeEPUBJS()
        try await page.open("tiny")
        _ = try await page.evaluate(
            """
            (function () {
              const section = new DOMParser().parseFromString(
                '<html xmlns="http://www.w3.org/1999/xhtml"><head/><body style="font-family: Georgia"/></html>',
                'application/xhtml+xml')
              window.fakeSpineHook(section)
              window.fakeContents.push({ content: section.querySelector('body') })
              return 1
            })()
            """)
        let body = "window.fakeContents[0].content.style"
        func apply(_ font: String?) async throws {
            let settings = font.map { #","fontFamily":"\#($0)""# } ?? ""
            try await page.controller.send(
                Data(#"{"type":"applySettings","settings":{"themeRules":{}\#(settings)}}"#.utf8))
        }

        try await apply(nil)
        #expect(try await page.evaluate("\(body).fontFamily") == #""Georgia""#)
        #expect(try await page.evaluate("window.fakeRemovals === undefined") == "true")
        try await apply("sans-serif")
        #expect(try await page.evaluate("\(body).fontFamily") == #""sans-serif""#)
        try await apply(nil)
        #expect(try await page.evaluate("\(body).fontFamily") == #""Georgia""#)
        #expect(try await page.evaluate("\(body).getPropertyPriority('font-family')") == #""""#)
    }

    /// The reader's spread wins over the one epub.js takes from the book's metadata as it starts.
    @Test(.timeLimit(.minutes(1))) func theReadersSpreadOutlastsTheBooks() async throws {
        let page = try await ReaderPage(loadBook: { _ in TinyEPUB.data })
        try await page.fakeEPUBJS()

        try await page.open("tiny", settings: ["spread": "none"])

        #expect(try await page.evaluate("window.fakeSpread") == #""none""#)
    }

    /// Cached locations that aren't an array of CFIs aren't loaded; they're generated afresh.
    @Test(.timeLimit(.minutes(1))) func unusableCachedLocationsAreRegenerated() async throws {
        let page = try await ReaderPage(loadBook: { _ in TinyEPUB.data })
        try await page.fakeEPUBJS()

        try await page.open("tiny", locations: "null")
        #expect(try await page.evaluate("window.fakeLoadedLocations === undefined") == "true")
        #expect(try await page.evaluate("window.fakeGenerated") == "true")

        try await page.open("tiny", locations: #"["epubcfi(/6/2)"]"#)
        #expect(try await page.evaluate("window.fakeLoadedLocations") == #"["epubcfi(/6/2)"]"#)
    }

    /// Replacing a book settles a display it left pending, and its pending display doesn't silence
    /// the new book's display errors.
    @Test(.timeLimit(.minutes(1))) func replacingABookSettlesItsPendingDisplay() async throws {
        let page = try await ReaderPage(loadBook: { _ in TinyEPUB.data })
        try await page.fakeEPUBJS(displayHangs: true)
        let first = Task { try await page.open("first") }
        while try await page.evaluate("window.fakeDisplays > 0") != "true" {
            try await Task.sleep(for: .milliseconds(20))
        }
        _ = try await page.evaluate("window.fakeOptions.displayHangs = false")

        try await page.open("second")
        await #expect(throws: (any Error).self) { try await first.value }
        #expect(page.last("error") == nil)

        _ = try await page.evaluate("window.fakeRendition.emit('displayerror', new Error('Bad link'))")
        let error = try await page.next("error")
        #expect(error["phase"] as? String == "display")
        #expect(error["message"] as? String == "Bad link")
    }

    /// Without a navigation document epub.js has no page list, which every relocation reads.
    @Test(.timeLimit(.minutes(1))) func aBookWithoutNavigationStillHasAPageList() async throws {
        let page = try await ReaderPage(loadBook: { _ in TinyEPUB.data })
        try await page.fakeEPUBJS(navigation: false)

        try await page.open("tiny")

        #expect(try await page.evaluate("window.fakeBook.pageList.pageFromCfi('epubcfi(/6/2)')") == "-1")
    }

    /// A book replaced before epub.js opens it (which a broken package never does) fails its `open`.
    @Test(.timeLimit(.minutes(1))) func replacingABookBeforeItOpensSettlesTheOldOpen() async throws {
        let page = try await ReaderPage(loadBook: { _ in TinyEPUB.data })
        try await page.fakeEPUBJS(openedHangs: true)
        let first = Task { try await page.open("first") }
        while try await page.evaluate("typeof window.fakeHeldOpen") != #""function""# {
            try await Task.sleep(for: .milliseconds(20))
        }
        _ = try await page.evaluate("window.fakeOptions.openedHangs = false")

        try await page.open("second")

        await #expect(throws: (any Error).self) { try await first.value }
        #expect(page.last("error") == nil)
    }

    /// A section that fails to display releases epub.js's queue, so `next` and `prev` still run,
    /// whether a command displayed it or epub.js did.
    @Test(.timeLimit(.minutes(1))) func aFailedDisplayReleasesEpubJSsQueue() async throws {
        let page = try await ReaderPage(loadBook: { _ in TinyEPUB.data })
        try await page.fakeEPUBJS(displayError: "No such section")

        await #expect(throws: (any Error).self) { try await page.open("tiny") }
        #expect(try await page.evaluate("window.fakeReleased") == "1")

        _ = try await page.evaluate("window.fakeRendition.emit('displayerror', new Error('Bad link'))")
        #expect(try await page.evaluate("window.fakeReleased") == "2")
    }

    /// The table of contents' links are relative to the package, as the spine and `relocated` are,
    /// not to the navigation document they're in.
    @Test(.timeLimit(.minutes(1))) func tableOfContentsLinksAreRelativeToThePackage() async throws {
        let page = try await ReaderPage(loadBook: { _ in TinyEPUB.data })
        let toc: [[String: Any]] = [
            ["id": "one", "label": "One", "href": "../text/c1.xhtml#p2", "subitems": [["href": "c%201.xhtml"]]],
            ["id": "away", "label": "Away", "href": "https://example.com/c1.xhtml"],
        ]
        try await page.fakeEPUBJS(toc: toc, navPath: "nav/toc.xhtml")

        try await page.open("tiny")

        let items = try #require(try await page.next("toc")["items"] as? [[String: Any]])
        #expect(items.map { $0["href"] as? String } == ["text/c1.xhtml#p2", "https://example.com/c1.xhtml"])
        let subitems = try #require(items.first?["subitems"] as? [[String: Any]])
        #expect(subitems.map { $0["href"] as? String } == ["nav/c 1.xhtml"])
    }

    /// A navigation document above the package's folder: its links stay relative to the package.
    @Test(.timeLimit(.minutes(1))) func tableOfContentsLinksAboveThePackageKeepTheirParent() async throws {
        let page = try await ReaderPage(loadBook: { _ in TinyEPUB.data })
        let toc: [[String: Any]] = [["id": "one", "label": "One", "href": "text/c1.xhtml#p2"]]
        try await page.fakeEPUBJS(toc: toc, navPath: "../nav.xhtml", packageDirectory: "/OEBPS/package/")

        try await page.open("tiny")

        let items = try #require(try await page.next("toc")["items"] as? [[String: Any]])
        #expect(items.map { $0["href"] as? String } == ["../text/c1.xhtml#p2"])
    }

    /// epub.js's `displayerror` doesn't say whose display failed, so a display queued behind one
    /// that fails still runs, rather than failing with it.
    @Test(.timeLimit(.minutes(1))) func aFailedDisplayDoesNotFailTheNextOne() async throws {
        let page = try await ReaderPage(loadBook: { _ in TinyEPUB.data })
        try await page.fakeEPUBJS(displayError: "No such section", failTarget: "bad.xhtml")
        try await page.open("tiny")

        let bad = Task { try await page.controller.send(Data(#"{"type":"display","target":"bad.xhtml"}"#.utf8)) }
        while try await page.evaluate("typeof window.fakeFail") != #""function""# {
            try await Task.sleep(for: .milliseconds(20))
        }
        let good = Task { try await page.controller.send(Data(#"{"type":"display","target":"good.xhtml"}"#.utf8)) }
        try await Task.sleep(for: .milliseconds(300))
        _ = try await page.evaluate("window.fakeFail()")

        await #expect(throws: (any Error).self) { try await bad.value }
        await #expect(throws: Never.self) { try await good.value }
    }

    /// The blob URLs epub.js makes for a book's assets, and the bridge's rewritten style sheets, are
    /// revoked when another book replaces it.
    @Test(.timeLimit(.minutes(1))) func aClosedBooksBlobsAreRevoked() async throws {
        let manifest =
            #"<item id="a" href="a.png" media-type="image/png"/>"#
            + #"<item id="css" href="style.css" media-type="text/css"/>"#
        let extra = [
            TinyEPUB.Entry(name: "OEBPS/a.png", body: Data(count: 16)),
            TinyEPUB.Entry(name: "OEBPS/style.css", body: Data("a.png".utf8)),
        ]
        let page = try await ReaderPage(loadBook: { id in
            guard id == "first" else { throw URLError(.fileDoesNotExist) }
            return TinyEPUB.data(extra: extra, manifest: manifest)
        })
        _ = try await page.controller.webView.evaluateJavaScript(
            """
            const ePub = window.ePub
            window.ePub = function (data, options) { return (window.testBook = ePub(data, options)) }
            const create = URL.createObjectURL
            const revoke = URL.revokeObjectURL
            window.testCreated = []
            window.testRevoked = []
            URL.createObjectURL = function (blob) { const url = create(blob); window.testCreated.push(url); return url }
            URL.revokeObjectURL = function (url) { window.testRevoked.push(url); revoke(url) }
            1
            """)
        let opening = Task { try await page.open("first") }
        defer { opening.cancel() }
        while try await page.evaluate("window.testBook !== undefined") != "true" {
            try await Task.sleep(for: .milliseconds(20))
        }
        _ = try await page.controller.webView.callAsyncJavaScript(
            "await window.testBook.opened", arguments: [:], in: nil, contentWorld: .page)
        #expect(try await page.evaluate("window.testCreated.length") == "3")

        await #expect(throws: (any Error).self) { try await page.open("second") }

        #expect(
            try await page.evaluate("window.testCreated.every((url) => window.testRevoked.includes(url))") == "true")
    }

    /// epub.js copies an asset out of the archive once per listing, all at once, so a book listing
    /// one twice is refused.
    @Test(.timeLimit(.minutes(1))) func anAssetListedTwiceIsRefused() async throws {
        let manifest =
            #"<item id="a" href="a.png" media-type="image/png"/>"#
            + #"<item id="b" href="./a.png" media-type="image/png"/>"#
        let png = TinyEPUB.Entry(name: "OEBPS/a.png", body: Data(count: 16))
        let page = try await ReaderPage(loadBook: { _ in TinyEPUB.data(extra: [png], manifest: manifest) })

        await #expect(throws: (any Error).self) { try await page.open("twice") }

        let error = try #require(page.last("error"))
        #expect(error["phase"] as? String == "open")
        #expect(error["message"] as? String == "The book lists a file more than once")
    }

    /// How the real epub.js, once the book opens, rewrites `text` as a style sheet and as a
    /// section, for a book listing the assets `listed` and containing only `present`, within a
    /// rewrite `budget` (characters) if given; then the style sheet a section linking to it gets.
    /// A missing style sheet reads as empty.
    private func rewritten(
        _ text: String, listed: [String], present: [String], budget: Int = 0
    ) async throws -> [String] {
        let manifest =
            listed.map { #"<item id="i\#($0)" href="\#($0)" media-type="image/png"/>"# }.joined()
            + #"<item id="css" href="style.css" media-type="text/css"/>"#
        let extra =
            present.map { TinyEPUB.Entry(name: "OEBPS/\($0)", body: Data(count: 16)) }
            + [TinyEPUB.Entry(name: "OEBPS/style.css", body: Data(text.utf8))]
        let page = try await ReaderPage(loadBook: { _ in TinyEPUB.data(extra: extra, manifest: manifest) })
        // Keeps the real book, and the blobs epub.js makes, where the test can read them.
        _ = try await page.controller.webView.evaluateJavaScript(
            """
            const ePub = window.ePub
            window.ePub = function (data, options) { return (window.testBook = ePub(data, options)) }
            const create = URL.createObjectURL
            window.testBlobs = {}
            URL.createObjectURL = function (blob) { const url = create(blob); window.testBlobs[url] = blob; return url }
            window.absReaderRewriteBudget = \(budget)
            1
            """)
        let opening = Task { try await page.open("assets") }
        defer { opening.cancel() }
        while try await page.evaluate("window.testBook !== undefined") != "true" {
            try await Task.sleep(for: .milliseconds(20))
        }

        let texts = try await page.controller.webView.callAsyncJavaScript(
            """
            await window.testBook.opened
            const resources = window.testBook.resources
            const css = resources.replacementUrls[resources.urls.indexOf('style.css')]
            const linked = resources.substitute('style.css', '/OEBPS/c1.xhtml')
            return [
              css ? await window.testBlobs[css].text() : '', resources.substitute(text, '/OEBPS/c1.xhtml'),
              window.testBlobs[linked] ? await window.testBlobs[linked].text() : linked
            ]
            """, arguments: ["text": text], contentWorld: .page)
        return try #require(texts as? [String])
    }

    /// Each asset's URL is swapped for its blob URL once, in style sheets and sections alike, not
    /// again inside the blob URLs the earlier swaps put in.
    @Test(.timeLimit(.minutes(1))) func assetURLsAreSubstitutedOnce() async throws {
        let names = ["a", "b", "c", "d"]
        let texts = try await rewritten("a b c d", listed: names, present: names)

        #expect(texts.map { $0.components(separatedBy: "blob:").count - 1 } == [4, 4, 4])
    }

    /// An asset missing from the archive stays unresolved without shifting the others onto the
    /// wrong blob URLs, as epub.js's own list of replacements does.
    @Test(.timeLimit(.minutes(1))) func aMissingAssetLeavesTheOthersMapped() async throws {
        let texts = try await rewritten("a.png b.png", listed: ["a.png", "b.png"], present: ["b.png"])

        let blob = try Regex("blob:[^ ]+")
        #expect(texts.map { $0.replacing(blob, with: "BLOB") } == ["a.png BLOB", "a.png BLOB", "a.png BLOB"])
    }

    /// A style sheet or section whose rewrite would grow past the budget is emptied (a style sheet,
    /// so sections linking to it get the empty one, not the original) or left as it was (a section).
    @Test(.timeLimit(.minutes(1))) func aRewriteOverTheBudgetIsSkipped() async throws {
        let text = Array(repeating: "a.png", count: 100).joined(separator: " ")
        let texts = try await rewritten(text, listed: ["a.png"], present: ["a.png"], budget: 1000)

        #expect(texts == ["", text, ""])
    }

    /// A relocation is posted whenever any of its fields changes, not only its start.
    @Test(.timeLimit(.minutes(1))) func aRelocationWithANewEndIsPosted() async throws {
        let page = try await ReaderPage(loadBook: { _ in TinyEPUB.data })
        try await page.fakeEPUBJS()
        try await page.open("tiny")

        for (end, atEnd) in [("e1", false), ("e2", true), ("e2", true)] {
            _ = try await page.evaluate(
                """
                window.fakeRendition.emit('relocated', {
                  start: { cfi: 's', href: 'c1.xhtml' }, end: { cfi: '\(end)', percentage: 0 }, atEnd: \(atEnd)
                })
                """)
        }

        let relocations = page.events.filter { $0["type"] as? String == "relocated" }
        #expect(relocations.map { $0["endCfi"] as? String } == ["e1", "e2"])
        #expect(relocations.map { $0["atEnd"] as? Bool } == [false, true])
    }

    /// Emits a relocation ending on page 1 of 2 in spine section `index`, and returns the progress
    /// the bridge posts for it.
    private func progress(on page: ReaderPage, endingInSection index: Int) async throws -> Double? {
        _ = try await page.evaluate(
            """
            window.fakeRendition.emit('relocated', {
              start: { cfi: 's', href: 'c1.xhtml', index: \(index) },
              end: { cfi: 'e', index: \(index), displayed: { page: 1, total: 2 }, percentage: 0 }
            })
            """)
        return page.last("relocated")?["progress"] as? Double
    }

    /// A spine past the limit gets no locations, and progress by section instead.
    @Test(.timeLimit(.minutes(1))) func aLongSpineGetsProgressBySection() async throws {
        let page = try await ReaderPage(loadBook: { _ in TinyEPUB.data })
        try await page.fakeEPUBJS(spineLength: 2001)

        try await page.open("tiny")

        #expect(try await page.evaluate("window.fakeGenerated === undefined") == "true")
        #expect(try await progress(on: page, endingInSection: 1000) == 0.5)
    }

    /// Locations still generating at the deadline stop, and progress goes by section instead.
    @Test(.timeLimit(.minutes(1))) func slowLocationsFallBackToProgressBySection() async throws {
        let page = try await ReaderPage(loadBook: { _ in TinyEPUB.data })
        try await page.fakeEPUBJS(spineLength: 4)
        _ = try await page.evaluate("window.absReaderLocationsTimeoutMs = 50")

        try await page.open("tiny")
        while try await page.evaluate("window.fakeStopped") != "true" {
            try await Task.sleep(for: .milliseconds(20))
        }

        #expect(try await progress(on: page, endingInSection: 1) == 0.375)
        #expect(page.last("locationsReady") == nil)
    }

    /// A spine item whose CFI base (with its id) is past the limit gets no locations: every
    /// location would repeat it.
    @Test(.timeLimit(.minutes(1))) func aLongCFIBaseGetsProgressBySection() async throws {
        let page = try await ReaderPage(loadBook: { _ in TinyEPUB.data })
        try await page.fakeEPUBJS(spineLength: 4, cfiBase: 513)

        try await page.open("tiny")

        #expect(try await page.evaluate("window.fakeGenerated === undefined") == "true")
        #expect(try await progress(on: page, endingInSection: 1) == 0.375)
    }

    /// Location text past the limit stops generation and is dropped; progress goes by section, and
    /// nothing is posted to cache.
    @Test(.timeLimit(.minutes(1))) func locationsPastTheOutputLimitFallBackToProgressBySection() async throws {
        let page = try await ReaderPage(loadBook: { _ in TinyEPUB.data })
        try await page.fakeEPUBJS(spineLength: 4, locationCharacters: 1001)
        _ = try await page.evaluate("window.absReaderLocationsMaxCharacters = 1000")

        try await page.open("tiny")

        #expect(try await page.evaluate("window.fakeStopped") == "true")
        #expect(try await page.evaluate("window.fakeParsed") == "[]")
        #expect(try await progress(on: page, endingInSection: 1) == 0.375)
        #expect(page.last("locationsReady") == nil)
    }

    /// Real epub.js builds a section's locations in one go, each repeating every ancestor's id. A
    /// chapter whose would pass the limit is skipped before that, and progress goes by section; one
    /// with an ordinary id still gets its locations.
    @Test(.timeLimit(.minutes(1)), arguments: [20_000, 8])
    func locationsRepeatingALongElementIDAreSkippedBeforeParsing(idLength: Int) async throws {
        let body =
            #"<div id="\#(String(repeating: "x", count: idLength))"><p>"#
            + String(repeating: "Lorem ipsum dolor sit amet. ", count: 100) + "</p></div>"
        let page = try await ReaderPage(loadBook: { _ in TinyEPUB.data(chapterBody: body) })
        _ = try await page.controller.webView.evaluateJavaScript(
            """
            window.absReaderLocationsMaxCharacters = 100000
            const ePub = window.ePub
            window.ePub = function (data, options) {
              const book = ePub(data, options)
              // Its queue waits for animation frames, which an off-screen page never gets.
              book.locations.q.tick = function (task) { setTimeout(task, 0) }
              const parse = book.locations.parse
              book.locations.parse = function () { window.testParsed = true; return parse.apply(this, arguments) }
              // epub.js can't lay pages out off screen, so a stand-in rendition displays at once.
              book.renderTo = function () {
                const nothing = function () {}
                return {
                  settings: {}, started: Promise.resolve(), on: nothing, off: nothing, spread: nothing,
                  themes: { register: nothing, select: nothing, fontSize: nothing, font: nothing },
                  getContents: function () { return [] },
                  display: function () { return Promise.resolve() },
                  currentLocation: function () {
                    return { start: { cfi: 's', index: 0 }, end: { cfi: 'e', index: 0, displayed: { page: 1, total: 2 } } }
                  }
                }
              }
              return book
            }
            1
            """)

        try await page.open("long-id")

        if idLength > 1000 {
            while page.last("relocated")?["progress"] as? Double != 0.5 {
                try await Task.sleep(for: .milliseconds(20))
            }
            #expect(try await page.evaluate("window.testParsed === undefined") == "true")
            #expect(page.last("locationsReady") == nil)
        } else {
            _ = try await page.next("locationsReady")
            #expect(try await page.evaluate("window.testParsed") == "true")
        }
    }

    /// A table of contents link to a chapter the package lists as `./c1.xhtml` keeps that href,
    /// which epub.js finds the section by.
    @Test(.timeLimit(.minutes(1))) func tableOfContentsLinksUseTheSpinesHref() async throws {
        let page = try await ReaderPage(loadBook: { _ in
            TinyEPUB.data(chapterHref: "./c1.xhtml", chapterLink: "./c1.xhtml#p2")
        })
        _ = try await page.controller.webView.evaluateJavaScript(
            """
            const ePub = window.ePub
            window.ePub = function (data, options) { return (window.testBook = ePub(data, options)) }
            1
            """)
        let opening = Task { try await page.open("dotted") }
        defer { opening.cancel() }

        let items = try #require(try await page.next("toc")["items"] as? [[String: Any]])
        let href = try #require(items.first?["href"] as? String)
        #expect(href == "./c1.xhtml#p2")
        #expect(try await page.evaluate("window.testBook.spine.get('\(href)') !== null") == "true")
    }

    /// A display epub.js starts itself (a link, say) that fails doesn't fail a display the bridge
    /// asked for after it; its failure is posted.
    @Test(.timeLimit(.minutes(1))) func epubJSsOwnDisplayFailsAlone() async throws {
        let page = try await ReaderPage(loadBook: { _ in TinyEPUB.data })
        try await page.fakeEPUBJS(displayError: "Bad link", failTarget: "link.xhtml")
        try await page.open("tiny")

        _ = try await page.evaluate("(window.fakeRendition.display('link.xhtml'), 1)")
        while try await page.evaluate("typeof window.fakeFail") != #""function""# {
            try await Task.sleep(for: .milliseconds(20))
        }
        let good = Task { try await page.controller.send(Data(#"{"type":"display","target":"good.xhtml"}"#.utf8)) }
        try await Task.sleep(for: .milliseconds(300))
        _ = try await page.evaluate("window.fakeFail()")

        await #expect(throws: Never.self) { try await good.value }
        let error = try await page.next("error")
        #expect(error["phase"] as? String == "display")
        #expect(error["message"] as? String == "Bad link")
    }

    @Test func aCommandMustBeAJSONObject() async {
        let controller = EPUBReaderController(loadBook: { _ in Data() })

        await #expect(throws: EPUBReaderController.CommandError.notAnObject) {
            try await controller.send(Data("[]".utf8))
        }
    }
}
