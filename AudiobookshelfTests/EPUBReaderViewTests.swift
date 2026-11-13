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

    /// Writes a placeholder book, so the model has a file to show.
    private struct PlaceholderEbookFetcher: EbookFileFetching {
        func downloadEbook(itemID: String, fileIno: String?, to destination: URL, maxBytes: Int) async throws {
            try Data("not really a book".utf8).write(to: destination)
        }
    }

    @MainActor @Observable
    private final class ModelBox {
        var model: ReaderContainerModel
        init(_ model: ReaderContainerModel) { self.model = model }
    }

    @MainActor @Observable
    private final class ShownBox {
        var isShown = true
    }

    /// `content` until `shown` turns off.
    private struct Dismissable<Content: View>: View {
        let shown: ShownBox
        @ViewBuilder let content: () -> Content
        var body: some View {
            ZStack {
                Color.black
                if shown.isShown { content() }
            }
        }
    }

    private struct SwappableReader: View {
        let box: ModelBox
        var body: some View {
            ReaderContent(model: box.model, title: "Book", serverURL: nil, close: {})
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

        /// A replacement model (the account's client changed) gets a new reader session, rather than
        /// the retired model's, even when it's loaded before the container shows it.
        @Test func replacingTheModelStartsANewSession() async throws {
            let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            func loadedModel() async -> ReaderContainerModel {
                let request = EbookFileRequest(
                    connectionID: UUID(), itemID: "book", fileIno: "1", fileExtension: "epub", version: "1")
                let loader = EbookFileLoader(directory: directory, fetcher: PlaceholderEbookFetcher())
                let model = ReaderContainerModel(
                    request: request, kind: .epub, loader: loader, progress: nil, serverProgress: nil)
                await model.load()
                return model
            }
            let box = ModelBox(await loadedModel())
            let hosting = NSHostingView(rootView: SwappableReader(box: box))
            let window = NSWindow(
                contentRect: CGRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered,
                defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = hosting
            defer { window.close() }

            let first = try await Self.waitForWebView(in: hosting) { $0 != nil }
            try #require(first != nil)
            box.model = await loadedModel()
            let second = try await Self.waitForWebView(in: hosting) { $0 != nil && $0 !== first }
            #expect(second != nil)
            #expect(second !== first)
        }

        /// A reader that goes away (dismissed, or replaced on an account switch) closes its page,
        /// so a command the page could never finish off screen doesn't keep it alive.
        @Test func goingAwayClosesThePage() async throws {
            let request = EbookFileRequest(
                connectionID: UUID(), itemID: "book", fileIno: "1", fileExtension: "epub", version: "1")
            let loader = EbookFileLoader(
                directory: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString),
                fetcher: NoEbookFetcher())
            let model = ReaderContainerModel(
                request: request, kind: .epub, loader: loader, progress: nil, serverProgress: nil)
            let payload = ReaderSettingsPayload(settings: ReaderSettings(), resolvedAppearance: .light, layout: .single)
            let shown = ShownBox()
            let hosting = NSHostingView(
                rootView: Dismissable(shown: shown) {
                    EPUBReaderView(model: model, fileURL: URL(filePath: "/nonexistent/book.epub"), payload: payload)
                })
            let window = NSWindow(
                contentRect: CGRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered,
                defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = hosting
            defer { window.close() }

            let webView = try #require(try await Self.waitForWebView(in: hosting) { $0 != nil })
            #expect(webView.url == EPUBSchemeHandler.readerURL)
            shown.isShown = false
            for _ in 0..<200 where webView.url?.absoluteString != "about:blank" {
                hosting.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(webView.url?.absoluteString == "about:blank")
        }

        /// Lays the view out until `done` holds for its web view, or about two seconds pass.
        private static func waitForWebView(
            in hosting: NSView, until done: (WKWebView?) -> Bool
        ) async throws -> WKWebView? {
            for _ in 0..<200 where !done(webView(in: hosting)) {
                hosting.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(10))
            }
            return webView(in: hosting)
        }

        private static func webView(in view: NSView) -> WKWebView? {
            if let webView = view as? WKWebView { return webView }
            return view.subviews.lazy.compactMap(webView(in:)).first
        }
    }
#endif
