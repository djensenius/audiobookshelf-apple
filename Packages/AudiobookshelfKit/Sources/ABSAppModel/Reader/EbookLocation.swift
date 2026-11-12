import ABSCore
import ABSData
import Foundation

/// A validated `ebookLocation` (ADR 0008).
///
/// - EPUB: an epub.js CFI. Like the legacy app and the web client, a saved value is accepted
///   only if it starts with `epubcfi`. The reader must still check that the book resolves it
///   (`book.spine.get(cfi)`) and open at the start otherwise (#104).
/// - PDF and comics: a 1-based page. The web client sends a number and the legacy app sends
///   `String(page)`; both are read. Anything else, including 0, negative and fractional pages,
///   is rejected, and the reader opens at the start.
public enum EbookLocation: Sendable, Hashable {
    /// How a reader writes its location.
    public enum Style: Sendable, Hashable {
        case cfi
        case page
    }

    case cfi(String)
    /// 1-based.
    case page(Int)

    /// Parses a stored or server `ebookLocation` for a reader; `nil` when it isn't valid for it.
    public init?(_ stored: String?, style: Style?) {
        guard let stored, let style else { return nil }
        switch style {
        case .cfi:
            guard stored.hasPrefix("epubcfi") else { return nil }
            self = .cfi(stored)
        case .page:
            // Like JavaScript's `Number(value)`, surrounding whitespace is ignored.
            guard let value = Double(stored.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
            self.init(page: value, style: style)
        }
    }

    /// A page sent as a JSON number; `nil` unless it is a whole number of at least 1 and `style`
    /// is ``Style/page``.
    public init?(page value: Double, style: Style?) {
        guard style == .page, value.isFinite, value >= 1, value.rounded() == value, value <= Double(Int32.max)
        else { return nil }
        self = .page(Int(value))
    }

    public var style: Style {
        switch self {
        case .cfi: .cfi
        case .page: .page
        }
    }

    /// The `ebookLocation` to save and send: the CFI, or the page as a string, like the legacy app.
    public var stored: String {
        switch self {
        case .cfi(let cfi): cfi
        case .page(let page): String(page)
        }
    }

    /// Whether a reader of `kind` may save this location.
    public func isValid(for kind: ReaderKind) -> Bool {
        EbookLocation(stored, style: kind.locationStyle) == self
    }

    /// The page to open in a document of `pageCount` pages: the saved page when the document
    /// has it (`1...pageCount`), else the first page, as in the legacy PDF and comic readers.
    public func startPage(pageCount: Int) -> Int {
        if case .page(let page) = self, page >= 1, page <= pageCount { page } else { 1 }
    }

    /// The `ebookProgress` of a page, by the web client's formula `(page - 1) / numPages`,
    /// clamped to `0...1`.
    public static func progress(page: Int, pageCount: Int) -> Double {
        guard pageCount > 0 else { return 0 }
        return min(max(Double(page - 1) / Double(pageCount), 0), 1)
    }
}

/// Where a reader opens: the store row's location, which owns the position (ADR 0003, #101).
public struct EbookResumePoint: Sendable, Equatable {
    public enum Source: Sendable, Equatable {
        case local
        case server
        /// No valid saved location: open at the start.
        case beginning
    }

    public var location: EbookLocation?
    /// `0...1`, as saved with ``location``; `nil` when unknown.
    public var progress: Double?
    public var source: Source

    public init(location: EbookLocation?, progress: Double?, source: Source) {
        self.location = location
        self.progress = progress
        self.source = source
    }

    public static let beginning = EbookResumePoint(location: nil, progress: nil, source: .beginning)

    /// The first location valid for `kind`, in order: the row's, the row's before a merge
    /// replaced it (`replaced`, only when the merge brought a location valid for another format; a
    /// cleared or malformed location stays), then
    /// `server`, the progress known without a row. Dates aren't compared: the row already holds
    /// the store's decision. The chosen progress is ``normalized(_:)``, as a recorded one is.
    public static func resolve(
        kind: ReaderKind, local: LocalMediaProgressDTO?, replaced: LocalMediaProgressDTO? = nil,
        server: MediaProgress?
    ) -> Self {
        let style = kind.locationStyle
        let other: EbookLocation.Style? = style.map { $0 == .cfi ? .page : .cfi }
        let replaced = EbookLocation(local?.ebookLocation, style: other) == nil ? nil : replaced
        let candidates: [(String?, Double?, Source)] = [
            (local?.ebookLocation, local?.ebookProgress, .local),
            (replaced?.ebookLocation, replaced?.ebookProgress, .local),
            (server?.ebookLocation, server?.ebookProgress, .server),
        ]
        for (stored, progress, source) in candidates {
            if let location = EbookLocation(stored, style: style) {
                return EbookResumePoint(location: location, progress: normalized(progress), source: source)
            }
        }
        return .beginning
    }

    /// A saved progress as a reader takes it: `nil` when unknown or non-finite, else clamped to
    /// `0...1`.
    public static func normalized(_ progress: Double?) -> Double? {
        progress.flatMap { $0.isFinite ? min(max($0, 0), 1) : nil }
    }
}
