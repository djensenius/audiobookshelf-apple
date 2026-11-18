import ABSAppModel
import ABSCore
import ABSUI
import SwiftUI

/// One row of the book's metadata (legacy `index.vue` `#metadata`): a label and its values,
/// some of them links. Built apart from the view so the links and formatting can be tested.
struct ItemDetailMetadataRow: Identifiable, Equatable {
    enum Value: Hashable {
        /// Plain text, with what VoiceOver reads instead when it differs.
        case text(String, spoken: String? = nil)
        /// A name that opens `route`.
        case link(String, Route)
    }

    /// The `L10n` key of the label; unique per row.
    let labelKey: String
    let values: [Value]

    var id: String { labelKey }

    /// What VoiceOver reads after the label when every value is text; `nil` when the row has
    /// links, which each speak for themselves.
    var spokenText: String? {
        var spoken: [String] = []
        for value in values {
            guard case .text(let text, let alternative) = value else { return nil }
            spoken.append(alternative ?? text)
        }
        return spoken.joined(separator: ", ")
    }

    /// The rows for `details`, in legacy order; rows without a value are left out. Narrators,
    /// genres and tags open the library filtered by them; authors and series open their pages.
    static func rows(for details: ItemDetailModel.Details, locale: Locale) -> [ItemDetailMetadataRow] {
        var rows: [ItemDetailMetadataRow] = []
        func add(_ labelKey: String, _ values: [Value]) {
            if !values.isEmpty { rows.append(ItemDetailMetadataRow(labelKey: labelKey, values: values)) }
        }
        add(
            details.authors.count == 1 ? "LabelAuthor" : "LabelAuthors",
            details.authors.map { .link($0.name, .author(id: $0.id)) })
        add("LabelSeries", details.series.map { .link($0.text, .series(id: $0.id)) })
        if let duration = details.duration {
            let style = DurationStyle.elapsed(showSeconds: false)
            let text = style.string(duration, locale: locale)
            if !text.isEmpty {
                add("LabelDuration", [.text(text, spoken: style.accessibilityString(duration, locale: locale))])
            }
        }
        add(
            details.narrators.count == 1 ? "LabelNarrator" : "LabelNarrators",
            details.narrators.map { .link($0, .libraryFilter(kind: .narrators, value: $0)) })
        add("LabelGenres", details.genres.map { .link($0, .libraryFilter(kind: .genres, value: $0)) })
        add("LabelTags", details.tags.map { .link($0, .libraryFilter(kind: .tags, value: $0)) })
        add("LabelItemDetailPublisher", details.publisher.map { [.text($0)] } ?? [])
        add("LabelPublishYear", details.year.map { [.text($0)] } ?? [])
        add("LabelLanguage", details.language.map { [.text($0)] } ?? [])
        if let size = details.size, size > 0 {
            add("LabelSize", [.text(ByteCountFormatting.string(fromBytes: Int64(size), locale: locale))])
        }
        return rows
    }
}

/// The metadata rows: labels beside their values, or above them at accessibility text sizes.
/// Shows a book's details, or rows built elsewhere, such as a podcast's.
///
/// Each link, and each plain value, is at least 44 points tall, the minimum hit target (#612); in
/// the grid the labels are padded the same way, so each row's text lines up.
struct ItemDetailMetadata: View {
    private enum Source {
        case details(ItemDetailModel.Details)
        case rows([ItemDetailMetadataRow])
    }

    private let source: Source
    @Environment(\.locale) private var locale
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    init(rows: [ItemDetailMetadataRow]) {
        source = .rows(rows)
    }

    /// The rows of `details` (``ItemDetailMetadataRow/rows(for:locale:)``) in the environment's
    /// locale.
    init(details: ItemDetailModel.Details) {
        source = .details(details)
    }

    var body: some View {
        let rows =
            switch source {
            case .details(let details): ItemDetailMetadataRow.rows(for: details, locale: locale)
            case .rows(let rows): rows
            }
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: ABSSpacing.medium) {
                    ForEach(rows) { row in
                        VStack(alignment: .leading, spacing: ABSSpacing.xxSmall) {
                            label(row, padded: false)
                            values(row, padded: false)
                        }
                    }
                }
            } else {
                // No spacing: the cells' padding spaces the rows.
                Grid(alignment: .topLeading, horizontalSpacing: ABSSpacing.large, verticalSpacing: 0) {
                    ForEach(rows) { row in
                        // Modifiers go on the cells: on a `GridRow` they'd make it one cell.
                        GridRow {
                            label(row, padded: true)
                            values(row, padded: true)
                        }
                    }
                }
            }
        }
        // For UI tests.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("item.metadata")
    }

    /// Hidden from VoiceOver: ``values(_:)`` speaks it with each value, since VoiceOver often
    /// skips a container's label.
    private func label(_ row: ItemDetailMetadataRow, padded: Bool) -> some View {
        Text(verbatim: L10n.string(row.labelKey))
            .font(.subheadline)
            .foregroundStyle(ABSColor.mutedForeground)
            .modifier(HitTargetHeight(padded: padded))
            .accessibilityHidden(true)
    }

    /// - Parameter padded: Pads each value as ``HitTargetHeight`` does, as the grid's labels are.
    @ViewBuilder private func values(_ row: ItemDetailMetadataRow, padded: Bool) -> some View {
        let label = Text(verbatim: L10n.string(row.labelKey))
        let layout = ItemDetailFlowLayout(spacing: ABSSpacing.small) {
            // By position: a book can list the same name twice.
            ForEach(Array(row.values.enumerated()), id: \.offset) { _, value in
                switch value {
                case .text(let text, let spoken):
                    Text(verbatim: text)
                        .modifier(HitTargetHeight(padded: padded))
                        .accessibilityLabel(Text(verbatim: spoken ?? text))
                case .link(let name, let route):
                    NavigationLink(value: route) {
                        Text(verbatim: name)
                            .modifier(HitTargetHeight(padded: padded))
                            .frame(minWidth: HitTargetHeight.minimum, alignment: .leading)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.borderless)
                    // "Grover Gardner, Narrators, link".
                    .accessibilityValue(label)
                }
            }
        }
        .font(.subheadline)
        .frame(maxWidth: .infinity, alignment: .leading)
        if let spoken = row.spokenText {
            // One element: "Duration, 9 hours 6 minutes".
            layout
                .contentShape(.accessibility, .rect)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(label)
                .accessibilityValue(Text(verbatim: spoken))
        } else {
            layout
        }
    }
}

/// Makes a metadata cell at least 44 points tall, the minimum hit target. Padded, a line of text at
/// the default size is just that tall, and cells beside each other line up whatever their heights.
private struct HitTargetHeight: ViewModifier {
    static let minimum: CGFloat = 44
    /// Centers a line of `.subheadline` text, about 20 points tall at the default size, in 44.
    static let inset: CGFloat = 12
    var padded: Bool

    func body(content: Content) -> some View {
        content
            .padding(.vertical, padded ? Self.inset : 0)
            .frame(minHeight: Self.minimum)
    }
}

/// Lays its subviews out left to right, wrapping onto new lines when they don't fit.
struct ItemDetailFlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(maxWidth: proposal.width ?? .infinity, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let frames = arrange(maxWidth: bounds.width, subviews: subviews).frames
        for (subview, frame) in zip(subviews, frames) {
            subview.place(
                at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                proposal: ProposedViewSize(frame.size))
        }
    }

    private func arrange(maxWidth: CGFloat, subviews: Subviews) -> (frames: [CGRect], size: CGSize) {
        var frames: [CGRect] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0
        var width: CGFloat = 0
        for subview in subviews {
            var size = subview.sizeThatFits(.unspecified)
            if size.width > maxWidth {
                // Too long for a line of its own: let it wrap.
                size = subview.sizeThatFits(ProposedViewSize(width: maxWidth, height: nil))
            }
            if x > 0, x + size.width > maxWidth {
                x = 0
                y += lineHeight + spacing
                lineHeight = 0
            }
            frames.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
            width = max(width, x + size.width)
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
        return (frames, CGSize(width: width, height: y + lineHeight))
    }
}
