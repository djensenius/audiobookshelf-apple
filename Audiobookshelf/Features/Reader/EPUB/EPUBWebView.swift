import Foundation
import SwiftUI
import WebKit

/// Owns the reader's web view: the `absreader` scheme handler, the `absReader` message handler, and
/// a non-persistent data store, with the reader page loaded. Commands go in through ``send(_:)``;
/// events come out through ``onEvent`` as undecoded JSON.
@MainActor
final class EPUBReaderController {
    enum CommandError: Error, Equatable {
        /// The command isn't a JSON object.
        case notAnObject
        /// The reader was closed (``close()``).
        case closed
    }

    let webView: WKWebView
    /// Each event the page posts, as JSON `Data` (see the EPUB bridge contract).
    var onEvent: (Data) -> Void {
        get { messages.onEvent }
        set { messages.onEvent = newValue }
    }

    private let messages = EPUBMessageHandler()
    private let navigation = ReaderNavigationPolicy()
    private(set) var isClosed = false
    /// The commands the page is still running, failed by ``close()``.
    private var pending: [UUID: CheckedContinuation<Void, any Error>] = [:]

    /// - Parameter loadBook: Fetches a book's bytes for `absreader://book/<id>.epub`.
    init(
        resourceURL: @escaping (String) -> URL? = EPUBSchemeHandler.bundledFile,
        loadBook: @escaping EPUBSchemeHandler.BookLoader
    ) {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.setURLSchemeHandler(
            EPUBSchemeHandler(resourceURL: resourceURL, loadBook: loadBook), forURLScheme: EPUBSchemeHandler.scheme)
        messages.install(in: configuration.userContentController)
        webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = navigation
        #if DEBUG
            webView.isInspectable = true
        #endif
        #if os(iOS)
            webView.isOpaque = false
            webView.backgroundColor = .clear
            // epub.js pages inside its own container; the page itself never scrolls.
            webView.scrollView.bounces = false
            webView.scrollView.contentInsetAdjustmentBehavior = .never
        #endif
        webView.load(URLRequest(url: EPUBSchemeHandler.readerURL))
    }

    /// Runs one command (a JSON object, see the EPUB bridge contract) through
    /// `window.absReader.handle`, returning once the page has finished it. Throws when the page
    /// rejects it, for example a command sent before the `ready` event.
    func send(_ commandJSON: Data) async throws {
        guard !isClosed else { throw CommandError.closed }
        guard let command = try JSONSerialization.jsonObject(with: commandJSON) as? [String: Any] else {
            throw CommandError.notAnObject
        }
        let id = UUID()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            pending[id] = continuation
            // The callback doesn't capture the web view: a command the page never finishes leaves
            // nothing of the reader's alive once ``close()`` has failed it.
            webView.callAsyncJavaScript(
                "return await window.absReader.handle(command)", arguments: ["command": command], in: nil,
                in: .page
            ) { [weak self] result in
                MainActor.assumeIsolated {
                    guard let continuation = self?.pending.removeValue(forKey: id) else { return }
                    continuation.resume(with: result.map { _ in })
                }
            }
        }
    }

    /// Ends the reader page, for a reader that's gone: the commands it was still running fail with
    /// ``CommandError/closed``, it stops posting events, and a blank page replaces it, which stops
    /// epub.js. Off screen, the page gets no animation frames, so an `open` sent before the reader
    /// went away would otherwise never finish (WebKit doesn't fail it when the page goes), and the
    /// task awaiting it would keep the web view alive.
    func close() {
        guard !isClosed else { return }
        isClosed = true
        let stranded = pending.values
        pending = [:]
        for continuation in stranded { continuation.resume(throwing: CommandError.closed) }
        webView.configuration.userContentController.removeScriptMessageHandler(forName: EPUBMessageHandler.name)
        webView.stopLoading()
        navigation.isClosed = true
        webView.loadHTMLString("", baseURL: nil)
    }

    /// Whether the web view may load `url`: the main frame only the reader page; frames (epub.js's
    /// sections) only the reader's own scheme, `about:` and `blob:`.
    nonisolated static func allowsNavigation(to url: URL?, isMainFrame: Bool) -> Bool {
        guard let url else { return false }
        if isMainFrame { return url == EPUBSchemeHandler.readerURL }
        return ["about", "blob", EPUBSchemeHandler.scheme].contains(url.scheme ?? "")
    }
}

/// Keeps the web view on the reader page: the page itself and the frames epub.js makes for the
/// book's sections load; links out of the book don't navigate the reader away.
@MainActor
private final class ReaderNavigationPolicy: NSObject, WKNavigationDelegate {
    /// Once the reader is closed, only the blank page that replaces it loads.
    var isClosed = false

    func webView(
        _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction
    ) async -> WKNavigationActionPolicy {
        if isClosed {
            return navigationAction.targetFrame?.isMainFrame == true
                && navigationAction.request.url?.absoluteString == "about:blank" ? .allow : .cancel
        }
        return EPUBReaderController.allowsNavigation(
            to: navigationAction.request.url, isMainFrame: navigationAction.targetFrame?.isMainFrame ?? false)
            ? .allow : .cancel
    }
}

/// The reader's web view in SwiftUI. The controller owns the web view, so it survives view updates.
struct EPUBWebView {
    let controller: EPUBReaderController
}

#if os(iOS)
    extension EPUBWebView: UIViewRepresentable {
        func makeUIView(context: Context) -> WKWebView { controller.webView }
        func updateUIView(_ uiView: WKWebView, context: Context) {}
    }
#elseif os(macOS)
    extension EPUBWebView: NSViewRepresentable {
        func makeNSView(context: Context) -> WKWebView { controller.webView }
        func updateNSView(_ nsView: WKWebView, context: Context) {}
    }
#endif

#Preview("Reader page, no book") {
    // No EPUB fixture ships with the app: this shows the reader page loading, ready for `open`.
    EPUBWebView(controller: EPUBReaderController(loadBook: { _ in throw URLError(.fileDoesNotExist) }))
}
