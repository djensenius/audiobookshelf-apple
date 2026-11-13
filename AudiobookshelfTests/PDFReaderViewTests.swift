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

    @Test func aRequestedPageIsReportedOnceItSettles() async throws {
        let (view, coordinator, reported) = observedView()
        let document = try #require(PDFDocument(data: pdfData(pages: 6)))
        coordinator.withoutReporting(view) { view.document = document }

        coordinator.follow(PDFPageRequest(page: 5), in: view)
        #expect(shownPage(of: view) == 5)
        // Not while SwiftUI is still updating the view, nor the pages passed through.
        #expect(reported.pages.isEmpty)
        await settle(until: { !reported.pages.isEmpty })
        #expect(reported.pages == [5])
        #expect(coordinator.lastPage == 5)

        // Asking for the page already shown reports nothing more.
        coordinator.follow(PDFPageRequest(page: 5), in: view)
        await settle()
        #expect(reported.pages == [5])
    }

    @Test func aTurnBeforeARequestSettlesSupersedesIt() async throws {
        let (view, coordinator, reported) = observedView()
        let document = try #require(PDFDocument(data: pdfData(pages: 6)))
        coordinator.withoutReporting(view) { view.document = document }

        coordinator.follow(PDFPageRequest(page: 5), in: view)
        if let page = document.page(oneBased: 3) { view.go(to: page) }
        await settle()
        #expect(reported.pages == [3])
    }

    @Test func aRequestIsDroppedWhenTheDocumentChanges() async throws {
        let (view, coordinator, reported) = observedView()
        let first = try #require(PDFDocument(data: pdfData(pages: 6)))
        coordinator.withoutReporting(view) { view.document = first }

        coordinator.follow(PDFPageRequest(page: 5), in: view)
        let second = try #require(PDFDocument(data: pdfData(pages: 6)))
        coordinator.withoutReporting(view) { view.document = second }
        await settle()
        #expect(reported.pages.isEmpty)
    }

    @Test func theLinkJoinsThumbnailsToTheReaderWhicheverComesFirst() {
        let reader = PDFView()

        let readerFirst = PDFReaderLink()
        let laterThumbnails = PDFThumbnailView()
        readerFirst.pdfView = reader
        readerFirst.thumbnailView = laterThumbnails
        #expect(laterThumbnails.pdfView === reader)

        let thumbnailsFirst = PDFReaderLink()
        let earlierThumbnails = PDFThumbnailView()
        thumbnailsFirst.thumbnailView = earlierThumbnails
        thumbnailsFirst.pdfView = reader
        #expect(earlierThumbnails.pdfView === reader)
    }

    @Test(arguments: [
        ("7", 7), (" 12\n", 12), ("40", 40), ("0", 1), ("007", 7), ("41", 40), ("120", 40),
        ("99999999999999999999999999", 40), ("٣٤", 34),
    ])
    func aTypedPageIsClampedToTheDocument(text: String, page: Int) {
        #expect(PDFPageNavigator.page(from: text, pageCount: 40) == page)
    }

    @Test(arguments: ["", "  ", "abc", "12abc", "1 2", "-3", "+4", "1,234", "12.5", "Ⅻ", "½"])
    func anythingButDigitsIsNoPage(text: String) {
        #expect(PDFPageNavigator.page(from: text, pageCount: 40) == nil)
    }

    @Test func aDocumentWithoutPagesHasNoPageToGoTo() {
        #expect(PDFPageNavigator.page(from: "1", pageCount: 0) == nil)
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

        /// A request is followed in the update that brings it and not in the ones after it, which
        /// would turn the reader back; a new request for the same page is.
        @Test func hostedReaderFollowsEachRequestOnce() async throws {
            let book = try #require(PDFDocument(data: pdfData(pages: 8)))
            let reported = Reported()
            let link = PDFReaderLink()
            let host = HostedReader(document: book, initialPage: 2, link: link, reported: reported)
            #expect(link.pdfView === host.view)

            host.update(requestedPage: PDFPageRequest(page: 6))
            #expect(host.shownPage == 6)
            await settle(until: { !reported.pages.isEmpty })
            #expect(reported.pages == [6])

            host.goTo(5)
            host.update(isSpread: true)
            host.update(isSpread: false)
            #expect(host.shownPage == 5)

            host.update(requestedPage: PDFPageRequest(page: 6))
            #expect(host.shownPage == 6)
            await settle(until: { reported.pages.count > 2 })
            #expect(reported.pages == [6, 5, 6])
        }

        /// A request the reader is made with is stale: it opens on its initial page.
        @Test func hostedReaderIgnoresARequestFromBeforeItWasMade() async throws {
            let book = try #require(PDFDocument(data: pdfData(pages: 8)))
            let reported = Reported()
            let host = HostedReader(
                document: book, initialPage: 2, requestedPage: PDFPageRequest(page: 6), reported: reported)

            #expect(host.shownPage == 2)
            await settle()
            #expect(reported.pages.isEmpty)
        }
    #endif

    private func shownPage(of view: PDFView) -> Int? {
        view.currentPage.flatMap { view.document?.oneBasedPageNumber(of: $0) }
    }

    /// Lets tasks the reader started run: until `condition` holds, or long enough to see one wouldn't.
    private func settle(until condition: () -> Bool = { false }) async {
        for _ in 0..<100 where !condition() {
            await Task.yield()
        }
    }

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

        init(
            document: PDFDocument, initialPage: Int, requestedPage: PDFPageRequest? = nil,
            link: PDFReaderLink? = nil, reported: Reported
        ) {
            reader = PDFReaderView(
                document: document, initialPage: initialPage, requestedPage: requestedPage, link: link,
                onPageChange: { reported.pages.append($0) })
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

        func update(requestedPage: PDFPageRequest) {
            reader.requestedPage = requestedPage
            render()
        }

        func update(document: PDFDocument, initialPage: Int) {
            reader = PDFReaderView(
                document: document, initialPage: initialPage, isSpread: reader.isSpread,
                background: reader.background, requestedPage: reader.requestedPage, link: reader.link,
                onPageChange: reader.onPageChange)
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
