import ABSUI
import PDFKit
import SwiftUI

/// A ``PDFReaderView`` with page navigation (#102). With `showsControls` (the reader's chrome), a bar
/// along the bottom shows the page number, which opens a go-to-page field, and a button for a strip
/// of the document's page thumbnails (``PDFThumbnailStrip``): a row above the bar on iPhone and
/// iPad, a column down the leading side on Mac.
///
/// The page runs under the safe areas and the controls keep clear of them. A page picked by
/// number goes through ``PDFReaderView/requestedPage``, so it is reported like a turn once the
/// reader settles on it; a thumbnail turns the reader itself.
struct PDFPageNavigator: View {
    let document: PDFDocument
    /// The 1-based page to open on, clamped to the document.
    var initialPage = 1
    var isSpread = false
    var background = PDFReaderBackground.light
    /// Whether the navigation shows. The page doesn't move when it comes and goes.
    var showsControls = true
    /// The 1-based page the reader turned to.
    var onPageChange: @MainActor (Int) -> Void = { _ in }

    @State private var link = PDFReaderLink()
    @State private var request: PDFPageRequest?
    /// The page last reported; until then, the initial one.
    @State private var reportedPage: Int?
    @State private var showsThumbnails = false
    @State private var isGoingToPage = false
    @State private var typedPage = ""

    var body: some View {
        PDFReaderView(
            document: document, initialPage: initialPage, isSpread: isSpread, background: background,
            requestedPage: request, link: link
        ) { page in
            reportedPage = page
            onPageChange(page)
        }
        .ignoresSafeArea()
        .overlay {
            if showsControls, document.pageCount > 0 {
                controls
            }
        }
        .onChange(of: ObjectIdentifier(document)) {
            reportedPage = nil
            request = nil
        }
        .alert(Text(verbatim: L10n.string("ButtonReaderGoToPage")), isPresented: $isGoingToPage) {
            TextField(text: $typedPage, prompt: Text(verbatim: shownPage.formatted())) {
                Text(verbatim: L10n.string("LabelReaderPage"))
            }
            #if os(iOS)
                .keyboardType(.numberPad)
            #endif
            Button {
                goToTypedPage()
            } label: {
                Text(verbatim: L10n.string("ButtonGo"))
            }
            Button(role: .cancel) {
            } label: {
                Text(verbatim: L10n.string("ButtonCancel"))
            }
        } message: {
            Text(verbatim: pageNumberText)
        }
    }

    /// The thumbnails, when shown, and the bar. Their empty space lets taps through to the page.
    private var controls: some View {
        VStack(spacing: 0) {
            #if os(macOS)
                HStack(spacing: 0) {
                    if showsThumbnails {
                        PDFThumbnailStrip(link: link)
                            .frame(width: 112)
                            .background(.bar)
                        Divider()
                    }
                    Spacer(minLength: 0)
                }
                // Fills the height whether or not the thumbnails show, so the bar stays at the bottom.
                .frame(maxHeight: .infinity)
            #else
                Spacer(minLength: 0)
                if showsThumbnails {
                    PDFThumbnailStrip(link: link)
                        .frame(height: 76)
                        .background(.bar)
                }
            #endif
            bar
        }
    }

    private var bar: some View {
        ZStack {
            Button {
                typedPage = ""
                isGoingToPage = true
            } label: {
                Text(verbatim: pageNumberText)
                    .monospacedDigit()
                    .frame(minHeight: 44)
            }
            .buttonStyle(.borderless)
            .accessibilityHint(Text(verbatim: L10n.string("ButtonReaderGoToPage")))
            HStack {
                Toggle(isOn: $showsThumbnails) {
                    Label {
                        Text(verbatim: L10n.string("ButtonReaderThumbnails"))
                    } icon: {
                        Image(systemName: "square.grid.2x2")
                    }
                }
                .toggleStyle(.button)
                .labelStyle(.iconOnly)
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, ABSSpacing.medium)
        .padding(.vertical, ABSSpacing.xSmall)
        .background(.bar, ignoresSafeAreaEdges: .bottom)
    }

    /// The page shown: the last reported, or the initial one, clamped to the document.
    private var shownPage: Int {
        reportedPage ?? min(max(initialPage, 1), max(document.pageCount, 1))
    }

    private var pageNumberText: String {
        L10n.string("LabelReaderPageNumber", shownPage.formatted(), document.pageCount.formatted())
    }

    private func goToTypedPage() {
        guard let page = Self.page(from: typedPage, pageCount: document.pageCount) else { return }
        request = PDFPageRequest(page: page)
    }

    /// The 1-based page typed into the go-to-page field: digits in any script, around which space is
    /// ignored, clamped to `pageCount`. `nil` for anything else, or a document without pages.
    static func page(from text: String, pageCount: Int) -> Int? {
        let digits = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard pageCount > 0, !digits.isEmpty else { return nil }
        var number = 0
        for scalar in digits.unicodeScalars {
            guard CharacterSet.decimalDigits.contains(scalar), let digit = Character(scalar).wholeNumberValue
            else { return nil }
            // Past the last page stays there, so a long run of digits can't overflow.
            number = min(number * 10 + digit, pageCount)
        }
        return max(number, 1)
    }
}

/// Joins a ``PDFReaderView``'s page view to a ``PDFThumbnailStrip``, whichever is made first:
/// PDFKit's `PDFThumbnailView` shows and turns a `PDFView`. It holds both weakly.
@MainActor final class PDFReaderLink {
    weak var pdfView: PDFView? {
        didSet { join() }
    }
    weak var thumbnailView: PDFThumbnailView? {
        didSet { join() }
    }

    private func join() {
        guard let thumbnailView, thumbnailView.pdfView !== pdfView else { return }
        thumbnailView.pdfView = pdfView
    }
}

/// PDFKit's thumbnails of the pages a ``PDFReaderView`` shows, through a ``PDFReaderLink``: the
/// page shown is selected and a tap turns the reader to the page tapped. A row on iPhone and iPad,
/// a column on Mac.
struct PDFThumbnailStrip {
    let link: PDFReaderLink

    @MainActor private func attach(_ view: PDFThumbnailView) {
        if link.thumbnailView !== view { link.thumbnailView = view }
    }
}

#if os(macOS)
    extension PDFThumbnailStrip: NSViewRepresentable {
        /// Returned as is: on macOS PDFKit's thumbnail view scrolls itself, a collection view in its
        /// own `NSScrollView`. As another scroll view's document view it has no size to take.
        func makeNSView(context: Context) -> PDFThumbnailView {
            let view = PDFThumbnailView()
            view.maximumNumberOfColumns = 1
            view.thumbnailSize = CGSize(width: 72, height: 96)
            view.backgroundColor = .clear
            view.allowsDragging = false
            view.allowsMultipleSelection = false
            attach(view)
            return view
        }

        func updateNSView(_ view: PDFThumbnailView, context: Context) { attach(view) }
    }
#else
    extension PDFThumbnailStrip: UIViewRepresentable {
        func makeUIView(context: Context) -> PDFThumbnailView {
            let view = PDFThumbnailView()
            view.layoutMode = .horizontal
            view.thumbnailSize = CGSize(width: 44, height: 60)
            view.contentInset = UIEdgeInsets(top: 0, left: ABSSpacing.medium, bottom: 0, right: ABSSpacing.medium)
            view.backgroundColor = .clear
            attach(view)
            return view
        }

        func updateUIView(_ view: PDFThumbnailView, context: Context) { attach(view) }
    }
#endif
