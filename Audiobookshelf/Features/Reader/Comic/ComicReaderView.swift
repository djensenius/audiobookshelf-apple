import ABSAppModel
import ABSUI
import SwiftUI

/// The comic reader (#105, ADR 0008 decisions 3, 4 and 7): a CBZ already on disk, paged or in a
/// vertical scroll, with pinch zoom, two-page spreads when `layout` asks for them, and a
/// right-to-left toggle. A RAR archive (CBR) shows the unsupported state instead.
///
/// It reports each turn to `onPageChange` as a 1-based page `ebookLocation` with the web
/// client's progress; the reader container records them through `EbookProgressModel`. A tap
/// calls `onTap`, for the container's chrome. Pages turn by swiping and with the arrow keys,
/// which follow the reading direction.
///
/// The pager is a paging `ScrollView` rather than a `TabView`, whose page style iOS has but
/// macOS doesn't.
struct ComicReaderView: View {
    let fileURL: URL
    /// The resume point's location.
    var startLocation: EbookLocation?
    /// From ``ReaderSpreadPolicy``; vertical scroll ignores it.
    var layout = ReaderSpreadLayout.single
    var background = Color.black
    /// The book in the web client, for "Read in Browser" in the unsupported state.
    var webURL: URL?
    /// Identifies the book, for its saved reading direction.
    var preferencesKey: String?
    /// Shows the page number and the direction and scroll options.
    var showsControls = true
    var onTap: () -> Void = {}
    var onPageChange: @MainActor (EbookLocation, Double) -> Void = { _, _ in }
    @State private var model: ComicReaderModel?

    var body: some View {
        Group {
            if let model {
                switch model.state {
                case .loading:
                    LoadingView()
                case .ready:
                    ComicPagesView(model: model, layout: layout, showsControls: showsControls, onTap: onTap)
                case .unsupportedFormat:
                    ComicUnsupportedView(fileURL: fileURL, webURL: webURL)
                case .failed:
                    ErrorStateView(title: L10n.string("MessageReaderComicFailed"), systemImage: "book") {
                        Task { await model.open() }
                    }
                }
            } else {
                LoadingView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(background)
        .task(id: fileURL) {
            let model = ComicReaderModel(
                fileURL: fileURL,
                cacheDirectory: URL.cachesDirectory.appending(path: "ComicPages/\(UUID().uuidString)"),
                startLocation: startLocation, defaults: .standard, preferencesKey: preferencesKey,
                onPageChange: onPageChange)
            self.model = model
            await model.open()
        }
    }
}

/// The open comic: its pages and, with `showsControls`, the page number and options.
private struct ComicPagesView: View {
    let model: ComicReaderModel
    let layout: ReaderSpreadLayout
    let showsControls: Bool
    let onTap: () -> Void
    @State private var isZoomed = false

    var body: some View {
        ZStack(alignment: .bottom) {
            Group {
                if model.isVerticalScroll {
                    ComicScrollView(model: model, isZoomed: $isZoomed, onTap: onTap)
                } else {
                    ComicPagerView(model: model, gap: layout.gutter, isZoomed: $isZoomed, onTap: onTap)
                }
            }
            .ignoresSafeArea()
            if showsControls {
                ComicControls(model: model)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.default, value: showsControls)
        .onChange(of: layout.isTwoUp, initial: true) { _, twoUp in model.setTwoUp(twoUp) }
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.leftArrow) {
            model.turn(.left)
            return .handled
        }
        .onKeyPress(.rightArrow) {
            model.turn(.right)
            return .handled
        }
    }
}

/// One spread per screen, swiped sideways; right to left starts at the right end.
private struct ComicPagerView: View {
    let model: ComicReaderModel
    let gap: CGFloat
    @Binding var isZoomed: Bool
    let onTap: () -> Void
    @State private var position: ComicSpread?

    var body: some View {
        let spreads = model.spreads
        let shown = spreads.indices.map {
            spreads[ComicReaderLayout.displayIndex($0, count: spreads.count, rightToLeft: model.isRightToLeft)]
        }
        ScrollView(.horizontal) {
            LazyHStack(spacing: 0) {
                ForEach(shown, id: \.self) { spread in
                    let pages = spread.displayOrder(rightToLeft: model.isRightToLeft)
                    HStack(spacing: gap) {
                        ForEach(Array(pages.enumerated()), id: \.element) { index, page in
                            ComicPageView(model: model, page: page)
                                .frame(
                                    maxWidth: .infinity, maxHeight: .infinity,
                                    alignment: pages.count == 1 ? .center : index == 0 ? .trailing : .leading)
                        }
                    }
                    .modifier(ComicZoom(isZoomed: $isZoomed, onTap: onTap))
                    .containerRelativeFrame([.horizontal, .vertical])
                    .clipped()
                }
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.paging)
        .scrollPosition(id: $position)
        .scrollIndicators(.hidden)
        .scrollDisabled(isZoomed)
        .onChange(of: position) { _, spread in
            if let spread, let index = model.spreads.firstIndex(of: spread) { model.show(spreadAt: index) }
        }
        .onChange(of: model.spreads, initial: true) { syncPosition() }
        .onChange(of: model.spreadIndex) { syncPosition() }
    }

    private func syncPosition() {
        let spreads = model.spreads
        guard spreads.indices.contains(model.spreadIndex) else { return }
        position = spreads[model.spreadIndex]
    }
}

/// Every page in one column, scrolled vertically; always single pages.
private struct ComicScrollView: View {
    let model: ComicReaderModel
    @Binding var isZoomed: Bool
    let onTap: () -> Void
    @State private var position: Int?

    var body: some View {
        ScrollView(.vertical) {
            LazyVStack(spacing: 0) {
                ForEach(1...max(model.pageCount, 1), id: \.self) { page in
                    ComicPageView(model: model, page: page, fillsWidth: true)
                        .containerRelativeFrame(.horizontal)
                }
            }
            .scrollTargetLayout()
        }
        .modifier(ComicZoom(isZoomed: $isZoomed, onTap: onTap))
        .scrollPosition(id: $position, anchor: .top)
        .scrollDisabled(isZoomed)
        .onChange(of: position) { _, page in
            if let page { model.show(page: page) }
        }
        .onChange(of: model.spreadIndex, initial: true) {
            if position != model.currentPage { position = model.currentPage }
        }
    }
}

/// One page, decoded when it first shows.
private struct ComicPageView: View {
    let model: ComicReaderModel
    let page: Int
    /// Vertical scroll: as wide as the reader, as tall as the image needs.
    var fillsWidth = false
    @State private var image: ComicPageImage?
    @State private var failed = false

    var body: some View {
        Group {
            if let image {
                Image(decorative: image.image, scale: 1)
                    .resizable()
                    .aspectRatio(image.size, contentMode: .fit)
            } else if failed {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 200)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: fillsWidth ? 400 : 0)
            }
        }
        .task(id: page) {
            image = await model.image(ofPage: page)
            failed = image == nil
        }
    }
}

/// Pinch to zoom up to 5×, drag to pan while zoomed, double-tap to zoom in or reset; a single tap
/// calls `onTap`. The pages don't turn while zoomed.
private struct ComicZoom: ViewModifier {
    @Binding var isZoomed: Bool
    let onTap: () -> Void
    @State private var scale: CGFloat = 1
    @State private var baseScale: CGFloat = 1
    @State private var offset = CGSize.zero
    @State private var baseOffset = CGSize.zero
    @State private var size = CGSize.zero

    func body(content: Content) -> some View {
        content
            .scaleEffect(scale)
            .offset(offset)
            .onGeometryChange(for: CGSize.self) {
                $0.size
            } action: {
                size = $0
            }
            .contentShape(.rect)
            .gesture(
                MagnifyGesture()
                    .onChanged { value in
                        let range = ComicReaderLayout.zoomRange
                        scale = min(max(baseScale * value.magnification, range.lowerBound), range.upperBound)
                        offset = ComicReaderLayout.clampedOffset(baseOffset, scale: scale, size: size)
                    }
                    .onEnded { _ in settle() }
            )
            .gesture(
                DragGesture()
                    .onChanged { value in
                        let moved = CGSize(
                            width: baseOffset.width + value.translation.width,
                            height: baseOffset.height + value.translation.height)
                        offset = ComicReaderLayout.clampedOffset(moved, scale: scale, size: size)
                    }
                    .onEnded { _ in baseOffset = offset },
                isEnabled: scale > 1
            )
            .onTapGesture(count: 2) {
                withAnimation {
                    scale = scale > 1 ? 1 : 2
                    offset = .zero
                }
                settle()
            }
            .onTapGesture(perform: onTap)
            .onDisappear { if scale > 1 { isZoomed = false } }
    }

    private func settle() {
        if scale <= 1.01 {
            scale = 1
            offset = .zero
        }
        baseScale = scale
        baseOffset = offset
        isZoomed = scale > 1
    }
}

/// The page number, and the reading direction and vertical scroll options.
private struct ComicControls: View {
    let model: ComicReaderModel

    var body: some View {
        HStack(spacing: ABSSpacing.medium) {
            Text(
                verbatim: L10n.string(
                    "LabelReaderPageNumber", model.currentPage.formatted(), model.pageCount.formatted())
            )
            .font(.footnote.monospacedDigit())
            .frame(maxWidth: .infinity, alignment: .leading)
            Menu {
                Toggle(isOn: Binding(get: { model.isRightToLeft }, set: { model.setRightToLeft($0) })) {
                    Text(verbatim: L10n.string("LabelReaderRightToLeft"))
                }
                Toggle(isOn: Binding(get: { model.isVerticalScroll }, set: { model.setVerticalScroll($0) })) {
                    Text(verbatim: L10n.string("LabelReaderVerticalScroll"))
                }
            } label: {
                Label {
                    Text(verbatim: L10n.string("HeaderEreaderSettings"))
                } icon: {
                    Image(systemName: "book.pages")
                }
                .labelStyle(.iconOnly)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(.rect)
            }
            .menuIndicator(.hidden)
        }
        .padding(.horizontal, ABSSpacing.medium)
        .background(.bar)
    }
}

/// A RAR archive (CBR), which the app doesn't open in v1 (ADR 0008 §4): "Open In…" hands the file
/// to another app, and the web client reads it.
private struct ComicUnsupportedView: View {
    let fileURL: URL
    let webURL: URL?

    var body: some View {
        ContentUnavailableView {
            Label {
                Text(verbatim: L10n.string("MessageReaderFormatUnsupported"))
            } icon: {
                Image(systemName: "book.closed").accessibilityHidden(true)
            }
        } actions: {
            ShareLink(item: fileURL) {
                Text(verbatim: L10n.string("ButtonOpenIn"))
            }
            if let webURL {
                Link(destination: webURL) {
                    Text(verbatim: L10n.string("ButtonReadInBrowser"))
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }
}

extension ReaderSpreadLayout {
    /// The space between a spread's pages: the hinge's width on a spanned Duo, else none.
    fileprivate var gutter: CGFloat {
        if case .twoUp(let gap) = self { gap } else { 0 }
    }
}

#Preview("Failed") {
    ComicReaderView(
        fileURL: URL.temporaryDirectory.appending(path: "missing.cbz"),
        webURL: URL(string: "https://abs.example.com/item/1"))
}
