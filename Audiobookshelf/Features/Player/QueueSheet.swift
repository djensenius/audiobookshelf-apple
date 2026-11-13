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

/// The queue as one of the full player's sheets (``PlayerSheet/queue``). While it's up, it shows
/// the player's failures, such as a queued item that fails to play, instead of the window under it
/// (``SwiftUICore/View/playerErrorAlertLayer(player:)``).
struct QueueSheet: View {
    let model: PlayerViewModel
    let close: () -> Void

    var body: some View {
        QueueList()
            .playerSheetStyle(title: L10n.string("HeaderUpNext"), onDone: close)
            .playerErrorAlertLayer(player: model)
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
/// session starts. A play that fails leaves the row queued; the player reports the failure
/// (`errorMessageKey`), which the presenting ``QueueSheet`` or ``QueueInspector`` layer shows, or,
/// in ``PlayerDetailsPane``, the full player around it.
struct QueueList: View {
    private let controls: QueueContent.Controls
    @Environment(\.playbackQueue) private var queue
    @Environment(\.playItem) private var playItem

    init(controls: QueueContent.Controls = .toolbar) {
        self.controls = controls
    }

    var body: some View {
        let queue = queue
        QueueContent(
            rows: queue.map(QueueRow.rows(of:)) ?? [],
            canPlay: playItem != nil,
            play: play,
            remove: { queue?.remove(id: $0) },
            removeOffsets: { queue?.remove(atOffsets: $0) },
            move: { queue?.move(fromOffsets: $0, toOffset: $1) },
            clear: { queue?.clear() },
            controls: controls
        )
    }

    private func play(_ row: QueueRow) {
        guard let playItem else { return }
        // The app's action reports a failure through the player, not by throwing.
        Task { try? await row.play(with: playItem) }
    }
}

/// The queue's rows, with swipe or context-menu removal, drag to reorder and Clear (after a
/// confirmation); an empty queue says so. Has no model, so previews pass rows and no-op actions.
struct QueueContent: View {
    /// Where Edit and Clear go.
    enum Controls {
        /// The enclosing navigation bar, in a sheet or an inspector of its own.
        case toolbar
        /// A bar under the list, for a pane that shares its window's toolbar (``PlayerDetailsPane``).
        case bar
    }

    let rows: [QueueRow]
    /// Whether tapping a row plays it; `false` between sessions.
    let canPlay: Bool
    let play: (QueueRow) -> Void
    let remove: (QueueRow.ID) -> Void
    let removeOffsets: (IndexSet) -> Void
    let move: (IndexSet, Int) -> Void
    let clear: () -> Void
    var controls = Controls.toolbar
    @State private var confirmsClear = false
    #if os(iOS)
        /// The list's edit mode with ``Controls/bar``, which has no navigation bar to provide one.
        @State private var editMode = EditMode.inactive
    #endif

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
        .modifier(placedControls)
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

    private var placedControls: QueueControls {
        #if os(iOS)
            QueueControls(
                placement: controls, isEmpty: rows.isEmpty, confirmsClear: $confirmsClear, editMode: $editMode)
        #else
            QueueControls(placement: controls, isEmpty: rows.isEmpty, confirmsClear: $confirmsClear)
        #endif
    }
}

/// ``QueueContent``'s Edit (iOS, while it has rows) and Clear buttons, in the navigation bar or in
/// a bar under the content.
private struct QueueControls: ViewModifier {
    let placement: QueueContent.Controls
    let isEmpty: Bool
    @Binding var confirmsClear: Bool
    #if os(iOS)
        @Binding var editMode: EditMode
    #endif

    func body(content: Content) -> some View {
        switch placement {
        case .toolbar:
            content.toolbar {
                #if os(iOS)
                    ToolbarItem(placement: .topBarLeading) {
                        if !isEmpty { EditButton() }
                    }
                #endif
                ToolbarItem(placement: .destructiveAction) { clearButton }
            }
        case .bar:
            #if os(iOS)
                content
                    .safeAreaInset(edge: .bottom, spacing: 0) {
                        HStack {
                            if !isEmpty { EditButton() }
                            Spacer()
                            clearButton
                        }
                        .padding()
                    }
                    .environment(\.editMode, $editMode)
                    .onChange(of: isEmpty) { _, isEmpty in
                        if isEmpty { editMode = .inactive }
                    }
            #else
                content.safeAreaInset(edge: .bottom, spacing: 0) {
                    HStack {
                        Spacer()
                        clearButton
                    }
                    .padding()
                }
            #endif
        }
    }

    private var clearButton: some View {
        Button(role: .destructive) {
            confirmsClear = true
        } label: {
            Text(verbatim: L10n.string("ButtonClearQueue"))
        }
        .disabled(isEmpty)
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

    #Preview("Bar") {
        QueueContent(
            rows: QueueRow.previews, canPlay: true, play: { _ in }, remove: { _ in }, removeOffsets: { _ in },
            move: { _, _ in }, clear: {}, controls: .bar)
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
