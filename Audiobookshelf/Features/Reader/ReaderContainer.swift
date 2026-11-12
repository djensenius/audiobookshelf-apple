import ABSAPI
import ABSAppModel
import ABSCore
import ABSData
import ABSUI
import PDFKit
import SwiftUI

/// One item's ebook file to read, on one connection: what Read opens. Codable, so it can open the
/// macOS reader window (``ReaderWindow``).
struct ReaderPresentation: Codable, Hashable, Identifiable {
    let connectionID: UUID
    let itemID: String
    let title: String
    let file: EbookFile

    var id: String { [connectionID.uuidString, itemID, file.ino].joined(separator: "|") }
    var kind: ReaderKind { ReaderKind(file) }
    var request: EbookFileRequest { EbookFileRequest(connectionID: connectionID, itemID: itemID, file: file) }
}

extension EnvironmentValues {
    /// Builds an opened book's progress model with the account's `LocalProgressStore` and
    /// `ProgressSyncer`. The shell sets it once the progress syncer is wired (#184); until then it's
    /// `nil`, and readers open at the server's position and save nothing.
    @Entry var makeEbookProgress: (@MainActor (MediaKey, ReaderKind, MediaProgress?) -> EbookProgressModel?)?
    /// Finds an ebook's downloaded copy (``EbookFileLoader/downloadedFileLookup(items:locations:)``);
    /// `nil` without the on-device store.
    @Entry var downloadedEbookFile: (@Sendable (EbookFileRequest) async -> URL?)?
}

/// Where readers keep what they fetch and generate; the system may purge both.
enum ReaderCaches {
    static let ebooks = URL.cachesDirectory.appending(path: "Ebooks", directoryHint: .isDirectory)
    static let locations = EPUBLocationsCache(
        directory: URL.cachesDirectory.appending(path: "EPUBLocations", directoryHint: .isDirectory))
}

/// The reader for one ebook file (#101, ADR 0008, legacy `Reader.vue`): EPUB in the epub.js web
/// host, PDF in PDFKit, and the unsupported state for other formats. A tap shows or hides the
/// chrome (close, title and the reader settings). Full screen on iPhone and iPad, a window on Mac.
///
/// It needs the scene's library store serving the presentation's connection, for the account's
/// client and known progress. The reader follows the store: signing out or switching accounts
/// drops the book (the "not signed in" state), and the account's client attaching again reopens
/// it. Progress is flushed when the reader closes, when the app moves to the background, and
/// when the account goes.
struct ReaderContainer: View {
    let presentation: ReaderPresentation
    let onClose: () -> Void
    @Environment(\.libraryStore) private var store
    @Environment(\.makeEbookProgress) private var makeEbookProgress
    @Environment(\.downloadedEbookFile) private var downloadedEbookFile
    @Environment(\.scenePhase) private var scenePhase
    @State private var model: ReaderContainerModel?
    /// The account ``model`` was built for.
    @State private var modelSource: Source?
    @State private var isUnavailable = false
    @State private var serverURL: URL?

    /// The book, and the client of the account serving it, if the store is on its connection.
    private struct Source: Hashable {
        let presentation: ReaderPresentation
        let client: ObjectIdentifier?
    }

    private var servingClient: APIClient? {
        guard let store, store.connectionKey?.connectionID == presentation.connectionID else { return nil }
        return store.client as? APIClient
    }

    private var source: Source {
        Source(presentation: presentation, client: servingClient.map(ObjectIdentifier.init))
    }

    var body: some View {
        Group {
            if let model {
                ReaderContent(model: model, title: presentation.title, serverURL: serverURL, close: close)
            } else if isUnavailable {
                ErrorStateView(title: L10n.string("MessageReaderUnavailable"), systemImage: "book")
                    .overlay(alignment: .topLeading) { ReaderCloseButton(action: close).padding() }
            } else {
                LoadingView()
            }
        }
        .task(id: source) {
            let source = source
            if modelSource != source {
                if let model { Task { await model.flush() } }
                model = makeModel()
                modelSource = source
                serverURL = nil
            }
            isUnavailable = model == nil
            guard let model else { return }
            await model.load()
            // The account may have changed while it loaded; the next run replaces the model.
            guard !Task.isCancelled, self.source == source else { return }
            serverURL = try? await store?.makeServices()?.serverURL()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background, let model { Task { await model.flush() } }
        }
    }

    private func makeModel() -> ReaderContainerModel? {
        guard let store, let client = servingClient else { return nil }
        let fetcher = APIEbookFileFetcher(client: client)
        let kind = presentation.kind
        let serverProgress = store.progress.progress(libraryItemID: presentation.itemID)
        let key = MediaKey(serverConnectionID: presentation.connectionID, libraryItemId: presentation.itemID)
        let loader = EbookFileLoader(
            directory: ReaderCaches.ebooks, fetcher: fetcher, downloadedFile: downloadedEbookFile ?? { _ in nil })
        return ReaderContainerModel(
            request: presentation.request, kind: kind, loader: loader,
            progress: ReaderContainerModel.opens(kind) ? makeEbookProgress?(key, kind, serverProgress) : nil,
            serverProgress: serverProgress)
    }

    private func close() {
        if let model { Task { await model.flush() } }
        onClose()
    }
}

/// The loaded reader with its chrome.
private struct ReaderContent: View {
    let model: ReaderContainerModel
    let title: String
    let serverURL: URL?
    let close: () -> Void
    @Environment(AppSettings.self) private var settings: AppSettings?
    @Environment(\.colorScheme) private var colorScheme
    #if os(iOS)
        @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif
    @State private var size = CGSize.zero

    var body: some View {
        let readerSettings = settings?.readerSettings ?? ReaderSettings()
        let theme = ReaderTheme(readerSettings.theme, resolvedAppearance: colorScheme == .dark ? .dark : .light)
        let layout = spreadLayout(readerSettings.spread)
        ZStack(alignment: .top) {
            theme.chromeBackground.ignoresSafeArea()
            reader(settings: readerSettings, theme: theme, layout: layout)
                .onGeometryChange(for: CGSize.self) {
                    $0.size
                } action: {
                    size = $0
                }
            if model.isChromeVisible {
                ReaderChrome(model: model, title: title, close: close)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.default, value: model.isChromeVisible)
        // Native text and controls follow the reader's theme, not the app's appearance; "match
        // system" was resolved from the appearance outside.
        .environment(\.colorScheme, theme.colorScheme)
        #if os(iOS)
            .statusBarHidden(!model.isChromeVisible)
        #endif
    }

    @ViewBuilder
    private func reader(settings: ReaderSettings, theme: ReaderTheme, layout: ReaderSpreadLayout) -> some View {
        switch model.content {
        case .loading:
            LoadingView()
        case .failed:
            ErrorStateView(title: L10n.string("MessageReaderLoadFailed"), systemImage: "book") {
                Task { await model.load() }
            }
        case .unsupported:
            ReaderUnsupportedView(model: model, serverURL: serverURL)
        case .ready(let url):
            switch model.kind {
            case .pdf:
                PDFReaderHost(model: model, url: url, isSpread: layout.isTwoUp, theme: theme)
            case .epub:
                EPUBReaderView(
                    model: model, fileURL: url,
                    payload: ReaderSettingsPayload(
                        settings: settings, resolvedAppearance: colorScheme == .dark ? .dark : .light,
                        gap: layout.gap))
            case .comic, .unsupported:
                ReaderUnsupportedView(model: model, serverURL: serverURL)
            }
        }
    }

    private func spreadLayout(_ spread: ReaderSettings.Spread) -> ReaderSpreadLayout {
        #if os(iOS)
            ReaderSpreadPolicy.layout(
                setting: spread, platform: .iOS, sizeClass: horizontalSizeClass == .regular ? .regular : .compact,
                size: size, hingeWidth: nil)
        #else
            ReaderSpreadPolicy.layout(setting: spread, platform: .macOS, sizeClass: nil, size: size, hingeWidth: nil)
        #endif
    }
}

/// Close, the title, and the reader settings, over the top of the page.
private struct ReaderChrome: View {
    let model: ReaderContainerModel
    let title: String
    let close: () -> Void

    var body: some View {
        HStack(spacing: ABSSpacing.medium) {
            ReaderCloseButton(action: close)
            Text(verbatim: title)
                .font(.headline)
                .lineLimit(1)
                .frame(maxWidth: .infinity)
                .accessibilityAddTraits(.isHeader)
            ReaderSettingsMenu(kind: model.kind)
                .disabled(!ReaderContainerModel.opens(model.kind))
        }
        .padding(.horizontal, ABSSpacing.medium)
        .padding(.vertical, ABSSpacing.small)
        .frame(minHeight: 44)
        .background(.bar)
    }
}

private struct ReaderCloseButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label {
                Text(verbatim: L10n.string("ButtonItemDetailClose"))
            } icon: {
                Image(systemName: "xmark")
            }
            .labelStyle(.iconOnly)
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.cancelAction)
    }
}

/// A format the app doesn't open: CBZ until the comic reader (#105), and CBR, MOBI and AZW3 in v1
/// (ADR 0008 §4). The web client reads it.
private struct ReaderUnsupportedView: View {
    let model: ReaderContainerModel
    let serverURL: URL?

    var body: some View {
        ContentUnavailableView {
            Label {
                Text(verbatim: L10n.string("MessageReaderUnsupported", model.formatName))
            } icon: {
                Image(systemName: "book.closed").accessibilityHidden(true)
            }
        } actions: {
            if let serverURL {
                Link(destination: ItemDetailModel.webURL(serverURL: serverURL, itemID: model.request.itemID)) {
                    Text(verbatim: L10n.string("ButtonReadInBrowser"))
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }
}

/// Opens the PDF from disk, then shows it at the resume page.
private struct PDFReaderHost: View {
    let model: ReaderContainerModel
    let url: URL
    let isSpread: Bool
    let theme: ReaderTheme
    @State private var document: PDFDocument?
    @State private var failure: PDFDocumentLoadError?

    var body: some View {
        Group {
            if let document {
                let pageCount = document.pageCount
                PDFReaderView(
                    document: document, initialPage: model.resumePoint.location?.startPage(pageCount: pageCount) ?? 1,
                    isSpread: isSpread, background: PDFReaderBackground(theme)
                ) { page in
                    model.record(.page(page), progress: EbookLocation.progress(page: page, pageCount: pageCount))
                }
                .ignoresSafeArea()
                .simultaneousGesture(TapGesture().onEnded { model.toggleChrome() })
            } else if let failure {
                ErrorStateView(
                    title: L10n.string(failure == .locked ? "MessageReaderPDFLocked" : "MessageReaderLoadFailed"),
                    systemImage: failure == .locked ? "lock" : "book")
            } else {
                LoadingView()
            }
        }
        .task(id: url) {
            do throws(PDFDocumentLoadError) {
                document = try await PDFDocumentLoader.load(from: url)
            } catch {
                failure = error
            }
        }
    }
}

extension PDFReaderBackground {
    init(_ theme: ReaderTheme) {
        switch theme {
        case .light: self = .light
        case .dark: self = .dark
        case .black: self = .black
        case .sepia: self = .sepia
        }
    }
}

extension ReaderTheme {
    /// The appearance of native views over the page.
    var colorScheme: ColorScheme {
        switch self {
        case .light, .sepia: .light
        case .dark, .black: .dark
        }
    }

    /// The page colour behind the reader and its safe areas.
    var chromeBackground: Color {
        switch self {
        case .light: .white
        case .dark: Color(red: 35 / 255, green: 35 / 255, blue: 35 / 255)
        case .black: .black
        case .sepia: Color(red: 244 / 255, green: 236 / 255, blue: 216 / 255)
        }
    }
}

extension ReaderSpreadLayout {
    /// The EPUB bridge's column gap: the hinge's width in a spanned spread, else epub.js's own.
    var gap: Double {
        if case .twoUp(let gap) = self { Double(gap) } else { 0 }
    }
}

/// Opens the reader on one ebook (``ReaderPresenter``).
struct OpenReaderAction {
    let presentation: ReaderPresentation
    let open: @MainActor (ReaderPresentation) -> Void

    @MainActor func callAsFunction() { open(presentation) }
}

extension EnvironmentValues {
    /// Opens the reader on the item detail's ebook; `nil` without one.
    @Entry var openReader: OpenReaderAction?
}

/// Presents an item's ebook in ``ReaderContainer``: full screen on iPhone and iPad, its own window
/// on Mac (``ReaderWindow``). It provides ``EnvironmentValues/openReader`` while the item has an
/// ebook file and the library store has a connection.
struct ReaderPresenter: ViewModifier {
    let itemID: String
    let title: String
    let file: EbookFile?
    @Environment(\.libraryStore) private var store
    #if os(macOS)
        @Environment(\.openWindow) private var openWindow
    #else
        @State private var presented: ReaderPresentation?
    #endif

    func body(content: Content) -> some View {
        #if os(macOS)
            content.environment(\.openReader, action { [openWindow] in openWindow(id: ReaderWindow.id, value: $0) })
        #else
            content
                .environment(\.openReader, action { [$presented] in $presented.wrappedValue = $0 })
                .fullScreenCover(item: $presented) { presentation in
                    ReaderContainer(presentation: presentation) { presented = nil }
                }
        #endif
    }

    private func action(_ open: @escaping @MainActor (ReaderPresentation) -> Void) -> OpenReaderAction? {
        guard let file, let key = store?.connectionKey else { return nil }
        return OpenReaderAction(
            presentation: ReaderPresentation(connectionID: key.connectionID, itemID: itemID, title: title, file: file),
            open: open)
    }
}

#if os(macOS)
    /// The macOS reader window: a reader for the presentation, if the app's library store is still
    /// on its connection.
    struct ReaderWindow: View {
        static let id = "reader"
        let presentation: ReaderPresentation?
        let store: LibraryStore?
        @Environment(\.dismiss) private var dismiss

        var body: some View {
            if let presentation {
                ReaderContainer(presentation: presentation) { dismiss() }
                    .environment(\.libraryStore, store)
                    .navigationTitle(Text(verbatim: presentation.title))
                    .frame(minWidth: 480, minHeight: 600)
            }
        }
    }
#endif
