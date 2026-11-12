import CoreGraphics
import Foundation
import ImageIO
import Observation

/// One decoded comic page.
public struct ComicPageImage: Sendable {
    public let page: Int
    public let image: CGImage

    /// The decoded size in pixels.
    public var size: CGSize { CGSize(width: image.width, height: image.height) }
}

/// The comic reader's state for one CBZ file (#105, ADR 0008 decisions 3, 4 and 7): the open
/// archive, its spreads, the visible spread, and the reader's direction and scroll mode.
///
/// - **Location.** It opens at `startLocation` (a 1-based page, clamped by
///   ``EbookLocation/startPage(pageCount:)``) and reports each turn to `onPageChange` as the
///   visible spread's lower page, with the web client's progress `(page - 1) / pageCount`. The
///   reader container passes them to `EbookProgressModel`. Opening, a layout change or a repeat
///   of the last page isn't reported.
/// - **Spreads.** ``setTwoUp(_:)`` takes the shared spread policy's decision; vertical scroll is
///   always single. Pages marked in `ComicInfo.xml` and landscape images show alone; landscape
///   pages are found as they are decoded, so the spreads after one change then. The page being
///   read stays visible through every relayout.
/// - **Direction.** Right to left defaults to `ComicInfo.xml`'s `<Manga>YesAndRightToLeft</Manga>`.
///   A choice made with ``setRightToLeft(_:)`` is saved per `preferencesKey` and wins afterwards.
///   Vertical scroll is one choice for every comic.
/// - **CBR.** A RAR archive, whatever its extension, is ``State/unsupportedFormat``.
@MainActor
@Observable
public final class ComicReaderModel {
    public enum State: Sendable, Equatable {
        case loading
        case ready
        /// A RAR archive (CBR), which the app doesn't open in v1 (ADR 0008 §4).
        case unsupportedFormat
        case failed
    }

    /// The longest side a page is decoded at: sharp at full zoom on a large display, without
    /// keeping full-resolution scans in memory.
    public nonisolated static let maxPixelSize = 4096
    static let verticalScrollKey = "comicReaderVerticalScroll"

    public private(set) var state = State.loading
    public private(set) var pageCount = 0
    public private(set) var spreads: [ComicSpread] = []
    /// The visible spread's index in ``spreads``.
    public private(set) var spreadIndex = 0
    public private(set) var isRightToLeft = false
    public private(set) var isVerticalScroll: Bool
    /// Whether the layout asks for two-page spreads; vertical scroll ignores it.
    public private(set) var isTwoUp = false

    /// The visible spread's lower page, 1-based.
    public var currentPage: Int { spreads.indices.contains(spreadIndex) ? spreads[spreadIndex].lower : 1 }

    @ObservationIgnored private let fileURL: URL
    @ObservationIgnored private let cacheDirectory: URL
    @ObservationIgnored private let startLocation: EbookLocation?
    @ObservationIgnored private let defaults: UserDefaults?
    @ObservationIgnored private let preferencesKey: String?
    @ObservationIgnored private let onPageChange: @MainActor (EbookLocation, Double) -> Void
    @ObservationIgnored private var archive: ComicArchive?
    /// Pages shown alone: marked in `ComicInfo.xml` or found to be landscape.
    @ObservationIgnored private var alone: Set<Int> = []
    /// The page the reader turned to, kept visible when the spreads change.
    @ObservationIgnored private var anchorPage = 1

    /// - Parameters:
    ///   - fileURL: The CBZ on disk.
    ///   - cacheDirectory: Where pages are extracted; it belongs to this reader and is emptied.
    ///   - startLocation: The resume point's location.
    ///   - defaults: Where the direction and scroll mode are saved; `nil` saves nothing.
    ///   - preferencesKey: Identifies the book for its saved direction.
    ///   - onPageChange: A turn's location and progress.
    public init(
        fileURL: URL, cacheDirectory: URL, startLocation: EbookLocation?, defaults: UserDefaults? = nil,
        preferencesKey: String? = nil, onPageChange: @escaping @MainActor (EbookLocation, Double) -> Void
    ) {
        self.fileURL = fileURL
        self.cacheDirectory = cacheDirectory
        self.startLocation = startLocation
        self.defaults = defaults
        self.preferencesKey = preferencesKey
        self.onPageChange = onPageChange
        isVerticalScroll = defaults?.bool(forKey: Self.verticalScrollKey) ?? false
    }

    /// Opens the archive off the main actor. Again after a failure retries.
    public func open() async {
        guard archive == nil else { return }
        state = .loading
        let (url, cache) = (fileURL, cacheDirectory)
        let result = await Self.openArchive(url, cacheDirectory: cache)
        switch result {
        case .success(let archive):
            self.archive = archive
            pageCount = archive.pageCount
            alone = ComicReaderLayout.markedAlone(archive.comicInfo)
            isRightToLeft = savedRightToLeft ?? archive.comicInfo?.isRightToLeft ?? false
            anchorPage = startLocation?.startPage(pageCount: pageCount) ?? 1
            relayout()
            state = .ready
        case .failure(.unsupportedRAR):
            state = .unsupportedFormat
        case .failure:
            state = .failed
        }
    }

    /// The decoded page, extracted on demand; `nil` if it can't be read. A landscape page is
    /// shown alone from then on.
    public func image(ofPage page: Int) async -> ComicPageImage? {
        guard let archive, let image = await Self.decode(page, from: archive) else { return nil }
        if ComicReaderLayout.isLandscape(image.size), alone.insert(page).inserted, isTwoUp, !isVerticalScroll {
            relayout()
        }
        return image
    }

    /// Shows the spread at `index` (the pager settled on it); out of range is ignored.
    public func show(spreadAt index: Int) {
        guard spreads.indices.contains(index), index != spreadIndex else { return }
        spreadIndex = index
        anchorPage = currentPage
        report()
    }

    /// Shows the spread with `page` (vertical scroll reached it).
    public func show(page: Int) {
        guard (1...max(pageCount, 1)).contains(page) else { return }
        show(spreadAt: ComicReaderLayout.spreadIndex(containing: page, in: spreads))
    }

    /// Turns `delta` spreads in reading order, stopping at the first and last.
    public func turn(by delta: Int) {
        guard !spreads.isEmpty else { return }
        show(spreadAt: min(max(spreadIndex + delta, 0), spreads.count - 1))
    }

    /// Turns for an arrow key, which follows the reading direction.
    public func turn(_ arrow: ComicReaderLayout.Arrow) {
        turn(by: ComicReaderLayout.step(for: arrow, rightToLeft: isRightToLeft))
    }

    public func setTwoUp(_ twoUp: Bool) {
        guard twoUp != isTwoUp else { return }
        isTwoUp = twoUp
        relayout()
    }

    public func setRightToLeft(_ rightToLeft: Bool) {
        isRightToLeft = rightToLeft
        if let defaults, let key = rightToLeftKey { defaults.set(rightToLeft, forKey: key) }
    }

    public func setVerticalScroll(_ vertical: Bool) {
        guard vertical != isVerticalScroll else { return }
        isVerticalScroll = vertical
        defaults?.set(vertical, forKey: Self.verticalScrollKey)
        relayout()
    }

    // MARK: - Private

    private var rightToLeftKey: String? { preferencesKey.map { "comicReaderRightToLeft|\($0)" } }

    private var savedRightToLeft: Bool? {
        guard let defaults, let key = rightToLeftKey, defaults.object(forKey: key) != nil else { return nil }
        return defaults.bool(forKey: key)
    }

    private func relayout() {
        spreads = ComicReaderLayout.spreads(pageCount: pageCount, twoUp: isTwoUp && !isVerticalScroll, alone: alone)
        spreadIndex = ComicReaderLayout.spreadIndex(containing: anchorPage, in: spreads)
    }

    private func report() {
        let page = currentPage
        onPageChange(.page(page), EbookLocation.progress(page: page, pageCount: pageCount))
    }

    @concurrent private static func openArchive(
        _ url: URL, cacheDirectory: URL
    ) async -> Result<ComicArchive, ComicArchiveError> {
        do throws(ComicArchiveError) {
            return .success(try ComicArchive(url: url, cacheDirectory: cacheDirectory))
        } catch {
            return .failure(error)
        }
    }

    /// Extracts and decodes `page`, downsampled to ``maxPixelSize`` with its EXIF orientation applied.
    @concurrent private static func decode(_ page: Int, from archive: ComicArchive) async -> ComicPageImage? {
        guard let url = try? await archive.page(page),
            let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { return nil }
        let options =
            [
                kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
            ] as CFDictionary
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else { return nil }
        return ComicPageImage(page: page, image: image)
    }
}
