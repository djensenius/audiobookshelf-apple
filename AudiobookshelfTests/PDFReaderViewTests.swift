import CoreGraphics
import Foundation
import PDFKit
import Testing

@testable import Audiobookshelf

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
