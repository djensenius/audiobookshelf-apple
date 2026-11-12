import ABSAppModel
import CoreText
import PDFKit
import SwiftUI

#if os(macOS)
    import AppKit

    private typealias PlatformColor = NSColor
#else
    import UIKit

    private typealias PlatformColor = UIColor
#endif

/// The page background behind a PDF, from the reader theme (ADR 0008, decision 6: PDF only
/// changes the chrome and the background). The colours are the legacy reader's.
enum PDFReaderBackground: Sendable, Hashable, CaseIterable {
    case light
    case dark
    case black
    case sepia

    fileprivate var color: PlatformColor {
        switch self {
        case .light: PlatformColor(red: 1, green: 1, blue: 1, alpha: 1)
        case .dark: PlatformColor(red: 35 / 255, green: 35 / 255, blue: 35 / 255, alpha: 1)
        case .black: PlatformColor(red: 0, green: 0, blue: 0, alpha: 1)
        case .sepia: PlatformColor(red: 244 / 255, green: 236 / 255, blue: 216 / 255, alpha: 1)
        }
    }
}

/// A PDFKit reader (ADR 0008, decision 2). It shows `document` from `initialPage`, one page or
/// a two-page book spread, and reports each page the reader turns to.
///
/// Pages are 1-based, the form `ebookLocation` stores. The initial page isn't reported, so
/// opening a book doesn't count as reading it; nor is a page reported twice in a row, nor one
/// PDFKit passes through while a document or layout is being set.
struct PDFReaderView {
    let document: PDFDocument
    /// The 1-based page to open on, clamped to the document. Read when `document` changes.
    var initialPage = 1
    /// Two pages side by side, as a book (``ReaderSpreadPolicy``). Otherwise one page.
    var isSpread = false
    var background = PDFReaderBackground.light
    /// The 1-based page the reader turned to.
    var onPageChange: @MainActor (Int) -> Void = { _ in }

    /// Observes `PDFViewPageChanged`. It holds no reference to the view, and the notification
    /// center doesn't retain a selector-based observer.
    @MainActor final class Coordinator: NSObject {
        var onPageChange: @MainActor (Int) -> Void = { _ in }
        /// The page last reported or opened on, so it isn't reported again.
        private(set) var lastPage: Int?
        /// Set while ``withoutReporting(_:_:)`` reconfigures the view.
        private var isReconfiguring = false

        /// Runs `body` without reporting the pages PDFKit passes through: assigning a document
        /// selects its first page before `go(to:)` reaches the one to open on. Afterwards the
        /// page the view shows counts as reported.
        func withoutReporting(_ view: PDFView, _ body: () -> Void) {
            isReconfiguring = true
            body()
            isReconfiguring = false
            lastPage = view.currentPage.flatMap { view.document?.oneBasedPageNumber(of: $0) }
        }

        func observe(_ view: PDFView) {
            NotificationCenter.default.addObserver(
                self, selector: #selector(pageChanged(_:)), name: .PDFViewPageChanged, object: view)
        }

        func stopObserving(_ view: PDFView) {
            NotificationCenter.default.removeObserver(self, name: .PDFViewPageChanged, object: view)
        }

        @objc private func pageChanged(_ notification: Notification) {
            guard !isReconfiguring, let view = notification.object as? PDFView, let page = view.currentPage,
                let number = view.document?.oneBasedPageNumber(of: page), number != lastPage
            else { return }
            lastPage = number
            onPageChange(number)
        }
    }

    @MainActor private func makeView(context: Context) -> ReaderPDFView {
        let view = ReaderPDFView()
        view.displayDirection = .horizontal
        context.coordinator.observe(view)
        update(view, context: context)
        return view
    }

    @MainActor private func update(_ view: ReaderPDFView, context: Context) {
        let coordinator = context.coordinator
        coordinator.onPageChange = onPageChange
        let isNewDocument = view.document !== document
        let current = view.currentPage.flatMap { view.document?.oneBasedPageNumber(of: $0) }

        let mode: PDFDisplayMode = isSpread ? .twoUp : .singlePage
        let isNewLayout = view.displayMode != mode || view.displaysAsBook != isSpread || isNewDocument
        if isNewLayout {
            coordinator.withoutReporting(view) {
                view.setSpread(isSpread)
                view.displayMode = mode
                view.displaysAsBook = isSpread
                view.autoScales = true
                if isNewDocument { view.document = document }
                // A new layout keeps the page; a new document opens on the initial one.
                if let target = isNewDocument ? initialPage : current, let page = document.page(oneBased: target) {
                    view.go(to: page)
                }
            }
        }
        view.backgroundColor = background.color
    }
}

#if os(macOS)
    extension PDFReaderView: NSViewRepresentable {
        func makeCoordinator() -> Coordinator { Coordinator() }
        func makeNSView(context: Context) -> ReaderPDFView { makeView(context: context) }
        func updateNSView(_ view: ReaderPDFView, context: Context) { update(view, context: context) }
        static func dismantleNSView(_ view: ReaderPDFView, coordinator: Coordinator) {
            coordinator.stopObserving(view)
        }
    }

    /// Turns pages with the left and right arrow keys.
    final class ReaderPDFView: PDFView {
        override var acceptsFirstResponder: Bool { true }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.makeFirstResponder(self)
        }

        override func keyDown(with event: NSEvent) {
            switch event.specialKey {
            case .leftArrow where canGoToPreviousPage: goToPreviousPage(nil)
            case .rightArrow where canGoToNextPage: goToNextPage(nil)
            default: super.keyDown(with: event)
            }
        }

        /// PDFKit on macOS has no page view controller; arrows and scrolling turn both layouts.
        func setSpread(_ isSpread: Bool) {}
    }
#else
    extension PDFReaderView: UIViewRepresentable {
        func makeCoordinator() -> Coordinator { Coordinator() }
        func makeUIView(context: Context) -> ReaderPDFView { makeView(context: context) }
        func updateUIView(_ view: ReaderPDFView, context: Context) { update(view, context: context) }
        static func dismantleUIView(_ view: ReaderPDFView, coordinator: Coordinator) {
            coordinator.stopObserving(view)
        }
    }

    /// One page swipes with a page view controller. A spread can't use one, so swipes turn it.
    final class ReaderPDFView: PDFView {
        private lazy var swipes: [UISwipeGestureRecognizer] = ([.left, .right] as [UISwipeGestureRecognizer.Direction])
            .map { direction in
                let swipe = UISwipeGestureRecognizer(target: self, action: #selector(swiped(_:)))
                swipe.direction = direction
                addGestureRecognizer(swipe)
                return swipe
            }

        func setSpread(_ isSpread: Bool) {
            usePageViewController(!isSpread, withViewOptions: nil)
            for swipe in swipes { swipe.isEnabled = isSpread }
        }

        @objc private func swiped(_ swipe: UISwipeGestureRecognizer) {
            if swipe.direction == .left, canGoToNextPage {
                goToNextPage(nil)
            } else if swipe.direction == .right, canGoToPreviousPage {
                goToPreviousPage(nil)
            }
        }
    }
#endif

// MARK: - Preview

/// A PDF drawn in code, so the preview needs no file.
private func previewDocument(pages: Int) -> PDFDocument {
    let data = NSMutableData()
    var box = CGRect(x: 0, y: 0, width: 420, height: 595)
    guard let consumer = CGDataConsumer(data: data as CFMutableData),
        let context = CGContext(consumer: consumer, mediaBox: &box, nil)
    else { return PDFDocument() }
    for page in 1...pages {
        context.beginPDFPage(nil)
        let text = NSAttributedString(
            string: "\(page)",
            attributes: [.font: CTFontCreateWithName("Helvetica-Bold" as CFString, 160, nil)])
        let line = CTLineCreateWithAttributedString(text)
        let bounds = CTLineGetImageBounds(line, context)
        context.textPosition = CGPoint(x: box.midX - bounds.midX, y: box.midY - bounds.midY)
        CTLineDraw(line, context)
        context.stroke(box.insetBy(dx: 24, dy: 24))
        context.endPDFPage()
    }
    context.closePDF()
    return PDFDocument(data: data as Data) ?? PDFDocument()
}

#Preview("Single page") {
    PDFReaderView(document: previewDocument(pages: 8), initialPage: 2)
}

#Preview("Spread, dark") {
    PDFReaderView(document: previewDocument(pages: 8), initialPage: 3, isSpread: true, background: .dark)
}
