import ABSAppModel
import ABSCore
import ABSPlayback
import ABSUI
import SwiftUI

extension EnvironmentValues {
    /// The running account session's play queue; `nil` between sessions (``PlaybackEnvironment``).
    @Entry var playbackQueue: PlaybackQueueControl?
}

/// The full player's Up Next button, which presents ``QueueSheet``. Disabled between sessions.
struct QueueSlot: View {
    @Binding var sheet: PlayerSheet?
    @Environment(\.playbackQueue) private var queue

    var body: some View {
        Button {
            sheet = .queue
        } label: {
            Label {
                Text(verbatim: L10n.string("HeaderUpNext"))
            } icon: {
                Image(systemName: "list.bullet")
            }
        }
        .disabled(queue == nil)
    }
}

/// The queue as one of the full player's sheets (``PlayerSheet/queue``).
struct QueueSheet: View {
    let close: () -> Void

    var body: some View {
        QueueList()
            .playerSheetStyle(title: L10n.string("HeaderUpNext"), onDone: close)
    }
}

/// The queue panel next to the browsing content (ADR 0004): ``PlayerSlot``'s inspector, which
/// compact width shows as a sheet. Whether it's open is the scene's
/// `Router/isQueueInspectorPresented`.
struct QueueInspector: View {
    let router: Router

    var body: some View {
        NavigationStack {
            QueueList()
                .navigationTitle(Text(verbatim: L10n.string("HeaderUpNext")))
                #if os(iOS)
                    .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button {
                            router.isQueueInspectorPresented = false
                        } label: {
                            Text(verbatim: L10n.string("ButtonDone"))
                        }
                    }
                }
        }
        .inspectorColumnWidth(min: 280, ideal: 340, max: 480)
    }
}

/// The running session's queue (`\.playbackQueue`) as ``QueueContent``: its changes go to the
/// queue, and a tap plays the row through `\.playItem`, which takes it out of the queue once its
/// session starts. A play that fails shows an alert and leaves the row queued.
struct QueueList: View {
    @Environment(\.playbackQueue) private var queue
    @Environment(\.playItem) private var playItem
    @State private var playFailed = false

    var body: some View {
        let queue = queue
        QueueContent(
            rows: queue.map(QueueRow.rows(of:)) ?? [],
            canPlay: playItem != nil,
            play: play,
            remove: { queue?.remove(id: $0) },
            removeOffsets: { queue?.remove(atOffsets: $0) },
            move: { queue?.move(fromOffsets: $0, toOffset: $1) },
            clear: { queue?.clear() }
        )
        .alert(Text(verbatim: L10n.string("MessagePlaybackStartFailed")), isPresented: $playFailed) {
            Button(role: .cancel) {
            } label: {
                Text(verbatim: L10n.string("ButtonOk"))
            }
        }
    }

    private func play(_ row: QueueRow) {
        guard let playItem else { return }
        Task {
            do {
                try await row.play(with: playItem)
            } catch {
                playFailed = true
            }
        }
    }
}

/// The queue's rows, with swipe or context-menu removal, drag to reorder and Clear (after a
/// confirmation); an empty queue says so. Has no model, so previews pass rows and no-op actions.
struct QueueContent: View {
    let rows: [QueueRow]
    /// Whether tapping a row plays it; `false` between sessions.
    let canPlay: Bool
    let play: (QueueRow) -> Void
    let remove: (QueueRow.ID) -> Void
    let removeOffsets: (IndexSet) -> Void
    let move: (IndexSet, Int) -> Void
    let clear: () -> Void
    @State private var confirmsClear = false

    var body: some View {
        Group {
            if rows.isEmpty {
                ContentUnavailableView {
                    Label {
                        Text(verbatim: L10n.string("MessageQueueEmpty"))
                    } icon: {
                        Image(systemName: "list.bullet")
                    }
                }
            } else {
                list
            }
        }
        .toolbar {
            #if os(iOS)
                ToolbarItem(placement: .topBarLeading) {
                    if !rows.isEmpty { EditButton() }
                }
            #endif
            ToolbarItem(placement: .destructiveAction) {
                Button(role: .destructive) {
                    confirmsClear = true
                } label: {
                    Text(verbatim: L10n.string("ButtonClearQueue"))
                }
                .disabled(rows.isEmpty)
            }
        }
        .confirmationDialog(
            Text(verbatim: L10n.string("MessageConfirmClearQueue")), isPresented: $confirmsClear,
            titleVisibility: .visible
        ) {
            Button(role: .destructive, action: clear) {
                Text(verbatim: L10n.string("ButtonClearQueue"))
            }
        }
    }

    private var list: some View {
        List {
            ForEach(rows) { row in
                Button {
                    play(row)
                } label: {
                    QueueRowView(row: row)
                }
                .buttonStyle(.plain)
                .disabled(!canPlay)
                .accessibilityHint(Text(verbatim: canPlay ? L10n.string("LabelPlayQueueItemHint") : ""))
                .contextMenu {
                    Button(role: .destructive) {
                        remove(row.id)
                    } label: {
                        Label {
                            Text(verbatim: L10n.string("ButtonRemove"))
                        } icon: {
                            Image(systemName: "trash")
                        }
                    }
                }
                .accessibilityAction(named: Text(verbatim: L10n.string("ButtonRemove"))) {
                    remove(row.id)
                }
            }
            .onDelete(perform: removeOffsets)
            .onMove(perform: move)
        }
    }
}

/// A queued item: its cover, title, subtitle and duration, read by VoiceOver as one element. At
/// accessibility text sizes the cover goes, so the text keeps its room.
private struct QueueRowView: View {
    let row: QueueRow
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .body) private var coverHeight: CGFloat = 48
    private var libraries = LibraryCoverSettings()

    init(row: QueueRow) {
        self.row = row
    }

    var body: some View {
        HStack(spacing: 12) {
            if !dynamicTypeSize.isAccessibilitySize {
                CoverView(
                    key: row.coverKey, title: row.title, author: row.subtitle,
                    shape: CoverShape(isPodcast: row.isPodcastEpisode, librarySettings: libraries.current),
                    accessibility: .hidden
                )
                .frame(height: coverHeight)
                .clipShape(.rect(cornerRadius: 4))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: row.title)
                    .lineLimit(2)
                if let subtitle = row.subtitle {
                    Text(verbatim: subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if let duration = row.duration {
                    DurationText(seconds: duration, style: .elapsed(showSeconds: false))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(minHeight: 44)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }
}

#if DEBUG
    extension QueueRow {
        fileprivate static let previews = [
            QueueItem(
                libraryItemID: "book", title: "The Hobbit", subtitle: "J. R. R. Tolkien", duration: 40_000),
            QueueItem(
                libraryItemID: "podcast", episodeID: "episode", title: "A long episode title that wraps onto two lines",
                subtitle: "A Podcast", duration: 3_725),
            QueueItem(libraryItemID: "other", title: "No details"),
        ].map { QueueRow(item: $0, serverConnectionID: UUID()) }
    }

    #Preview("Queue") {
        NavigationStack {
            QueueContent(
                rows: QueueRow.previews, canPlay: true, play: { _ in }, remove: { _ in }, removeOffsets: { _ in },
                move: { _, _ in }, clear: {})
        }
    }

    #Preview("Empty") {
        NavigationStack {
            QueueContent(
                rows: [], canPlay: false, play: { _ in }, remove: { _ in }, removeOffsets: { _ in },
                move: { _, _ in }, clear: {})
        }
    }

    #Preview("Accessibility size") {
        NavigationStack {
            QueueContent(
                rows: QueueRow.previews, canPlay: true, play: { _ in }, remove: { _ in }, removeOffsets: { _ in },
                move: { _, _ in }, clear: {})
        }
        .dynamicTypeSize(.accessibility3)
    }
#endif
