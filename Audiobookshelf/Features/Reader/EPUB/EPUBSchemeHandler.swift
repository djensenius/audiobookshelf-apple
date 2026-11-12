import Foundation
import WebKit

/// Serves the EPUB reader's `absreader://` URLs (ADR 0008, the EPUB bridge contract).
///
/// - `absreader://app/<file>`: the reader page and its scripts, from the bundle's `Web` folder.
///   Only those four files are served.
/// - `absreader://book/<id>.epub`: the book's bytes, from the injected loader, so tokens and
///   server URLs never reach JavaScript.
///
/// Anything else is a 404. A task WebKit stops gets nothing more.
@MainActor
final class EPUBSchemeHandler: NSObject, WKURLSchemeHandler {
    nonisolated static let scheme = "absreader"
    /// The reader page's URL; the web view loads it.
    nonisolated static let readerURL = URL(string: "\(scheme)://app/reader.html")!

    /// Fetches a book's bytes by its opaque id (the `<id>` in `absreader://book/<id>.epub`).
    typealias BookLoader = @Sendable (String) async throws -> Data

    /// The files under `absreader://app/`, with their MIME types.
    nonisolated static let appFiles: [String: String] = [
        "reader.html": "text/html; charset=utf-8",
        "reader.js": "text/javascript; charset=utf-8",
        "epub.min.js": "text/javascript; charset=utf-8",
        "jszip.min.js": "text/javascript; charset=utf-8",
    ]

    private let resourceURL: (String) -> URL?
    private let loadBook: BookLoader
    /// Book loads in flight, by task. `webView(_:stop:)` removes its entry, so a load finishing
    /// after that delivers nothing (WebKit raises on a stopped task).
    private var loads: [ObjectIdentifier: Task<Void, Never>] = [:]

    /// - Parameters:
    ///   - resourceURL: The bundled file for an app file name; by default the app bundle's.
    ///   - loadBook: Fetches a book's bytes.
    init(resourceURL: @escaping (String) -> URL? = EPUBSchemeHandler.bundledFile, loadBook: @escaping BookLoader) {
        self.resourceURL = resourceURL
        self.loadBook = loadBook
    }

    /// The bundled reader file: the synchronized `Web` folder's files are copied to the bundle's
    /// resources.
    nonisolated static func bundledFile(_ name: String) -> URL? {
        Bundle.main.url(forResource: name, withExtension: nil)
    }

    /// The book id in `absreader://book/<id>.epub`, or `nil` for any other URL.
    nonisolated static func bookID(in url: URL) -> String? {
        guard url.scheme == scheme, url.host() == "book" else { return nil }
        let path = url.path(percentEncoded: false)
        guard path.hasPrefix("/"), path.hasSuffix(".epub") else { return nil }
        let id = String(path.dropFirst().dropLast(".epub".count))
        return id.isEmpty || id.contains("/") ? nil : id
    }

    /// The app file name in `absreader://app/<file>`, if it's one that is served.
    nonisolated static func appFile(in url: URL) -> String? {
        guard url.scheme == scheme, url.host() == "app" else { return nil }
        let name = String(url.path(percentEncoded: false).dropFirst())
        return appFiles[name] == nil ? nil : name
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url else {
            return Self.respond(urlSchemeTask, status: 404, url: Self.readerURL)
        }
        if let name = Self.appFile(in: url), let mimeType = Self.appFiles[name],
            let file = resourceURL(name), let data = try? Data(contentsOf: file)
        {
            return Self.respond(urlSchemeTask, status: 200, url: url, data: data, mimeType: mimeType)
        }
        guard let id = Self.bookID(in: url) else { return Self.respond(urlSchemeTask, status: 404, url: url) }

        let key = ObjectIdentifier(urlSchemeTask)
        let loadBook = self.loadBook
        loads[key] = Task { [weak self] in
            let result: Result<Data, any Error>
            do {
                result = .success(try await loadBook(id))
            } catch {
                result = .failure(error)
            }
            // Stopped (or the handler is gone): WebKit must not hear from this task again.
            guard let self, loads.removeValue(forKey: key) != nil, !Task.isCancelled else { return }
            switch result {
            case .success(let data):
                Self.respond(
                    urlSchemeTask, status: 200, url: url, data: data, mimeType: "application/epub+zip",
                    // The page (absreader://app) reads the book (absreader://book) cross-origin.
                    headers: ["Access-Control-Allow-Origin": "\(Self.scheme)://app"])
            case .failure(let error):
                urlSchemeTask.didFailWithError(error)
            }
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {
        loads.removeValue(forKey: ObjectIdentifier(urlSchemeTask))?.cancel()
    }

    private static func respond(
        _ task: any WKURLSchemeTask, status: Int, url: URL, data: Data = Data(), mimeType: String = "text/plain",
        headers: [String: String] = [:]
    ) {
        var fields = headers
        fields["Content-Type"] = mimeType
        fields["Content-Length"] = String(data.count)
        fields["Cache-Control"] = "no-store"
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: fields)
        task.didReceive(
            response
                ?? URLResponse(url: url, mimeType: mimeType, expectedContentLength: data.count, textEncodingName: nil))
        if !data.isEmpty { task.didReceive(data) }
        task.didFinish()
    }
}
