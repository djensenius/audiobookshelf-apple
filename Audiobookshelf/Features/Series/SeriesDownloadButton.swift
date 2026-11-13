import ABSAppModel
import ABSCore
import ABSUI
import SwiftUI

/// Download Series in the series screen's toolbar (legacy `BookshelfToolbar.vue`'s download button on a series
/// page) and the alerts of ``SeriesDownloadModel``: nothing to download, the confirmation, the cellular question,
/// and failures.
struct SeriesDownloadButton: View {
    let model: SeriesDownloadModel
    /// The library the series' books are in (``SeriesDetailModel/booksLibraryID``); `nil` until the series loaded.
    let libraryID: String?
    @Environment(\.locale) private var locale
    /// The listing under way, cancelled when the button leaves the screen.
    @State private var listing: Task<Void, Never>?

    var body: some View {
        Button {
            guard let libraryID else { return }
            listing = Task { await model.start(libraryID: libraryID) }
        } label: {
            Label {
                Text(verbatim: L10n.string("ButtonDownloadSeries"))
            } icon: {
                Image(systemName: "arrow.down.circle")
            }
        }
        .help(Text(verbatim: L10n.string("ButtonDownloadSeries")))
        .disabled(libraryID == nil || model.isWorking)
        .onDisappear { listing?.cancel() }
        .alert(
            Text(verbatim: model.prompt.map { SeriesDownloadAlert($0, locale: locale).title } ?? ""),
            isPresented: Binding(get: { model.prompt != nil }, set: { if !$0 { model.prompt = nil } }),
            presenting: model.prompt.map { SeriesDownloadAlert($0, locale: locale) }
        ) { alert in
            if alert.asks {
                Button(role: .cancel) {
                    model.cancel()
                } label: {
                    Text(verbatim: L10n.string("ButtonCancel"))
                }
                Button {
                    let metered = alert.prompt == .meteredConfirmation
                    Task {
                        if metered { await model.confirmMetered() } else { await model.confirm() }
                    }
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
}

/// The text and buttons of a ``SeriesDownloadModel/Prompt``'s alert.
struct SeriesDownloadAlert {
    let prompt: SeriesDownloadModel.Prompt
    let title: String
    let message: String?
    /// Whether it asks the user to go ahead (Cancel and OK), rather than telling them (OK).
    let asks: Bool

    init(_ prompt: SeriesDownloadModel.Prompt, locale: Locale) {
        self.prompt = prompt
        switch prompt {
        case .alreadyDownloaded:
            (title, message, asks) = (L10n.string("MessageSeriesAlreadyDownloaded"), nil, false)
        case .confirm(let plan):
            let message = L10n.string(
                "MessageSeriesDownloadConfirmIos", plan.itemIDs.count.formatted(.number.locale(locale)),
                plan.fileCount.formatted(.number.locale(locale)),
                ByteCountFormatting.string(fromBytes: plan.size, locale: locale))
            (title, self.message, asks) = (L10n.string("HeaderConfirm"), message, true)
        case .meteredConfirmation:
            (title, message, asks) = (
                L10n.string("HeaderConfirm"), L10n.string("MessageConfirmDownloadUsingCellular"), true
            )
        case .meteredDenied:
            (title, message, asks) = (L10n.string("ToastDownloadNotAllowedOnCellular"), nil, false)
        case .loadFailed:
            (title, message, asks) = (L10n.string("MessageSeriesDownloadListFailed"), nil, false)
        case .queueFailed(let count):
            let title = L10n.plural(
                "MessageSeriesDownloadQueueFailed", count: count, count.formatted(.number.locale(locale)))
            (self.title, message, asks) = (title, nil, false)
        }
    }
}
