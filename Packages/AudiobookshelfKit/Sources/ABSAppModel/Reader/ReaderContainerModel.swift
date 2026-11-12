import ABSCore
import Foundation
import Observation

/// The reader container's state for one ebook file (#101, ADR 0008): which reader opens it, the
/// file on disk, where it opens, and whether the chrome shows.
///
/// - **Formats.** EPUB and PDF open; CBZ waits for the comic reader (#105), and CBR, MOBI and
///   AZW3 aren't opened in v1 (ADR 0008 §4): both show the unsupported state.
/// - **Progress.** With an ``EbookProgressModel``, the reader resumes from it and every page turn
///   goes through it (local first, then the debounced sync); ``flush()`` sends at once, for
///   closing and backgrounding. Without one (until the account's progress store and syncer are
///   wired, #184), the reader opens at the server's position as known and saves nothing.
/// - **Opening.** A reader reports where it opened; that report is the resume point, not a
///   turn, so opening a book doesn't mark its progress changed. A reader that renders the book
///   somewhere else on opening (epub.js reports the start of the page holding the saved CFI, or
///   the first page's CFI for an unread book) reports it through ``recordOpening(_:progress:)``.
@MainActor
@Observable
public final class ReaderContainerModel {
    public enum Content: Sendable, Equatable {
        case loading
        /// The file is on disk at the URL.
        case ready(URL)
        /// The app doesn't open this format (yet).
        case unsupported
        /// The file couldn't be fetched.
        case failed
    }

    public let request: EbookFileRequest
    public let kind: ReaderKind
    public private(set) var content = Content.loading
    /// Where the reader opens, once loaded.
    public private(set) var resumePoint = EbookResumePoint.beginning
    /// The latest location reported, or the resume point's.
    public private(set) var location: EbookLocation?
    /// `0...1` with ``location``.
    public private(set) var progress: Double?
    public private(set) var isChromeVisible = true

    @ObservationIgnored private let loader: EbookFileLoader
    @ObservationIgnored private let progressModel: EbookProgressModel?
    @ObservationIgnored private let serverProgress: MediaProgress?
    /// Whether a location other than where the reader opened was reported.
    @ObservationIgnored private var turned = false
    /// Where the reader rendered the book on opening, if it said (``recordOpening(_:progress:)``).
    @ObservationIgnored private var openedAt: EbookLocation?

    /// - Parameters:
    ///   - progress: The book's progress model; `nil` opens at `serverProgress` and saves nothing.
    ///   - serverProgress: The progress known for the item, used without `progress`.
    public init(
        request: EbookFileRequest, kind: ReaderKind, loader: EbookFileLoader, progress: EbookProgressModel?,
        serverProgress: MediaProgress?
    ) {
        self.request = request
        self.kind = kind
        self.loader = loader
        self.progressModel = progress
        self.serverProgress = serverProgress
    }

    /// Whether the container has a reader for `kind`: EPUB and PDF.
    public static func opens(_ kind: ReaderKind) -> Bool {
        switch kind {
        case .epub, .pdf: true
        case .comic, .unsupported: false
        }
    }

    /// The format's name for the unsupported state, such as `CBZ` or `MOBI`.
    public var formatName: String {
        switch kind {
        case .epub: "EPUB"
        case .pdf: "PDF"
        case .comic: "CBZ"
        case .unsupported(let format):
            (format.rawValue.isEmpty ? request.fileExtension : format.rawValue).uppercased()
        }
    }

    /// Whether page turns are saved: there's a progress model.
    public var savesProgress: Bool { progressModel != nil }

    /// Fetches the file (or finds it on disk) and the resume point together. Again after a failure
    /// retries.
    public func load() async {
        guard Self.opens(kind) else {
            content = .unsupported
            return
        }
        content = .loading
        let (loader, request) = (loader, request)
        let file = Task { try await loader.load(request) }
        let point = await resume()
        do {
            let url = try await withTaskCancellationHandler {
                try await file.value.url
            } onCancel: {
                file.cancel()
            }
            resumePoint = point
            if !turned {
                location = point.location
                progress = point.progress
            }
            content = .ready(url)
        } catch {
            guard !(error is CancellationError), !Task.isCancelled else { return }
            content = .failed
        }
    }

    private func resume() async -> EbookResumePoint {
        if let progressModel { return await progressModel.resume() }
        return EbookResumePoint.resolve(kind: kind, local: nil, server: serverProgress)
    }

    /// Where the reader rendered the book on opening, before any turn: shown, but not saved, and
    /// not a turn when reported again. Ignored once the reader has turned.
    public func recordOpening(_ location: EbookLocation, progress: Double?) {
        guard !turned, location.isValid(for: kind) else { return }
        openedAt = location
        self.location = location
        self.progress = EbookResumePoint.normalized(progress)
    }

    /// A location the reader reports. One that isn't valid for the format is ignored; the resume
    /// point or the opening location before any other location is where the reader opened, not a
    /// turn.
    public func record(_ location: EbookLocation, progress: Double?) {
        guard location.isValid(for: kind) else { return }
        if !turned, location == resumePoint.location || location == openedAt { return }
        turned = true
        self.location = location
        self.progress = EbookResumePoint.normalized(progress)
        progressModel?.record(location, progress: progress)
    }

    public func toggleChrome() {
        isChromeVisible.toggle()
    }

    /// Sends unsent progress now: call when the reader closes and when the app moves to the
    /// background.
    public func flush() async {
        await progressModel?.flush()
    }
}
