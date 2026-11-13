import Foundation
import Observation

/// One row of an EPUB's table of contents, flattened from the page's nested `toc` items.
public struct EPUBContentsEntry: Sendable, Hashable, Identifiable {
    /// Its position in ``EPUBTableOfContents/entries``.
    public let id: Int
    public let label: String
    /// The spine href ``EPUBBridgeCommand/display(target:)`` shows.
    public let href: String
    /// Its nesting, from 0 for a top-level entry; at most ``EPUBTableOfContents/maxLevel``.
    public let level: Int

    public init(id: Int, label: String, href: String, level: Int) {
        self.id = id
        self.label = label
        self.href = href
        self.level = level
    }
}

/// A book's table of contents as the TOC sheet lists it: the entries in reading order, each with
/// its level, as the legacy reader's modal lists chapters and their subchapters.
public struct EPUBTableOfContents: Sendable, Hashable {
    /// The most entries kept; a crafted book's longer list is cut off here.
    public static let maxEntries = 5000
    /// The deepest indentation; deeper entries are listed at this level.
    public static let maxLevel = 5

    public let entries: [EPUBContentsEntry]

    /// Flattens `items` depth first. An entry without an href can't be shown, so it's left out and
    /// its subitems take its place; one without a label is listed by its href.
    public init(_ items: [EPUBTOCItem]) {
        var entries: [EPUBContentsEntry] = []
        // A stack rather than recursion, so a deeply nested list can't exhaust the stack.
        var pending = items.reversed().map { ($0, 0) }
        while entries.count < Self.maxEntries, let (item, level) = pending.popLast() {
            var childLevel = level
            if !item.href.isEmpty {
                let label = item.label.trimmingCharacters(in: .whitespacesAndNewlines)
                entries.append(
                    EPUBContentsEntry(
                        id: entries.count, label: label.isEmpty ? item.href : label, href: item.href,
                        level: min(level, Self.maxLevel)))
                childLevel = level + 1
            }
            pending.append(contentsOf: item.subitems.reversed().map { ($0, childLevel) })
        }
        self.entries = entries
    }

    /// Decodes a `toc` event's message: `nil` when it isn't one or is malformed. Call it off the
    /// main actor; a book's table of contents can be large.
    public static func decode(_ data: Data) -> EPUBTableOfContents? {
        guard case .toc(let items) = try? EPUBBridgeEvent.decode(data) else { return nil }
        return EPUBTableOfContents(items)
    }

    /// The entry for the section at `href` (a `relocated` event's spine href): the first entry in
    /// that file, ignoring its fragment.
    public func currentEntryID(href: String?) -> Int? {
        guard let href else { return nil }
        let file = Self.file(href)
        return entries.first { Self.file($0.href) == file }?.id
    }

    private static func file(_ href: String) -> Substring {
        let path = href.prefix { $0 != "#" }
        return path.hasPrefix("./") ? path.dropFirst(2) : path
    }
}

/// The EPUB reader's table of contents sheet: what the page sent, where the reader is, and
/// whether the sheet is shown.
@MainActor @Observable
public final class EPUBContentsModel {
    /// `nil` until the page sends the table of contents.
    public private(set) var contents: EPUBTableOfContents?
    /// The section the reader shows, from its last `relocated` event.
    public private(set) var currentHref: String?
    public var isPresented = false

    public init() {}

    /// The entry to highlight as the current chapter.
    public var currentEntryID: Int? { contents?.currentEntryID(href: currentHref) }

    public func receive(_ contents: EPUBTableOfContents) {
        self.contents = contents
    }

    public func relocated(to href: String?) {
        currentHref = href
    }

    /// Closes the sheet.
    /// - Returns: The command that shows `entry`.
    public func select(_ entry: EPUBContentsEntry) -> EPUBBridgeCommand {
        isPresented = false
        return .display(target: entry.href)
    }
}

/// When the contents sheet scrolls to the current entry: the first time there is one once it's
/// shown, whether then or later (the book's first location can come after its contents), but not
/// again as the reader moves on while someone browses the list.
public struct EPUBContentsScroll: Sendable, Equatable {
    private var hasScrolled = false

    public init() {}

    /// The entry to scroll to now that the current one is `id`, if any.
    public mutating func target(for id: Int?) -> Int? {
        guard !hasScrolled, let id else { return nil }
        hasScrolled = true
        return id
    }
}
