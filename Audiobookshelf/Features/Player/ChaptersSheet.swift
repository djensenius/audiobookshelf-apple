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

/// A chapter row's text (D5). The start is in media time, as the scrubber's elapsed time shows the
/// position over the whole item, so a row's start is what the player shows on reaching it; the
/// duration is at the playback rate, as the scrubber's remaining time.
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
/// start without changing play or pause, and closes the sheet. Without chapters (the item changed
/// while it was open) it says so.
struct ChaptersSheet: View {
    let model: PlayerViewModel
    let close: () -> Void
    @Environment(\.locale) private var locale

    var body: some View {
        let rate = model.rate
        let chapters = model.chapters.map {
            ChaptersList.Entry(
                row: $0, presentation: ChapterRowPresentation(row: $0, position: $0.id + 1, rate: rate, locale: locale))
        }
        Group {
            if chapters.isEmpty {
                ContentUnavailableView {
                    Label {
                        Text(verbatim: L10n.string("MessageNoChapters"))
                    } icon: {
                        Image(systemName: "list.bullet")
                    }
                }
            } else {
                ChaptersList(model: model, chapters: chapters, close: close)
            }
        }
        .playerSheetStyle(title: L10n.string("HeaderChapters"), onDone: close)
    }
}

/// The list itself. It reads the playback time once per tick for the current chapter and passes
/// each row whether it's current, so a tick redraws only the rows whose mark changed.
private struct ChaptersList: View {
    struct Entry {
        let row: PlayerChapterRow
        let presentation: ChapterRowPresentation
    }

    let model: PlayerViewModel
    let chapters: [Entry]
    let close: () -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .subheadline) private var columnWidth = 64

    var body: some View {
        let current = model.currentChapterIndex
        let isAccessibilitySize = dynamicTypeSize.isAccessibilitySize
        ScrollViewReader { proxy in
            List {
                Section {
                    ForEach(chapters, id: \.row.id) { entry in
                        ChapterRow(
                            row: entry.row, presentation: entry.presentation, isCurrent: entry.row.id == current,
                            columnWidth: isAccessibilitySize ? nil : columnWidth
                        ) {
                            select(entry.row)
                        }
                        .equatable()
                    }
                } header: {
                    if !isAccessibilitySize {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            ChapterColumns(
                                columnWidth: columnWidth, start: L10n.string("LabelStart"),
                                duration: L10n.string("LabelDuration")
                            ) {
                                Text(verbatim: L10n.string("LabelChapters"))
                            }
                            // Lines the columns up with the rows' current-chapter checkmark.
                            Image(systemName: "checkmark").hidden()
                        }
                        .accessibilityHidden(true)
                    }
                }
            }
            .task {
                // A turn later, once the list in the presented sheet has laid out its rows.
                await Task.yield()
                guard let current = model.currentChapterIndex else { return }
                proxy.scrollTo(current, anchor: .center)
            }
        }
    }

    private func select(_ row: PlayerChapterRow) {
        Task { await model.selectChapter(row) }
        close()
    }
}

/// One chapter. Equatable without its action, so a tick that doesn't change its inputs skips it.
private struct ChapterRow: View, Equatable {
    /// What the action seeks to. Part of equality, so a row reused after the item changed (same
    /// text, another exact start) never keeps the old action.
    let row: PlayerChapterRow
    let presentation: ChapterRowPresentation
    let isCurrent: Bool
    /// The width of each time column, or `nil` to stack the times under the title.
    let columnWidth: CGFloat?
    let action: () -> Void

    nonisolated static func == (lhs: ChapterRow, rhs: ChapterRow) -> Bool {
        lhs.row == rhs.row && lhs.presentation == rhs.presentation && lhs.isCurrent == rhs.isCurrent
            && lhs.columnWidth == rhs.columnWidth
    }

    var body: some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Group {
                    if let columnWidth {
                        ChapterColumns(
                            columnWidth: columnWidth, start: presentation.startText,
                            duration: presentation.durationText
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
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "checkmark")
                    .foregroundStyle(ABSColor.accent)
                    .opacity(isCurrent ? 1 : 0)
                    .accessibilityHidden(true)
            }
            .frame(minHeight: 44)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .fontWeight(isCurrent ? .semibold : nil)
        .listRowBackground(isCurrent ? ABSColor.accent.opacity(0.2) : nil)
        // On the button itself, so VoiceOver keeps its action.
        .accessibilityLabel(Text(verbatim: presentation.accessibilityLabel))
        .accessibilityValue(Text(verbatim: isCurrent ? L10n.string("LabelCurrentChapter") : ""))
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
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

#Preview("No chapters") {
    ChaptersSheet(model: .preview(loaded: false), close: {})
}

#Preview("Accessibility size") {
    ChaptersSheet(model: .preview(at: 4_000, playing: true), close: {})
        .dynamicTypeSize(.accessibility3)
}
