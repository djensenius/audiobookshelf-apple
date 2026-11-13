import ABSAppModel
import ABSCore
import ABSUI
import SwiftUI

/// The list behind ``DownloadsView`` and ``DownloadQueueView``: the downloads under way, and in
/// `.all` mode the storage used, the downloaded books and one section per downloaded podcast.
struct DownloadsList: View {
    enum Mode { case all, queue }

    let mode: Mode
    @State private var model: DownloadsTabModel
    @Environment(\.serverID) private var serverID
    /// What waits for the user to confirm its deletion.
    @State private var pendingDelete: PendingDelete?

    init(services: DownloadsServices, mode: Mode) {
        self.mode = mode
        _model = State(initialValue: DownloadsTabModel(services: services))
    }

    var body: some View {
        let listing = model.listing
        content(listing)
            .task(id: serverID) { await model.observe(connectionID: serverID) }
            .refreshable { await model.reload() }
            .confirmationDialog(
                Text(verbatim: pendingDelete?.message ?? ""), isPresented: deleteBinding, titleVisibility: .visible,
                presenting: pendingDelete
            ) { pending in
                Button(L10n.string("ButtonDelete"), role: .destructive) {
                    Task { await delete(pending) }
                }
                Button(L10n.string("ButtonCancel"), role: .cancel) {}
            }
            .alert(
                Text(verbatim: noticeTitle), isPresented: noticeBinding, presenting: model.notice
            ) { notice in
                noticeActions(notice)
            } message: { notice in
                if let message = noticeMessage(notice) { Text(verbatim: message) }
            }
    }

    @ViewBuilder
    private func content(_ listing: DownloadsListing) -> some View {
        let isEmpty = mode == .all ? listing.isEmpty : listing.downloads.isEmpty
        if !model.isLoaded, mode == .all {
            LoadingView()
        } else if isEmpty, let failure = loadFailure {
            ErrorStateView(title: failure) {
                Task { await model.reload() }
            }
        } else if isEmpty {
            ContentUnavailableView {
                Label {
                    Text(verbatim: L10n.string("MessageNoDownloads"))
                } icon: {
                    Image(systemName: "arrow.down.circle")
                        .accessibilityHidden(true)
                }
            }
        } else {
            List {
                if mode == .all {
                    Section {
                        DownloadsStorageRow(used: listing.downloadedBytes, available: model.availableBytes)
                    }
                }
                if model.queueLoadError != nil {
                    Section { queueLoadFailedRow }
                }
                downloadingSection(listing)
                if mode == .all {
                    booksSection(listing.books)
                    ForEach(listing.podcasts) { podcastSection($0, isFirst: $0.id == listing.podcasts.first?.id) }
                }
            }
        }
    }

    /// Why an empty list couldn't be read: the downloaded items (`.all` only), or the stored
    /// downloads under way; `nil` when both were read.
    private var loadFailure: String? {
        if mode == .all, model.loadError != nil { return L10n.string("MessageDownloadsLoadFailed") }
        return model.queueLoadError != nil ? L10n.string("MessageDownloadQueueLoadFailed") : nil
    }

    /// Shown above the list when the stored downloads under way couldn't be read, so the queue
    /// isn't silently missing; Retry reads them again.
    private var queueLoadFailedRow: some View {
        HStack(spacing: ABSSpacing.medium) {
            Label {
                Text(verbatim: L10n.string("MessageDownloadQueueLoadFailed"))
            } icon: {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(ABSColor.mutedForeground)
                    .accessibilityHidden(true)
            }
            Spacer(minLength: ABSSpacing.small)
            Button(L10n.string("ButtonRetry")) {
                Task { await model.reload() }
            }
            .buttonStyle(.borderless)
        }
        .font(.footnote)
    }

    @ViewBuilder
    private func downloadingSection(_ listing: DownloadsListing) -> some View {
        if !listing.downloads.isEmpty {
            Section {
                ForEach(listing.downloads) { download in
                    DownloadQueueRow(download: download)
                        .disabled(model.busy.contains(download.id))
                        .swipeActions {
                            Button(L10n.string("ButtonCancel"), role: .destructive) {
                                Task { await model.cancel(recordID: download.id) }
                            }
                            if download.status.isRetryable {
                                Button(L10n.string("ButtonRetry")) {
                                    Task { await model.retry(recordID: download.id) }
                                }
                                .tint(ABSColor.accent)
                            }
                        }
                }
            } header: {
                HStack(spacing: ABSSpacing.small) {
                    DownloadProgressIndicator(fraction: listing.downloadingFraction, count: listing.downloads.count)
                    Text(verbatim: L10n.string("HeaderDownloading"))
                    Spacer()
                    Button(L10n.string("ButtonCancelAllDownloads"), role: .destructive) {
                        Task { await model.cancelAll() }
                    }
                    .font(.caption)
                }
            }
        }
    }

    @ViewBuilder
    private func booksSection(_ books: [DownloadsListing.Item]) -> some View {
        if !books.isEmpty {
            Section {
                ForEach(books) { book in
                    DownloadedItemRow(item: book, serverID: serverID)
                        .disabled(model.busy.contains(book.id))
                        .swipeActions { deleteButton(.item(book)) }
                }
            } header: {
                Text(verbatim: L10n.string("LabelBooks"))
            }
        }
    }

    /// One section per podcast: its summary row, then its episodes; only the first has a header.
    private func podcastSection(_ podcast: DownloadsListing.Item, isFirst: Bool) -> some View {
        Section {
            DownloadedItemRow(item: podcast, serverID: serverID)
                .swipeActions { deleteButton(.item(podcast)) }
            ForEach(podcast.episodes) { episode in
                DownloadedEpisodeRow(episode: episode)
                    .swipeActions { deleteButton(.episode(podcast, episode)) }
            }
        } header: {
            if isFirst { Text(verbatim: L10n.string("LabelPodcasts")) }
        }
        .disabled(model.busy.contains(podcast.id))
    }

    private func deleteButton(_ pending: PendingDelete) -> some View {
        Button(L10n.string("ButtonDelete"), role: .destructive) { pendingDelete = pending }
    }

    private func delete(_ pending: PendingDelete) async {
        switch pending {
        case .item(let item): await model.delete(itemID: item.id)
        case .episode(let item, let episode): await model.deleteEpisode(itemID: item.id, episodeId: episode.id)
        }
    }

    private var deleteBinding: Binding<Bool> {
        Binding {
            pendingDelete != nil
        } set: {
            if !$0 { pendingDelete = nil }
        }
    }

    private var noticeBinding: Binding<Bool> {
        Binding {
            model.notice != nil
        } set: {
            if !$0 { model.notice = nil }
        }
    }

    private var noticeTitle: String {
        switch model.notice {
        case .confirmMeteredRetry: L10n.string("HeaderConfirm")
        default: L10n.string("HeaderDownloads")
        }
    }

    private func noticeMessage(_ notice: DownloadsTabModel.Notice) -> String? {
        switch notice {
        case .cancelFailed: L10n.string("MessageDownloadCancelFailed")
        case .retryFailed: L10n.string("MessageDownloadRetryFailed")
        case .retryDenied: L10n.string("ToastDownloadNotAllowedOnCellular")
        case .confirmMeteredRetry: L10n.string("MessageConfirmDownloadUsingCellular")
        case .deleteFailed: L10n.string("MessageDownloadDeleteFailed")
        }
    }

    @ViewBuilder
    private func noticeActions(_ notice: DownloadsTabModel.Notice) -> some View {
        if case .confirmMeteredRetry(let recordID) = notice {
            Button(L10n.string("ButtonYes")) {
                Task { await model.confirmMeteredRetry(recordID: recordID) }
            }
            Button(L10n.string("ButtonCancel"), role: .cancel) {}
        } else {
            Button(L10n.string("ButtonOk")) {}
        }
    }
}

/// A deletion waiting for confirmation: a whole downloaded item, or one podcast episode.
private enum PendingDelete {
    case item(DownloadsListing.Item)
    case episode(DownloadsListing.Item, DownloadsListing.Episode)

    /// The legacy confirmation text.
    var message: String {
        switch self {
        case .item: L10n.string("MessageConfirmDeleteLocalFiles")
        case .episode(_, let episode): L10n.string("MessageConfirmDeleteLocalEpisode", episode.title)
        }
    }
}
