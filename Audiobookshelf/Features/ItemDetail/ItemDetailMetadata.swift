import ABSAppModel
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
            add("LabelSize", [.text(Int64(size).formatted(.byteCount(style: .file).locale(locale)))])
        }
        return rows
    }
}

/// The metadata rows: labels beside their values, or above them at accessibility text sizes.
struct ItemDetailMetadata: View {
    let details: ItemDetailModel.Details
    @Environment(\.locale) private var locale
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let rows = ItemDetailMetadataRow.rows(for: details, locale: locale)
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: ABSSpacing.medium) {
                ForEach(rows) { row in
                    VStack(alignment: .leading, spacing: ABSSpacing.xxSmall) {
                        label(row)
                        values(row)
                    }
                }
            }
        } else {
            Grid(alignment: .topLeading, horizontalSpacing: ABSSpacing.large, verticalSpacing: ABSSpacing.small) {
                ForEach(rows) { row in
                    // Modifiers go on the cells: on a `GridRow` they'd make it one cell.
                    GridRow {
                        label(row)
                        values(row)
                    }
                }
            }
        }
    }

    /// Hidden from VoiceOver: ``values(_:)`` speaks it with each value, since VoiceOver often
    /// skips a container's label.
    private func label(_ row: ItemDetailMetadataRow) -> some View {
        Text(verbatim: L10n.string(row.labelKey))
            .font(.subheadline)
            .foregroundStyle(ABSColor.mutedForeground)
            .accessibilityHidden(true)
    }

    @ViewBuilder private func values(_ row: ItemDetailMetadataRow) -> some View {
        let label = Text(verbatim: L10n.string(row.labelKey))
        let layout = ItemDetailFlowLayout(spacing: ABSSpacing.small) {
            // By position: a book can list the same name twice.
            ForEach(Array(row.values.enumerated()), id: \.offset) { _, value in
                switch value {
                case .text(let text, let spoken):
                    Text(verbatim: text)
                        .accessibilityLabel(Text(verbatim: spoken ?? text))
                case .link(let name, let route):
                    NavigationLink(value: route) {
                        Text(verbatim: name)
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
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(label)
                .accessibilityValue(Text(verbatim: spoken))
        } else {
            layout
        }
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
