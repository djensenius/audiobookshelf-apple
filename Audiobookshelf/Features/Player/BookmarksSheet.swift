import ABSAppModel
import ABSCore
import ABSUI
import SwiftUI

extension EnvironmentValues {
    /// The signed-in account's bookmarks. The app shell (#183) sets it; `nil` while signed out, which
    /// leaves the player's bookmarks button disabled (D11).
    @Entry var bookmarkStore: BookmarkStore?
}

/// The toolbar's bookmarks button: filled when the item has bookmarks, hidden for podcast episodes
/// and without an item, and disabled without a usable connection (D11).
struct BookmarksSlot: View {
    let model: PlayerViewModel
    @Binding var sheet: PlayerSheet?
    @Environment(\.bookmarkStore) private var store

    var body: some View {
        let presentation = BookmarksSlotPresentation(player: model, store: store)
        if presentation.isVisible {
            Button {
                sheet = .bookmarks
            } label: {
                Label {
                    Text(verbatim: L10n.string("LabelYourBookmarks"))
                } icon: {
                    Image(systemName: presentation.systemImage)
                }
            }
            .disabled(!presentation.isEnabled)
        }
    }
}

/// The bookmarks button's state, from the player and the store.
struct BookmarksSlotPresentation: Equatable {
    let isVisible: Bool
    let isEnabled: Bool
    /// `bookmark.fill` when the item has bookmarks, else `bookmark`.
    let systemImage: String

    @MainActor
    init(player: PlayerViewModel, store: BookmarkStore?) {
        guard let store else {
            isVisible = player.supportsBookmarks
            isEnabled = false
            systemImage = "bookmark"
            return
        }
        let model = PlayerBookmarksModel(player: player, store: store)
        isVisible = model.isVisible
        isEnabled = model.isVisible && model.isEnabled
        systemImage = model.hasBookmarks ? "bookmark.fill" : "bookmark"
    }
}

/// How the sheet displays a bookmark's time: the media time divided by the current playback rate,
/// as the legacy modal did. Display only; bookmarks are stored and sought in media time.
enum BookmarkTimePresentation {
    /// `time` divided by `rate`; a non-finite or non-positive rate counts as `1`.
    static func atRate(_ time: Double, rate: Double) -> Double {
        time / (rate.isFinite && rate > 0 ? rate : 1)
    }

    /// The timestamp, such as "1:05:00".
    static func text(_ time: Double, rate: Double, locale: Locale) -> String {
        DurationStyle.timestamp.string(atRate(time, rate: rate), locale: locale)
    }

    /// The timestamp spoken in full, such as "1 hour, 5 minutes".
    static func accessibilityText(_ time: Double, rate: Double, locale: Locale) -> String {
        DurationStyle.timestamp.accessibilityString(atRate(time, rate: rate), locale: locale)
    }
}

/// A bookmark row's text.
struct BookmarkRowPresentation: Equatable {
    let title: String
    let timeText: String
    /// The title and the time spoken in full.
    let accessibilityLabel: String

    init(bookmark: AudioBookmark, rate: Double, locale: Locale) {
        title = bookmark.title
        timeText = BookmarkTimePresentation.text(bookmark.time, rate: rate, locale: locale)
        accessibilityLabel = L10n.string(
            "LabelBookmarkRowAccessibility", bookmark.title,
            BookmarkTimePresentation.accessibilityText(bookmark.time, rate: rate, locale: locale), locale: locale)
    }
}

/// A failed bookmark change, for the error alert.
enum BookmarkFailure {
    case create, update, remove

    /// The legacy toast's string key.
    var messageKey: String {
        switch self {
        case .create: "ToastBookmarkCreateFailed"
        case .update: "ToastBookmarkUpdateFailed"
        case .remove: "ToastBookmarkRemoveFailed"
        }
    }
}

/// The bookmarks sheet (port of `BookmarksModal.vue`): the item's bookmarks by time (D8), with the
/// one at the current second highlighted, and a bar to create one at the current second (D10).
/// Choosing a bookmark seeks to it and closes the sheet; swiping or the context menu edits or
/// deletes one, after confirming. Changes show at once and roll back, with an alert, if they fail.
struct BookmarksSheet: View {
    let model: PlayerViewModel
    let close: () -> Void

    var body: some View {
        BookmarksPane(model: model, onSelect: close)
            .playerSheetStyle(title: L10n.string("LabelYourBookmarks"), onDone: close)
    }
}

/// The bookmarks without the sheet's frame, for the sheet and for the full player's details pane
/// on a large display (#84). Choosing a bookmark seeks to it, then calls `onSelect`. Its form opens
/// in the enclosing `NavigationStack`.
struct BookmarksPane: View {
    let model: PlayerViewModel
    let onSelect: () -> Void
    @Environment(\.bookmarkStore) private var store

    var body: some View {
        if let store {
            BookmarksContent(
                bookmarks: PlayerBookmarksModel(player: model, store: store), rate: model.rate, close: onSelect)
        } else {
            NoBookmarksView()
        }
    }
}

/// What the form opened for: a new bookmark, with the item, second and default title captured
/// when it opened, or an existing one.
enum BookmarkEditorTarget: Hashable, Identifiable {
    case create(itemID: String, time: Double, defaultTitle: String)
    case edit(AudioBookmark)

    var id: Self { self }

    /// Whether the form creates a bookmark rather than renaming one.
    var isCreate: Bool {
        if case .create = self { true } else { false }
    }
}

/// The sheet's body when there is a store: the list (or a spinner during the first load, or the
/// empty state), the create bar, the form, the delete confirmation and the error alert.
///
/// Writes run in unstructured tasks, so they finish after the sheet closes; a failure then only
/// rolls the store back, silently, as the alert has nowhere to show.
private struct BookmarksContent: View {
    let bookmarks: PlayerBookmarksModel
    let rate: Double
    let close: () -> Void
    @Environment(\.locale) private var locale
    @State private var editor: BookmarkEditorTarget?
    @State private var pendingDelete: AudioBookmark?
    /// The last failure; kept while the alert closes so its title doesn't go blank.
    @State private var failure: BookmarkFailure?
    @State private var isShowingFailure = false

    var body: some View {
        let rows = bookmarks.rows.map {
            (bookmark: $0, presentation: BookmarkRowPresentation(bookmark: $0, rate: rate, locale: locale))
        }
        Group {
            if rows.isEmpty, bookmarks.isFirstLoadInProgress {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if rows.isEmpty {
                NoBookmarksView()
            } else {
                BookmarksList(
                    bookmarks: bookmarks, rows: rows, canEdit: bookmarks.isEnabled, select: select,
                    edit: { editor = .edit($0) }, delete: { pendingDelete = $0 })
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            CreateBookmarkBar(bookmarks: bookmarks, rate: rate) { time in
                guard let itemID = bookmarks.currentItemID else { return }
                editor = .create(itemID: itemID, time: time, defaultTitle: bookmarks.defaultTitle(locale: locale))
            }
        }
        .navigationDestination(item: $editor) { target in
            BookmarkEditor(target: target, rate: rate, placeholder: placeholder(for: target)) { title in
                submit(title, for: target)
            }
        }
        .confirmationDialog(
            Text(verbatim: L10n.string("MessageConfirmRemoveBookmark")),
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible, presenting: pendingDelete
        ) { bookmark in
            Button(role: .destructive) {
                remove(bookmark)
            } label: {
                Text(verbatim: L10n.string("ButtonDelete"))
            }
            Button(role: .cancel) {
            } label: {
                Text(verbatim: L10n.string("ButtonCancel"))
            }
        }
        .alert(
            Text(verbatim: failure.map { L10n.string($0.messageKey) } ?? ""), isPresented: $isShowingFailure,
            presenting: failure
        ) { _ in
            Button {
            } label: {
                Text(verbatim: L10n.string("ButtonOk"))
            }
        }
        .task { await bookmarks.onAppear() }
    }

    private func placeholder(for target: BookmarkEditorTarget) -> String {
        switch target {
        case .create(_, _, let defaultTitle): defaultTitle
        // An empty title keeps the current one.
        case .edit(let bookmark): bookmark.title
        }
    }

    private func select(_ bookmark: AudioBookmark) {
        Task { await bookmarks.select(bookmark) }
        close()
    }

    private func submit(_ title: String, for target: BookmarkEditorTarget) {
        editor = nil
        let bookmarks = bookmarks
        Task {
            do {
                switch target {
                case .create(let itemID, let time, let defaultTitle):
                    try await bookmarks.create(title: title, itemID: itemID, at: time, defaultTitle: defaultTitle)
                case .edit(let bookmark): try await bookmarks.rename(bookmark, to: title)
                }
            } catch is CancellationError {
            } catch {
                show(target.isCreate ? .create : .update)
            }
        }
    }

    private func remove(_ bookmark: AudioBookmark) {
        pendingDelete = nil
        let bookmarks = bookmarks
        Task {
            do {
                try await bookmarks.delete(bookmark)
            } catch is CancellationError {
            } catch {
                show(.remove)
            }
        }
    }

    private func show(_ failure: BookmarkFailure) {
        self.failure = failure
        isShowingFailure = true
    }
}

private struct NoBookmarksView: View {
    var body: some View {
        ContentUnavailableView {
            Label {
                Text(verbatim: L10n.string("MessageNoBookmarks"))
            } icon: {
                Image(systemName: "bookmark")
            }
        }
    }
}

/// The list. It reads the playback time once per tick for the current bookmark and passes each
/// row whether it's current, so a tick redraws only the rows whose mark changed.
private struct BookmarksList: View {
    let bookmarks: PlayerBookmarksModel
    let rows: [(bookmark: AudioBookmark, presentation: BookmarkRowPresentation)]
    let canEdit: Bool
    let select: (AudioBookmark) -> Void
    let edit: (AudioBookmark) -> Void
    let delete: (AudioBookmark) -> Void

    var body: some View {
        let current = bookmarks.currentBookmarkID
        List {
            ForEach(rows, id: \.bookmark.id) { row in
                BookmarkRow(
                    bookmark: row.bookmark, presentation: row.presentation, isCurrent: row.bookmark.id == current
                ) {
                    select(row.bookmark)
                }
                .equatable()
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    // Not `.destructive`: the list would remove the row before the confirmation.
                    if canEdit {
                        deleteButton(row.bookmark, role: nil)
                            .tint(.red)
                        editButton(row.bookmark)
                    }
                }
                .contextMenu {
                    if canEdit {
                        editButton(row.bookmark)
                        deleteButton(row.bookmark, role: .destructive)
                    }
                }
            }
        }
    }

    private func editButton(_ bookmark: AudioBookmark) -> some View {
        Button {
            edit(bookmark)
        } label: {
            Label {
                Text(verbatim: L10n.string("ButtonEdit"))
            } icon: {
                Image(systemName: "pencil")
            }
        }
        .tint(ABSColor.accent)
    }

    private func deleteButton(_ bookmark: AudioBookmark, role: ButtonRole?) -> some View {
        Button(role: role) {
            delete(bookmark)
        } label: {
            Label {
                Text(verbatim: L10n.string("ButtonDelete"))
            } icon: {
                Image(systemName: "trash")
            }
        }
    }
}

/// One bookmark. Equatable without its action, so a tick that doesn't change its inputs skips it.
private struct BookmarkRow: View, Equatable {
    let bookmark: AudioBookmark
    let presentation: BookmarkRowPresentation
    let isCurrent: Bool
    let action: () -> Void

    nonisolated static func == (lhs: BookmarkRow, rhs: BookmarkRow) -> Bool {
        lhs.bookmark == rhs.bookmark && lhs.presentation == rhs.presentation && lhs.isCurrent == rhs.isCurrent
    }

    var body: some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: ABSSpacing.small) {
                Image(systemName: isCurrent ? "bookmark.fill" : "bookmark")
                    .foregroundStyle(isCurrent ? ABSColor.accent : .secondary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: presentation.title)
                        .font(.body)
                        .lineLimit(3)
                    Text(verbatim: presentation.timeText)
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 44)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .fontWeight(isCurrent ? .semibold : nil)
        .listRowBackground(isCurrent ? ABSColor.accent.opacity(0.2) : nil)
        // On the button itself, so VoiceOver keeps its action.
        .accessibilityLabel(Text(verbatim: presentation.accessibilityLabel))
        .accessibilityHint(Text(verbatim: L10n.string("LabelPlayFromBookmarkHint")))
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
    }
}

/// The bar pinned below the list: "Create Bookmark" and the current second, at the rate. It reads
/// the playback time, so it's its own leaf view. Disabled when a bookmark is already at this second
/// (D10) or bookmarks are unavailable (D11).
private struct CreateBookmarkBar: View {
    let bookmarks: PlayerBookmarksModel
    let rate: Double
    let create: (Double) -> Void
    @Environment(\.locale) private var locale

    var body: some View {
        let time = bookmarks.creationTime
        Button {
            create(time)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: ABSSpacing.small) {
                Image(systemName: "plus")
                    .accessibilityHidden(true)
                Text(verbatim: L10n.string("ButtonCreateBookmark"))
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(verbatim: BookmarkTimePresentation.text(time, rate: rate, locale: locale))
                    .font(.body.monospacedDigit())
            }
            .frame(maxWidth: .infinity, minHeight: 44)
            .contentShape(.rect)
        }
        .buttonStyle(.borderedProminent)
        .disabled(!bookmarks.canCreate)
        .padding(.vertical, ABSSpacing.small)
        .padding(.horizontal, ABSSpacing.medium)
        .background(.bar)
        .accessibilityLabel(Text(verbatim: L10n.string("ButtonCreateBookmark")))
        .accessibilityValue(
            Text(verbatim: BookmarkTimePresentation.accessibilityText(time, rate: rate, locale: locale)))
    }
}

#Preview("Sheet") {
    BookmarksPreviewHost(bookmarks: .previewFixtures) { model in
        BookmarksSheet(model: model, close: {})
    }
}

#Preview("Sheet, empty") {
    BookmarksPreviewHost(bookmarks: []) { model in
        BookmarksSheet(model: model, close: {})
    }
}

#Preview("Sheet, offline") {
    BookmarksPreviewHost(bookmarks: .previewFixtures, isAvailable: false) { model in
        BookmarksSheet(model: model, close: {})
    }
}

#Preview("Sheet, writes fail") {
    BookmarksPreviewHost(bookmarks: .previewFixtures, failsWrites: true) { model in
        BookmarksSheet(model: model, close: {})
    }
}

#Preview("Sheet, accessibility size") {
    BookmarksPreviewHost(bookmarks: .previewFixtures) { model in
        BookmarksSheet(model: model, close: {})
    }
    .dynamicTypeSize(.accessibility3)
}
