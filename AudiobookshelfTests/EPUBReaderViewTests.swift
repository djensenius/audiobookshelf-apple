import ABSAppModel
import ABSCore
import Foundation
import SwiftUI
import Testing
import WebKit

@testable import Audiobookshelf

#if os(macOS)
    import AppKit

    /// Fetches nothing: the session's book is never read in these tests.
    private struct NoEbookFetcher: EbookFileFetching {
        func downloadEbook(itemID: String, fileIno: String?, to destination: URL, maxBytes: Int) async throws {
            throw URLError(.fileDoesNotExist)
        }
    }

    @MainActor
    @Suite struct EPUBReaderViewTests {
        /// The reader creates its session as it appears, through SwiftUI's own lifecycle, so the
        /// book's web view is shown rather than nothing.
        @Test func appearingShowsTheBooksWebView() async throws {
            let request = EbookFileRequest(
                connectionID: UUID(), itemID: "book", fileIno: "1", fileExtension: "epub", version: "1")
            let loader = EbookFileLoader(
                directory: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString),
                fetcher: NoEbookFetcher())
            let model = ReaderContainerModel(
                request: request, kind: .epub, loader: loader, progress: nil, serverProgress: nil)
            let payload = ReaderSettingsPayload(settings: ReaderSettings(), resolvedAppearance: .light, layout: .single)
            // In a stack, as the reader container shows it, which lays out the reader's children
            // rather than the reader as one view.
            let hosting = NSHostingView(
                rootView: ZStack {
                    Color.black
                    EPUBReaderView(model: model, fileURL: URL(filePath: "/nonexistent/book.epub"), payload: payload)
                })
            let window = NSWindow(
                contentRect: CGRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered,
                defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = hosting
            defer { window.close() }

            for _ in 0..<200 where Self.webView(in: hosting) == nil {
                hosting.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(Self.webView(in: hosting) != nil)
        }

        private static func webView(in view: NSView) -> WKWebView? {
            if let webView = view as? WKWebView { return webView }
            return view.subviews.lazy.compactMap(webView(in:)).first
        }
    }
#endif
