import ABSCore
import SwiftUI

/// Reads a user's progress on one item. The UI kit can't see the app model's progress cache, so
/// the app injects a closure that reads it.
///
/// Cells call it inside their `body` with their own item. When the closure reads a per-key
/// `@Observable` entry (as `ProgressCache.progress(libraryItemID:episodeID:)` does), SwiftUI
/// registers that read, so only the cells showing the changed item invalidate.
public struct ItemProgressReader: Sendable {
    private let read: @MainActor @Sendable (_ itemID: String, _ episodeID: String?) -> ItemProgress?

    public init(_ read: @escaping @MainActor @Sendable (_ itemID: String, _ episodeID: String?) -> ItemProgress?) {
        self.read = read
    }

    /// Knows no progress.
    public static let none = ItemProgressReader { _, _ in nil }

    @MainActor
    public func callAsFunction(itemID: String, episodeID: String?) -> ItemProgress? {
        read(itemID, episodeID)
    }
}

extension EnvironmentValues {
    @Entry public var itemProgressReader: ItemProgressReader = .none
}

/// The words and symbols the item views share.
enum ItemPresentation {
    /// The subtitle line: the book count for a collapsed series, else the item's own.
    static func subtitle(_ item: ItemSummary) -> String? {
        if item.kind == .series, let count = item.bookCount { return bookCount(count) }
        return item.subtitle
    }

    static func bookCount(_ count: Int) -> String {
        L10n.string("SharedBookCount", count.formatted())
    }

    /// Title, subtitle, series, then "Explicit" and "Abridged" when set, as one VoiceOver label.
    static func accessibilityLabel(_ item: ItemSummary) -> String {
        [
            item.title, subtitle(item), item.seriesText,
            item.isExplicit ? L10n.string("LabelExplicit") : nil,
            item.isAbridged ? L10n.string("LabelAbridged") : nil,
        ]
        .compactMap(\.self).joined(separator: ", ")
    }

    /// The progress a cell shows: the explicit one, else the reader's. A collapsed series has none:
    /// its `itemID` is its first book, whose progress isn't the series'.
    @MainActor
    static func progress(for item: ItemSummary, explicit: ItemProgress?, reader: ItemProgressReader) -> ItemProgress? {
        guard item.kind != .series else { return nil }
        return explicit ?? reader(itemID: item.itemID, episodeID: item.episodeID)
    }

    /// "Finished", or "Progress, 42%", and "Missing" for a missing item; empty for none.
    static func accessibilityValue(_ item: ItemSummary, progress: ItemProgress?, locale: Locale) -> String {
        var parts: [String] = []
        let shown = CoverView.accessibilityValue(
            progress: progress?.isInProgress == true ? progress?.fraction : nil,
            isFinished: progress?.isFinished ?? false, locale: locale)
        if !shown.isEmpty { parts.append(shown) }
        if item.isMissing { parts.append(L10n.string("LabelMissing")) }
        return parts.joined(separator: ", ")
    }

    static func title(_ kind: ItemActionKind) -> String {
        switch kind {
        case .play: L10n.string("ButtonPlay")
        case .markFinished: L10n.string("MessageMarkAsFinished")
        case .markNotFinished: L10n.string("SharedMarkAsNotFinished")
        case .hideFromContinueListening: L10n.string("SharedHideFromContinueListening")
        case .addToPlaylist: L10n.string("LabelAddToPlaylist")
        case .share: L10n.string("ButtonShare")
        case .openDetails: L10n.string("HeaderDetails")
        }
    }

    static func systemImage(_ kind: ItemActionKind) -> String {
        switch kind {
        case .play: "play.fill"
        case .markFinished: "checkmark.circle"
        case .markNotFinished: "arrow.uturn.backward.circle"
        case .hideFromContinueListening: "eye.slash"
        case .addToPlaylist: "text.badge.plus"
        case .share: "square.and.arrow.up"
        case .openDetails: "info.circle"
        }
    }

    /// Podcasts and episodes have square covers.
    static func defaultShape(_ item: ItemSummary) -> CoverShape {
        item.kind == .podcast || item.kind == .episode ? .square : .book
    }
}

/// The pointer feedback for cards and rows: the system hover effect on iPad, a highlight on Mac.
private struct ItemHoverModifier: ViewModifier {
    #if os(macOS)
        @State private var isHovering = false
    #endif

    func body(content: Content) -> some View {
        #if os(macOS)
            content
                .padding(ABSSpacing.xSmall)
                .background(
                    RoundedRectangle(cornerRadius: ABSRadius.medium)
                        .fill(ABSColor.secondarySurface.opacity(isHovering ? 0.6 : 0))
                )
                .onHover { isHovering = $0 }
        #else
            content.hoverEffect()
        #endif
    }
}

extension View {
    func itemHover() -> some View {
        modifier(ItemHoverModifier())
    }
}

/// A red warning icon with "Missing", shown on cards and rows of missing items. Not colour alone.
struct MissingIndicator: View {
    var body: some View {
        Label {
            Text(verbatim: L10n.string("LabelMissing"))
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(ABSColor.error)
        // The cell speaks the state in its accessibility value.
        .accessibilityHidden(true)
    }
}
