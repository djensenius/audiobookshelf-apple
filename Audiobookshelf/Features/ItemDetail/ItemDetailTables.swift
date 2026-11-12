import ABSAppModel
import ABSUI
import SwiftUI

/// The Chapters, Audio Tracks and Ebook Files sections under the description (legacy
/// `ChaptersTable.vue`, `TracksTable.vue` and `EbookFilesTable.vue`). Each is collapsed at
/// first, shows its count, and is left out when empty, as legacy (`index.vue:151-155`).
/// Tapping a chapter asks ``ItemDetailContent`` to confirm and play it; tracks and ebook files
/// are display only.
struct ItemDetailTables: View {
    let model: ItemDetailModel
    let bookTitle: String
    /// Chapters can be played now: the book has audio, there's a `playItem` action, and the item
    /// isn't gone or starting.
    let canPlayChapters: Bool
    /// The chapter, and the confirmation for its ``ItemDetailModel/startTime(for:)``.
    let selectChapter: (ItemDetailModel.ChapterRow, ItemDetailChapterPresentation) -> Void
    @Environment(\.locale) private var locale

    var body: some View {
        VStack(alignment: .leading, spacing: ABSSpacing.medium) {
            if !model.chapters.isEmpty {
                ItemDetailTableSection(titleKey: "HeaderChapters", count: model.chapters.count) {
                    ItemDetailTableHeader(keys: ["LabelTitle", "LabelStart", "LabelDuration"])
                    // Row IDs are positions, since the server's IDs may repeat.
                    ForEach(model.chapters) { chapter in
                        let presentation = ItemDetailChapterPresentation(
                            chapter: chapter, position: chapter.id + 1, bookTitle: bookTitle,
                            playbackStart: model.startTime(for: chapter), locale: locale)
                        ItemDetailChapterRow(presentation: presentation, isEnabled: canPlayChapters) {
                            selectChapter(chapter, presentation)
                        }
                    }
                }
            }
            if !model.tracks.isEmpty {
                ItemDetailTableSection(titleKey: "HeaderAudioTracks", count: model.tracks.count) {
                    ItemDetailTableHeader(keys: ["LabelFilename", "LabelDuration"])
                    ForEach(model.tracks) { track in
                        ItemDetailTableRow(
                            title: track.name ?? L10n.string("LabelUnknown"),
                            values: [DurationStyle.timestamp.string(track.duration, locale: locale)],
                            spokenValues: [DurationStyle.timestamp.accessibilityString(track.duration, locale: locale)])
                    }
                }
            }
            if !model.ebookFiles.isEmpty {
                ItemDetailTableSection(titleKey: "HeaderEbookFiles", count: model.ebookFiles.count) {
                    ItemDetailTableHeader(keys: ["LabelFilename", "LabelSize"])
                    ForEach(model.ebookFiles) { file in
                        ItemDetailEbookFileRow(file: file)
                    }
                }
            }
        }
    }
}

/// A collapsed section with its title and count, and its rows in a lazy stack, since a book can
/// have hundreds of chapters.
private struct ItemDetailTableSection<Content: View>: View {
    let titleKey: String
    let count: Int
    @ViewBuilder let content: Content
    @Environment(\.locale) private var locale

    var body: some View {
        DisclosureGroup {
            LazyVStack(alignment: .leading, spacing: 0) {
                content
            }
            .padding(.top, ABSSpacing.small)
        } label: {
            HStack(spacing: ABSSpacing.small) {
                Text(verbatim: L10n.string(titleKey))
                    .font(.headline)
                    .foregroundStyle(ABSColor.foreground)
                Text(verbatim: count.formatted(.number.locale(locale)))
                    .font(.caption.monospacedDigit())
                    .padding(.horizontal, ABSSpacing.small)
                    .padding(.vertical, ABSSpacing.xxSmall)
                    .background(ABSColor.border, in: .capsule)
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
        }
        .padding(ABSSpacing.medium)
        .background(ABSColor.secondarySurface, in: .rect(cornerRadius: ABSRadius.medium))
    }
}

/// The column titles; VoiceOver reads each row's own label instead. Left out at accessibility
/// text sizes, where rows stack their values under the title.
private struct ItemDetailTableHeader: View {
    /// `L10n` keys; the first is the leading column.
    let keys: [String]
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        if !dynamicTypeSize.isAccessibilitySize {
            ItemDetailTableColumns(values: keys.dropFirst().map { L10n.string($0) }) {
                Text(verbatim: L10n.string(keys[0]))
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(ABSColor.mutedForeground)
            .accessibilityHidden(true)
        }
    }
}

/// The leading content, then the values in columns that scale with the text size. At
/// accessibility sizes the values go under the leading content instead.
private struct ItemDetailTableColumns<Leading: View>: View {
    let values: [String]
    var underlinesFirstValue = false
    @ViewBuilder let leading: Leading
    @ScaledMetric(relativeTo: .subheadline) private var columnWidth: CGFloat = 64
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let isStacked = dynamicTypeSize.isAccessibilitySize
        let layout =
            isStacked
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: ABSSpacing.xxSmall))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: ABSSpacing.small))
        layout {
            leading
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(alignment: .firstTextBaseline, spacing: ABSSpacing.small) {
                ForEach(Array(values.enumerated()), id: \.offset) { offset, value in
                    Text(verbatim: value)
                        .underline(underlinesFirstValue && offset == 0)
                        .monospacedDigit()
                        .frame(minWidth: isStacked ? nil : columnWidth, alignment: isStacked ? .leading : .trailing)
                }
            }
        }
        .padding(.vertical, ABSSpacing.xSmall)
    }
}

/// A row of text. VoiceOver reads the title and `spokenValues` when given, else the visible
/// text.
private struct ItemDetailTableRow: View {
    let title: String
    let values: [String]
    /// The values as VoiceOver should say them, such as durations in full.
    var spokenValues: [String]?

    var body: some View {
        let row = ItemDetailTableColumns(values: values) {
            Text(verbatim: title)
        }
        .font(.subheadline)
        if let spokenValues {
            row
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(verbatim: title))
                .accessibilityValue(Text(verbatim: spokenValues.joined(separator: ", ")))
        } else {
            row.accessibilityElement(children: .combine)
        }
    }
}

/// A chapter, which asks to play from its start.
private struct ItemDetailChapterRow: View {
    let presentation: ItemDetailChapterPresentation
    let isEnabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ItemDetailTableColumns(
                values: [presentation.startText, presentation.durationText], underlinesFirstValue: isEnabled
            ) {
                Text(verbatim: presentation.title)
            }
            .font(.subheadline)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        // On the button itself, so VoiceOver keeps its action.
        .accessibilityLabel(Text(verbatim: presentation.accessibilityLabel))
        .accessibilityHint(Text(verbatim: isEnabled ? L10n.string("LabelItemDetailPlayChapterHint") : ""))
    }
}

/// An ebook file: its name, a mark on the primary one, and its size.
private struct ItemDetailEbookFileRow: View {
    let file: ItemDetailModel.EbookFileRow
    @Environment(\.locale) private var locale

    var body: some View {
        let name = file.filename.isEmpty ? L10n.string("LabelUnknown") : file.filename
        ItemDetailTableColumns(
            values: [file.size.map { Int64($0).formatted(.byteCount(style: .file).locale(locale)) } ?? ""]
        ) {
            HStack(alignment: .firstTextBaseline, spacing: ABSSpacing.xSmall) {
                Text(verbatim: name)
                if file.isPrimary {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(ABSColor.success)
                        .accessibilityLabel(Text(verbatim: L10n.string("LabelItemDetailPrimaryEbook")))
                }
            }
        }
        .font(.subheadline)
        .accessibilityElement(children: .combine)
    }
}
