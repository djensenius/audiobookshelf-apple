import ABSAppModel
import ABSCore
import Foundation
import PDFKit
import SwiftUI
import Testing

@testable import Audiobookshelf

#if os(macOS)
    import AppKit

    /// Writes a three-page PDF.
    private struct PDFFetcher: EbookFileFetching {
        func downloadEbook(itemID: String, fileIno: String?, to destination: URL, maxBytes: Int) async throws {
            try pdfData(pages: 3).write(to: destination)
        }
    }

    @MainActor
    @Suite struct ReaderContentTests {
        /// The PDF opens once: showing the loaded document in place of the loading view doesn't
        /// load it again, which would replace it and send the reader back to its opening page.
        @Test func thePDFLoadsOnceAsItAppears() async throws {
            let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            let request = EbookFileRequest(
                connectionID: UUID(), itemID: "book", fileIno: "1", fileExtension: "pdf", version: "1")
            let model = ReaderContainerModel(
                request: request, kind: .pdf, loader: EbookFileLoader(directory: directory, fetcher: PDFFetcher()),
                progress: nil, serverProgress: nil)
            await model.load()
            let hosting = NSHostingView(rootView: ReaderContent(model: model, title: "Book", serverURL: nil, close: {}))
            let window = NSWindow(
                contentRect: CGRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered,
                defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = hosting
            defer { window.close() }

            let first = try #require(try await Self.document(in: hosting) { $0 != nil })
            // Long enough for a second load to finish and replace the document.
            let later = try await Self.document(in: hosting) { $0 != nil && $0 !== first }
            #expect(later === first)
        }

        /// Lays the view out until `done` holds for its PDF view's document, or about a second passes.
        private static func document(
            in hosting: NSView, until done: (PDFDocument?) -> Bool
        ) async throws -> PDFDocument? {
            for _ in 0..<100 where !done(pdfView(in: hosting)?.document) {
                hosting.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(10))
            }
            return pdfView(in: hosting)?.document
        }

        private static func pdfView(in view: NSView) -> PDFView? {
            if let pdfView = view as? PDFView { return pdfView }
            return view.subviews.lazy.compactMap(pdfView(in:)).first
        }
    }
#endif
