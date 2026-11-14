import ABSAppModel
import ABSCore
import ABSUI
import SwiftUI

/// The Download button of a book (legacy `pages/item/_id/index.vue`'s download button), built for
/// podcast episodes too: it shows the media's ``ItemDownloadState`` and acts on it.
///
/// - Not downloaded: a tap queues the download (with the cellular question when the path is
///   metered). Hidden when the app has no download stack, while signed out, and when the account
///   can't request a download now (offline, or without the download permission), as legacy
///   `showDownload` hides it.
/// - Queued, downloading, paused or failed: a tap offers Cancel Download, and Retry for a paused or
///   failed one.
/// - Downloaded: a tap asks before deleting the downloaded files.
/// - A long press (a secondary click on the Mac) shows the same actions in a context menu.
/// - For a connection whose downloads continue only while the app is open (#467), the cellular
///   question, the actions of a download under way and its VoiceOver hint say so
///   (``DownloadsWhileAppOpenNotice``).
///
/// It builds one ``ItemDownloadModel`` per server item, episode and connection, observing the
/// downloaded items while it is on screen; or, in a list (a podcast's episode rows, `feed`), reading
/// the screen's shared ``DownloadedItemsFeed`` so the rows don't each observe the store.
struct ItemDownloadButton: View {
    /// How the button is drawn: bordered on a detail screen, or a compact symbol in a row.
    enum Style {
        case bordered
        case compact
    }

    let libraryItemID: String
    var episodeID: String?
    /// The episode's title, which the delete confirmation names; `nil` for a book.
    var episodeTitle: String?
    /// The expanded item a download is requested with; `nil` until loaded, which disables Download.
    let item: ABSCore.LibraryItem?
    /// The screen's shared downloaded items, of the active connection; `nil` to observe them here.
    var feed: DownloadedItemsFeed?
    var style: Style = .bordered
    @Environment(\.serverID) private var serverID
    @Environment(\.downloadAccess) private var access
    @Environment(\.downloads) private var downloads
    @State private var model: ItemDownloadModel?

    private struct Key: Hashable {
        let libraryItemID: String
        let episodeID: String?
        let connectionID: UUID?
        let feed: ObjectIdentifier?
    }

    var body: some View {
        Group {
            if let model, model.libraryItemID == libraryItemID, model.episodeID == episodeID,
                model.connectionID == serverID, model.feed === feed, model.isShown
            {
                ItemDownloadControl(model: model, item: item, episodeTitle: episodeTitle, style: style)
            }
        }
        .task(
            id: Key(
                libraryItemID: libraryItemID, episodeID: episodeID, connectionID: serverID,
                feed: feed.map(ObjectIdentifier.init))
        ) {
            guard let serverID, let access, let downloads, feed.map({ $0.connectionID == serverID }) ?? true else {
                model = nil
                return
            }
            let model = ItemDownloadModel(
                libraryItemID: libraryItemID, episodeID: episodeID, connectionID: serverID, access: access,
                services: downloads, feed: feed)
            self.model = model
            // Returns at once with a feed, which the screen observes.
            await model.observe()
        }
    }
}

/// The button, its actions and its alerts for one model.
private struct ItemDownloadControl: View {
    let model: ItemDownloadModel
    let item: ABSCore.LibraryItem?
    let episodeTitle: String?
    let style: ItemDownloadButton.Style
    @Environment(\.locale) private var locale
    @State private var showsActions = false

    var body: some View {
        let state = model.state
        let presentation = ItemDownloadPresentation(state: state, locale: locale)
        let deletion = ItemDownloadDeletion(episodeTitle: episodeTitle)
        let notesOnlyWhileOpen = model.notesOnlyWhileOpen
        Button {
            if state.canStart {
                start()
            } else {
                showsActions = true
            }
        } label: {
            Label {
                Text(verbatim: presentation.title)
            } icon: {
                if let fraction = state.fraction {
                    ItemDownloadRing(fraction: fraction, isPaused: state.canRetry)
                } else {
                    Image(systemName: presentation.systemImage)
                }
            }
            .labelStyle(.iconOnly)
            // A row's symbol keeps a 44-point target.
            .frame(minWidth: style == .compact ? 44 : nil, minHeight: style == .compact ? 44 : nil)
            .contentShape(.rect)
        }
        .itemDownloadButtonStyle(style, state: state)
        .disabled(model.isWorking || (state.canStart && item == nil))
        .help(Text(verbatim: presentation.title))
        .accessibilityValue(Text(verbatim: presentation.value ?? ""))
        .accessibilityHint(Text(verbatim: notesOnlyWhileOpen ? DownloadsWhileAppOpenNotice.message : ""))
        .contextMenu {
            if !state.canStart { actions(state, deletion: deletion, confirmingDelete: false) }
        }
        .confirmationDialog(
            Text(verbatim: state.localItemID == nil ? presentation.title : deletion.message),
            isPresented: $showsActions, titleVisibility: .visible
        ) {
            actions(model.state, deletion: deletion, confirmingDelete: true)
            Button(L10n.string("ButtonCancel"), role: .cancel) {}
        } message: {
            if notesOnlyWhileOpen { Text(verbatim: DownloadsWhileAppOpenNotice.message) }
        }
        // A finished or removed download leaves nothing to act on.
        .onChange(of: state.recordID) { showsActions = false }
        .alert(
            Text(verbatim: model.prompt.map { ItemDownloadAlert($0).title } ?? ""),
            isPresented: Binding(get: { model.prompt != nil }, set: { if !$0 { model.prompt = nil } }),
            presenting: model.prompt.map { ItemDownloadAlert($0, onlyWhileOpen: model.onlyWhileOpen) }
        ) { alert in
            if alert.asks {
                Button(role: .cancel) {
                    model.dismissMetered()
                } label: {
                    Text(verbatim: L10n.string("ButtonCancel"))
                }
                Button {
                    Task { await model.confirmMetered() }
                } label: {
                    Text(verbatim: L10n.string("ButtonOk"))
                }
            } else {
                Button(L10n.string("ButtonOk")) {}
            }
        } message: { alert in
            if let message = alert.message { Text(verbatim: message) }
        }
    }

    /// Cancel Download and Retry for a download under way; Delete for a downloaded one, which the
    /// context menu sends to the confirmation first.
    @ViewBuilder
    private func actions(
        _ state: ItemDownloadState, deletion: ItemDownloadDeletion, confirmingDelete: Bool
    ) -> some View {
        if state.canRetry {
            Button {
                start()
            } label: {
                Label(L10n.string("ButtonRetry"), systemImage: "arrow.clockwise")
            }
        }
        if state.recordID != nil {
            Button(role: .destructive) {
                Task { await model.cancel() }
            } label: {
                Label(L10n.string("ButtonCancelDownload"), systemImage: "xmark.circle")
            }
        }
        if state.localItemID != nil {
            Button(role: .destructive) {
                if confirmingDelete {
                    Task { await model.delete() }
                } else {
                    showsActions = true
                }
            } label: {
                Label(deletion.button, systemImage: "trash")
            }
        }
    }

    private func start() {
        guard let item else { return }
        Task { await model.download(item: item) }
    }
}

extension View {
    /// Bordered on a detail screen; in a row, a large borderless symbol, green once downloaded,
    /// like the row's finished toggle.
    @ViewBuilder
    fileprivate func itemDownloadButtonStyle(_ style: ItemDownloadButton.Style, state: ItemDownloadState) -> some View {
        switch style {
        case .bordered:
            buttonStyle(.bordered)
        case .compact:
            self
                .buttonStyle(.borderless)
                .imageScale(.large)
                .foregroundStyle(
                    state.localItemID == nil ? AnyShapeStyle(.tint) : AnyShapeStyle(ABSColor.success))
        }
    }
}

/// The delete action's title and confirmation: the downloaded files of a book, or one downloaded
/// episode by its title.
struct ItemDownloadDeletion: Equatable {
    let button: String
    let message: String

    init(episodeTitle: String?) {
        if let episodeTitle {
            button = L10n.string("ButtonDeleteLocalEpisode")
            message = L10n.string("MessageConfirmDeleteLocalEpisode", episodeTitle)
        } else {
            button = L10n.string("ButtonDeleteLocalItem")
            message = L10n.string("MessageConfirmDeleteLocalFiles")
        }
    }
}

/// How far a download is, as a ring that scales with the text size.
private struct ItemDownloadRing: View {
    let fraction: Double
    let isPaused: Bool
    @ScaledMetric(relativeTo: .body) private var size: CGFloat = 20

    var body: some View {
        ZStack {
            Circle()
                .stroke(.secondary.opacity(0.3), lineWidth: size / 8)
            Circle()
                .trim(from: 0, to: min(max(fraction, 0), 1))
                .stroke(.tint, style: StrokeStyle(lineWidth: size / 8, lineCap: .round))
                .rotationEffect(.degrees(-90))
            if isPaused {
                Image(systemName: "pause.fill")
                    .font(.system(size: size * 0.4))
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// The label, symbol and spoken value of an ``ItemDownloadState``.
struct ItemDownloadPresentation: Equatable {
    /// The button's title, which VoiceOver reads as its label.
    let title: String
    let systemImage: String
    /// The percentage done while downloading or paused, for VoiceOver.
    let value: String?

    init(state: ItemDownloadState, locale: Locale) {
        value = state.fraction.map { $0.formatted(.percent.precision(.fractionLength(0)).locale(locale)) }
        switch state {
        case .none: (title, systemImage) = (L10n.string("LabelDownload"), "arrow.down.circle")
        case .queued: (title, systemImage) = (L10n.string("LabelDownloadStatusQueued"), "clock")
        case .downloading:
            (title, systemImage) = (L10n.string("LabelDownloadStatusDownloading"), "arrow.down.circle")
        case .paused: (title, systemImage) = (L10n.string("LabelDownloadStatusPaused"), "pause.circle")
        case .failed:
            (title, systemImage) = (L10n.string("LabelDownloadStatusFailed"), "exclamationmark.arrow.circlepath")
        case .downloaded: (title, systemImage) = (L10n.string("LabelDownloaded"), "checkmark.circle.fill")
        }
    }
}

/// The text and buttons of an ``ItemDownloadModel/Prompt``'s alert.
struct ItemDownloadAlert: Equatable {
    let prompt: ItemDownloadModel.Prompt
    let title: String
    let message: String?
    /// Whether it asks the user to go ahead (Cancel and OK), rather than telling them (OK).
    let asks: Bool

    /// - Parameter onlyWhileOpen: whether the connection's downloads continue only while the app is
    ///   open (``ItemDownloadModel/onlyWhileOpen``); the cellular question then says so.
    init(_ prompt: ItemDownloadModel.Prompt, onlyWhileOpen: Bool = false) {
        self.prompt = prompt
        switch prompt {
        case .meteredConfirmation:
            let note = onlyWhileOpen ? "\n\n" + DownloadsWhileAppOpenNotice.message : ""
            (title, message, asks) = (
                L10n.string("HeaderConfirm"), L10n.string("MessageConfirmDownloadUsingCellular") + note, true
            )
        case .meteredDenied: (title, message, asks) = (L10n.string("ToastDownloadNotAllowedOnCellular"), nil, false)
        case .notEnoughSpace: (title, message, asks) = (L10n.string("MessageDownloadNotEnoughSpace"), nil, false)
        case .startFailed: (title, message, asks) = (L10n.string("MessageDownloadStartFailed"), nil, false)
        case .cancelFailed: (title, message, asks) = (L10n.string("MessageDownloadCancelFailed"), nil, false)
        case .deleteFailed: (title, message, asks) = (L10n.string("MessageDownloadDeleteFailed"), nil, false)
        }
    }
}
