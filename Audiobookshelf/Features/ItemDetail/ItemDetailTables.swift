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
    let selectChapter: (ItemDetailModel.ChapterRow, ItemDetailChapterPresentation) -> Void
    @Environment(\.locale) private var locale

    var body: some View {
        VStack(alignment: .leading, spacing: ABSSpacing.medium) {
            if !model.chapters.isEmpty {
                ItemDetailTableSection(titleKey: "HeaderChapters", count: model.chapters.count) {
                    ItemDetailTableHeader(keys: ["LabelTitle", "LabelStart", "LabelDuration"])
                    ForEach(Array(model.chapters.enumerated()), id: \.element.id) { offset, chapter in
                        let presentation = ItemDetailChapterPresentation(
                            chapter: chapter, position: offset + 1, bookTitle: bookTitle, locale: locale)
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
                            values: [DurationStyle.timestamp.string(track.duration, locale: locale)])
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

/// The column titles; VoiceOver reads each row's own label instead.
private struct ItemDetailTableHeader: View {
    /// `L10n` keys; the first is the leading column.
    let keys: [String]

    var body: some View {
        ItemDetailTableRow(title: L10n.string(keys[0]), values: keys.dropFirst().map { L10n.string($0) })
            .font(.caption.weight(.semibold))
            .foregroundStyle(ABSColor.mutedForeground)
            .accessibilityHidden(true)
    }
}

/// A row: the leading text, then fixed-width values.
private struct ItemDetailTableRow: View {
    let title: String
    let values: [String]

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: ABSSpacing.small) {
            Text(verbatim: title)
                .frame(maxWidth: .infinity, alignment: .leading)
            ForEach(Array(values.enumerated()), id: \.offset) { _, value in
                Text(verbatim: value)
                    .monospacedDigit()
                    .frame(minWidth: 64, alignment: .trailing)
            }
        }
        .font(.subheadline)
        .padding(.vertical, ABSSpacing.xSmall)
        .accessibilityElement(children: .combine)
    }
}

/// A chapter, which asks to play from its start.
private struct ItemDetailChapterRow: View {
    let presentation: ItemDetailChapterPresentation
    let isEnabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: ABSSpacing.small) {
                Text(verbatim: presentation.title)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(verbatim: presentation.startText)
                    .underline(isEnabled)
                    .frame(minWidth: 64, alignment: .trailing)
                Text(verbatim: presentation.durationText)
                    .frame(minWidth: 64, alignment: .trailing)
            }
            .monospacedDigit()
            .font(.subheadline)
            .padding(.vertical, ABSSpacing.xSmall)
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
        HStack(alignment: .firstTextBaseline, spacing: ABSSpacing.small) {
            HStack(alignment: .firstTextBaseline, spacing: ABSSpacing.xSmall) {
                Text(verbatim: name)
                if file.isPrimary {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(ABSColor.success)
                        .accessibilityLabel(Text(verbatim: L10n.string("LabelItemDetailPrimaryEbook")))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(verbatim: file.size.map { Int64($0).formatted(.byteCount(style: .file).locale(locale)) } ?? "")
                .monospacedDigit()
                .frame(minWidth: 64, alignment: .trailing)
        }
        .font(.subheadline)
        .padding(.vertical, ABSSpacing.xSmall)
        .accessibilityElement(children: .combine)
    }
}
