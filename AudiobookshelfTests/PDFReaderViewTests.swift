import CoreGraphics
import Foundation
import PDFKit
import SwiftUI
import Testing

@testable import Audiobookshelf

#if os(macOS)
    import AppKit
#endif

@MainActor
@Suite struct PDFReaderViewTests {
    @Test func openingOnALaterPageReportsNothing() throws {
        let (view, coordinator, reported) = observedView()
        let document = try #require(PDFDocument(data: pdfData(pages: 5)))

        coordinator.withoutReporting(view) {
            // Assigning the document selects page 1 before the reader reaches its opening page.
            view.document = document
            if let page = document.page(oneBased: 4) { view.go(to: page) }
        }
        #expect(reported.pages.isEmpty)
        #expect(coordinator.lastPage == 4)

        // The opening page isn't reported when PDFKit announces it again; a turn is.
        if let page = document.page(oneBased: 4) { view.go(to: page) }
        if let page = document.page(oneBased: 5) { view.go(to: page) }
        #expect(reported.pages == [5])
    }

    @Test func eachTurnAfterOpeningIsReportedOnce() throws {
        let (view, coordinator, reported) = observedView()
        let document = try #require(PDFDocument(data: pdfData(pages: 3)))
        coordinator.withoutReporting(view) { view.document = document }

        for number in [2, 2, 3] {
            if let page = document.page(oneBased: number) { view.go(to: page) }
        }
        #expect(reported.pages == [2, 3])
        #expect(coordinator.lastPage == 3)
    }

    #if os(macOS)
        /// Through SwiftUI's own make and update calls: opening on a later page, toggling the
        /// spread both ways and replacing the document report nothing and keep the right page.
        @Test func hostedReaderReportsOnlyTurns() throws {
            let book = try #require(PDFDocument(data: pdfData(pages: 8)))
            let reported = Reported()
            let host = HostedReader(document: book, initialPage: 4, reported: reported)

            #expect(host.shownPage == 4)
            #expect(reported.pages.isEmpty)

            host.goTo(5)
            #expect(reported.pages == [5])

            host.update(isSpread: true)
            #expect(host.view?.displayMode == .twoUp)
            #expect(host.shownPage == 5)
            host.update(isSpread: false)
            #expect(host.view?.displayMode == .singlePage)
            #expect(host.shownPage == 5)
            #expect(reported.pages == [5])

            let other = try #require(PDFDocument(data: pdfData(pages: 6)))
            host.update(document: other, initialPage: 3)
            #expect(host.view?.document === other)
            #expect(host.shownPage == 3)
            #expect(reported.pages == [5])

            host.goTo(2)
            #expect(reported.pages == [5, 2])
        }
    #endif

    private func observedView() -> (PDFView, PDFReaderView.Coordinator, Reported) {
        let view = PDFView(frame: CGRect(x: 0, y: 0, width: 400, height: 600))
        let coordinator = PDFReaderView.Coordinator()
        let reported = Reported()
        coordinator.onPageChange = { reported.pages.append($0) }
        coordinator.observe(view)
        return (view, coordinator, reported)
    }
}

@MainActor
private final class Reported {
    var pages: [Int] = []
}

/// A PDF drawn in code, so no binary fixture is committed.
private func pdfData(pages: Int) -> Data {
    let data = NSMutableData()
    var box = CGRect(x: 0, y: 0, width: 200, height: 300)
    guard let consumer = CGDataConsumer(data: data as CFMutableData),
        let context = CGContext(consumer: consumer, mediaBox: &box, nil)
    else { return Data() }
    for _ in 0..<pages {
        context.beginPDFPage(nil)
        context.fill(box.insetBy(dx: 20, dy: 20))
        context.endPDFPage()
    }
    context.closePDF()
    return data as Data
}

#if os(macOS)
    /// A `PDFReaderView` in an `NSHostingView`, so SwiftUI drives `makeNSView` and `updateNSView`.
    @MainActor
    private final class HostedReader {
        private let hosting: NSHostingView<PDFReaderView>
        private var reader: PDFReaderView

        init(document: PDFDocument, initialPage: Int, reported: Reported) {
            reader = PDFReaderView(
                document: document, initialPage: initialPage, onPageChange: { reported.pages.append($0) })
            hosting = NSHostingView(rootView: reader)
            hosting.frame = CGRect(x: 0, y: 0, width: 600, height: 400)
            hosting.layoutSubtreeIfNeeded()
        }

        var view: ReaderPDFView? { Self.find(in: hosting) }

        var shownPage: Int? {
            view.flatMap { view in view.currentPage.flatMap { view.document?.oneBasedPageNumber(of: $0) } }
        }

        func goTo(_ number: Int) {
            if let view, let page = view.document?.page(oneBased: number) { view.go(to: page) }
        }

        func update(isSpread: Bool) {
            reader.isSpread = isSpread
            render()
        }

        func update(document: PDFDocument, initialPage: Int) {
            reader = PDFReaderView(
                document: document, initialPage: initialPage, isSpread: reader.isSpread,
                background: reader.background, onPageChange: reader.onPageChange)
            render()
        }

        private func render() {
            hosting.rootView = reader
            hosting.layoutSubtreeIfNeeded()
        }

        private static func find(in view: NSView) -> ReaderPDFView? {
            if let reader = view as? ReaderPDFView { return reader }
            return view.subviews.lazy.compactMap(find(in:)).first
        }
    }
#endif
