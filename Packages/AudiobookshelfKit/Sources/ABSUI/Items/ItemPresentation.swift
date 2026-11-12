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

    /// "1 book", "12 books".
    static func bookCount(_ count: Int, locale: Locale? = nil) -> String {
        L10n.plural("SharedBookCount", count: count, locale: locale)
    }

    /// Title, subtitle (author or narrator, or a collapsed series' book count) and series, as one
    /// VoiceOver label. Badges and progress are states, spoken in ``accessibilityValue(_:progress:locale:)``.
    static func accessibilityLabel(_ item: ItemSummary) -> String {
        [item.title, subtitle(item), item.seriesText].compactMap(\.self).joined(separator: ", ")
    }

    /// The row is one accessibility element, so include its spoken duration in the label.
    static func rowAccessibilityLabel(_ item: ItemSummary, locale: Locale) -> String {
        let label = accessibilityLabel(item)
        guard let duration = item.duration else { return label }
        let spokenDuration = DurationStyle.elapsed(showSeconds: false).accessibilityString(duration, locale: locale)
        guard !spokenDuration.isEmpty else { return label }
        return "\(label), \(spokenDuration)"
    }

    /// The progress a cell shows: the explicit one, else the reader's. A collapsed series has none:
    /// its `itemID` is its first book, whose progress isn't the series'.
    @MainActor
    static func progress(for item: ItemSummary, explicit: ItemProgress?, reader: ItemProgressReader) -> ItemProgress? {
        guard item.kind != .series else { return nil }
        return explicit ?? reader(itemID: item.itemID, episodeID: item.episodeID)
    }

    /// The cell's states, as its VoiceOver value: "Finished" or "Progress, 42%", then the badges
    /// ("Explicit", "Abridged") and "Missing"; empty for none.
    static func accessibilityValue(_ item: ItemSummary, progress: ItemProgress?, locale: Locale) -> String {
        var parts: [String] = []
        let shown = CoverView.accessibilityValue(
            progress: progress?.isInProgress == true ? progress?.fraction : nil,
            isFinished: progress?.isFinished ?? false, locale: locale)
        if !shown.isEmpty { parts.append(shown) }
        if item.isExplicit { parts.append(L10n.string("LabelExplicit")) }
        if item.isAbridged { parts.append(L10n.string("LabelAbridged")) }
        if item.isMissing { parts.append(L10n.string("LabelMissing")) }
        return parts.joined(separator: ", ")
    }

    /// A series card's label: name and book count.
    static func accessibilityLabel(_ series: SeriesSummary, locale: Locale? = nil) -> String {
        "\(series.name), \(bookCount(series.bookCount, locale: locale))"
    }

    /// An author card's label: name and, when known, book count.
    static func accessibilityLabel(_ author: AuthorSummary, locale: Locale? = nil) -> String {
        [author.name, author.bookCount.map { bookCount($0, locale: locale) }].compactMap(\.self)
            .joined(separator: ", ")
    }

    /// A shelf's "Show All" button names its shelf, so a list of buttons tells them apart.
    static func showAllAccessibilityLabel(shelfTitle: String) -> String {
        "\(L10n.string("LabelShowAll")), \(shelfTitle)"
    }

    /// A ``ProgressBadge``'s VoiceOver value: "Finished", "42%", or `nil` when it shows nothing.
    static func progressBadgeValue(_ progress: ItemProgress?, locale: Locale) -> String? {
        guard let progress else { return nil }
        if progress.isFinished { return L10n.string("LabelFinished") }
        return progress.isInProgress ? progressAccessibilityValue(progress.fraction, locale: locale) : nil
    }

    /// Whether a card adds a check to its finished cover: its green bar alone tells finished
    /// from almost finished by colour.
    static func showsFinishedCheck(_ progress: ItemProgress?, differentiateWithoutColor: Bool) -> Bool {
        differentiateWithoutColor && progress?.isFinished == true
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
    /// The pointer feedback of ABSUI's cards and rows, for app cards that sit beside them.
    public func itemHover() -> some View {
        modifier(ItemHoverModifier())
    }
}

/// A red warning icon with "Missing", shown on cards and rows of missing items. Not colour alone.
struct MissingIndicator: View {
    var body: some View {
        Label {
            // Text uses the secondary label colour for contrast; the icon carries the red.
            Text(verbatim: L10n.string("LabelMissing"))
                .foregroundStyle(.secondary)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(ABSColor.error)
        }
        .font(.caption.weight(.semibold))
        // The cell speaks the state in its accessibility value.
        .accessibilityHidden(true)
    }
}
