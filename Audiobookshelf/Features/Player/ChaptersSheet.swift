import ABSAppModel
import ABSUI
import SwiftUI

/// The toolbar's Chapters button; disabled when the item has no chapters.
struct ChaptersSlot: View {
    let model: PlayerViewModel
    @Binding var sheet: PlayerSheet?

    var body: some View {
        Button {
            sheet = .chapters
        } label: {
            Label {
                Text(verbatim: L10n.string("HeaderChapters"))
            } icon: {
                Image(systemName: "list.bullet")
            }
        }
        .disabled(!model.hasChapters)
    }
}

/// A chapter row's text (D5): the start in media time, as the scrubber's elapsed time, and the
/// duration at the playback rate, as its remaining time.
struct ChapterRowPresentation: Equatable {
    /// The server's title, or "Chapter 3" when it's blank.
    let title: String
    let startText: String
    let durationText: String
    /// The title with the start and duration spoken in full.
    let accessibilityLabel: String

    /// - Parameters:
    ///   - position: The chapter's 1-based place in the list, to number an untitled chapter.
    ///   - rate: The playback rate; a non-finite or non-positive rate counts as `1`.
    init(row: PlayerChapterRow, position: Int, rate: Double, locale: Locale) {
        title =
            row.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? L10n.string(
                "LabelItemDetailChapterUntitled", position.formatted(.number.locale(locale)), locale: locale)
            : row.title
        let duration = row.duration / (rate.isFinite && rate > 0 ? rate : 1)
        startText = DurationStyle.timestamp.string(row.start, locale: locale)
        durationText = DurationStyle.timestamp.string(duration, locale: locale)
        accessibilityLabel = L10n.string(
            "LabelItemDetailChapterAccessibility", title,
            DurationStyle.timestamp.accessibilityString(row.start, locale: locale),
            DurationStyle.timestamp.accessibilityString(duration, locale: locale), locale: locale)
    }
}

/// The chapter list (port of `ChaptersModal.vue`): each chapter's title, start and duration, with
/// the current chapter marked and scrolled to when the sheet opens. Choosing a chapter seeks to its
/// start without changing play or pause, and closes the sheet.
struct ChaptersSheet: View {
    let model: PlayerViewModel
    let close: () -> Void
    @Environment(\.locale) private var locale
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .subheadline) private var columnWidth = 64

    var body: some View {
        let rate = model.rate
        let isAccessibilitySize = dynamicTypeSize.isAccessibilitySize
        ScrollViewReader { proxy in
            List {
                Section {
                    ForEach(model.chapters) { row in
                        ChapterRow(
                            model: model, id: row.id,
                            presentation: ChapterRowPresentation(
                                row: row, position: row.id + 1, rate: rate, locale: locale),
                            columnWidth: isAccessibilitySize ? nil : columnWidth
                        ) {
                            select(row)
                        }
                    }
                } header: {
                    if !isAccessibilitySize {
                        ChapterColumns(
                            columnWidth: columnWidth, start: L10n.string("LabelStart"),
                            duration: L10n.string("LabelDuration")
                        ) {
                            Text(verbatim: L10n.string("LabelChapters"))
                        }
                        .accessibilityHidden(true)
                    }
                }
            }
            .onAppear {
                // Read here rather than in the body, so playback ticks don't redraw the list.
                guard let current = model.currentChapterIndex else { return }
                proxy.scrollTo(current, anchor: .center)
            }
        }
        .playerSheetStyle(title: L10n.string("HeaderChapters"), onDone: close)
    }

    private func select(_ row: PlayerChapterRow) {
        Task { await model.selectChapter(row) }
        close()
    }
}

/// One chapter. It reads the playback time for its current-chapter mark, so a tick redraws only
/// the visible rows, not the list.
private struct ChapterRow: View {
    let model: PlayerViewModel
    let id: Int
    let presentation: ChapterRowPresentation
    /// The width of each time column, or `nil` to stack the times under the title.
    let columnWidth: CGFloat?
    let action: () -> Void

    var body: some View {
        let isCurrent = model.currentChapterIndex == id
        Button(action: action) {
            Group {
                if let columnWidth {
                    ChapterColumns(
                        columnWidth: columnWidth, start: presentation.startText, duration: presentation.durationText
                    ) {
                        title
                    }
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        title
                        HStack(spacing: 16) {
                            Text(verbatim: presentation.startText)
                            Text(verbatim: presentation.durationText)
                        }
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .fontWeight(isCurrent ? .semibold : nil)
        .listRowBackground(isCurrent ? ABSColor.accent.opacity(0.2) : nil)
        // On the button itself, so VoiceOver keeps its action.
        .accessibilityLabel(Text(verbatim: presentation.accessibilityLabel))
        .accessibilityValue(Text(verbatim: isCurrent ? L10n.string("LabelCurrentChapter") : ""))
    }

    private var title: some View {
        Text(verbatim: presentation.title)
            .font(.body)
            .lineLimit(3)
    }
}

/// A title followed by the start and duration columns, for the rows and the header.
private struct ChapterColumns<Title: View>: View {
    let columnWidth: CGFloat
    let start: String
    let duration: String
    @ViewBuilder let title: Title

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            title
                .frame(maxWidth: .infinity, alignment: .leading)
            Group {
                Text(verbatim: start)
                    .frame(minWidth: columnWidth, alignment: .trailing)
                Text(verbatim: duration)
                    .frame(minWidth: columnWidth, alignment: .trailing)
            }
            .font(.subheadline.monospacedDigit())
            .foregroundStyle(.secondary)
        }
    }
}

#Preview("Playing") {
    ChaptersSheet(model: .preview(at: 4_000, playing: true), close: {})
}

#Preview("Accessibility size") {
    ChaptersSheet(model: .preview(at: 4_000, playing: true), close: {})
        .dynamicTypeSize(.accessibility3)
}
