import ABSAppModel
import ABSCore
import ABSUI
import SwiftUI

/// A downloaded item (legacy `pages/localMedia/item/_id.vue`): its cover and sizes, how it's
/// linked to the signed-in account, its tracks or episodes and ebook files, and deleting it or
/// one of its episodes.
struct LocalItemDetailView: View {
    @State private var model: LocalItemDetailModel
    @Environment(AccountManager.self) private var accounts: AccountManager?
    @Environment(\.dismiss) private var dismiss
    /// What waits for the user to confirm its deletion.
    @State private var pendingDelete: PendingLocalDelete?

    init(itemID: UUID, services: DownloadsServices) {
        _model = State(initialValue: LocalItemDetailModel(itemID: itemID, services: services))
    }

    var body: some View {
        content
            .navigationTitle(Text(verbatim: model.detail?.title ?? L10n.string("ButtonLocalMedia")))
            .task { await model.observe() }
            .onChange(of: account, initial: true) { _, account in model.account = account }
            .onChange(of: model.isDeleted) { _, deleted in if deleted { dismiss() } }
            .confirmationDialog(
                Text(verbatim: pendingDelete?.message ?? ""), isPresented: deleteBinding, titleVisibility: .visible,
                presenting: pendingDelete
            ) { pending in
                Button(L10n.string("ButtonDelete"), role: .destructive) {
                    Task {
                        switch pending {
                        case .item: await model.delete()
                        case .episode(let episode): await model.deleteEpisode(id: episode.id)
                        }
                    }
                }
                Button(L10n.string("ButtonCancel"), role: .cancel) {}
            }
            .alert(
                Text(verbatim: L10n.string("HeaderDownloads")), isPresented: noticeBinding, presenting: model.notice
            ) { _ in
                Button(L10n.string("ButtonOk")) {}
            } message: { _ in
                Text(verbatim: L10n.string("MessageDownloadDeleteFailed"))
            }
    }

    @ViewBuilder
    private var content: some View {
        if let detail = model.detail {
            List {
                Section { LocalItemHeader(detail: detail, coverFileURL: model.coverFileURL) }
                if !detail.tracks.isEmpty {
                    Section {
                        ForEach(detail.tracks) { LocalFileRow(file: $0) }
                    } header: {
                        Text(verbatim: "\(L10n.string("HeaderAudioTracks")) (\(detail.tracks.count.formatted()))")
                    }
                }
                if detail.isPodcast, !detail.episodes.isEmpty {
                    Section {
                        ForEach(detail.episodes) { episode in
                            LocalEpisodeRow(episode: episode)
                                .swipeActions {
                                    // Not `.destructive`: the list would remove the row before
                                    // the confirmation (as in `DownloadsList.deleteButton`).
                                    Button(L10n.string("ButtonDelete")) { pendingDelete = .episode(episode) }
                                        .tint(.red)
                                }
                                // The same confirmation for a pointer (macOS) or a long press.
                                .contextMenu {
                                    Button(L10n.string("ButtonDelete"), role: .destructive) {
                                        pendingDelete = .episode(episode)
                                    }
                                }
                        }
                    } header: {
                        Text(verbatim: "\(L10n.string("HeaderEpisodes")) (\(detail.episodes.count.formatted()))")
                    }
                }
                fileSection(detail.ebooks, title: L10n.string("HeaderEbookFiles"))
                fileSection(detail.otherFiles, title: L10n.string("HeaderOtherFiles"))
                Section {
                    Button(L10n.string("ButtonDeleteLocalItem"), role: .destructive) { pendingDelete = .item }
                }
            }
            .disabled(model.isDeleting)
            .refreshable { await model.reload() }
        } else if !model.isLoaded {
            LoadingView()
        } else if model.loadError != nil {
            ErrorStateView(title: L10n.string("MessageLocalItemLoadFailed")) {
                Task { await model.reload() }
            }
        } else {
            ContentUnavailableView {
                Label {
                    Text(verbatim: L10n.string("MessageLocalItemNotFound"))
                } icon: {
                    Image(systemName: "internaldrive")
                        .accessibilityHidden(true)
                }
            }
        }
    }

    @ViewBuilder
    private func fileSection(_ files: [LocalItemDetail.File], title: String) -> some View {
        if !files.isEmpty {
            Section {
                ForEach(files) { LocalFileRow(file: $0) }
            } header: {
                Text(verbatim: title)
            }
        }
    }

    /// The signed-in account, for the link status.
    private var account: LocalItemDetail.Account? {
        accounts?.activeConnection.map {
            LocalItemDetail.Account(connectionID: $0.id, address: $0.address, userID: $0.userId)
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
}

/// A deletion on the local item screen waiting for confirmation.
private enum PendingLocalDelete {
    case item
    case episode(LocalItemDetail.Episode)

    /// The legacy confirmation text.
    var message: String {
        switch self {
        case .item: L10n.string("MessageConfirmDeleteLocalFiles")
        case .episode(let episode): L10n.string("MessageConfirmDeleteLocalEpisode", episode.title)
        }
    }
}

/// A downloaded item's cover: its downloaded file, read here so it shows offline even after the
/// image cache dropped it, else the cover through the image pipeline.
private struct LocalItemCover: View {
    let detail: LocalItemDetail
    let fileURL: URL?
    @Environment(\.displayScale) private var displayScale
    @State private var image: CGImage?

    private static let width: CGFloat = 96

    var body: some View {
        Group {
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .scaledToFill()
                    .frame(width: Self.width, height: Self.width * shape.aspectRatio)
                    .clipShape(.rect(cornerRadius: ABSRadius.small))
                    .accessibilityHidden(true)
            } else {
                CoverView(
                    key: CoverRef(
                        entityID: detail.libraryItemId,
                        updatedAt: LocalDownloadedCovers.version(of: detail.coverUpdatedAt)
                    )
                    .key(serverID: detail.serverConnectionID),
                    title: detail.title, author: detail.author, shape: shape, accessibility: .hidden
                )
            }
        }
        .task(id: fileURL) {
            guard let fileURL else {
                image = nil
                return
            }
            let pixels = Int((Self.width * max(shape.aspectRatio, 1) * displayScale).rounded(.up))
            image = await LocalItemDetailModel.coverImage(at: fileURL, maxPixelSize: pixels)
        }
    }

    private var shape: CoverShape { detail.isPodcast ? .square : .book }
}

/// The cover, title, author, sizes and link status of a downloaded item.
private struct LocalItemHeader: View {
    let detail: LocalItemDetail
    let coverFileURL: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: ABSSpacing.medium) {
            HStack(alignment: .top, spacing: ABSSpacing.medium) {
                LocalItemCover(detail: detail, fileURL: coverFileURL)
                    .frame(width: 96)
                VStack(alignment: .leading, spacing: ABSSpacing.xSmall) {
                    Text(verbatim: detail.title)
                        .font(.headline)
                    if let author = detail.author {
                        Text(verbatim: author)
                            .font(.subheadline)
                            .foregroundStyle(ABSColor.mutedForeground)
                    }
                    Text(
                        verbatim: L10n.string(
                            "LabelDownloadedTotalSize", ByteCountFormatting.string(fromBytes: detail.totalBytes))
                    )
                    .font(.caption)
                    .foregroundStyle(ABSColor.mutedForeground)
                    if detail.totalDuration > 0 {
                        Text(verbatim: TimeFormatting.timestamp(detail.totalDuration))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(ABSColor.mutedForeground)
                    }
                }
                .accessibilityElement(children: .combine)
            }
            LocalItemLinkView(link: detail.link)
        }
    }
}

/// How a downloaded item is linked to the signed-in account, with the legacy wording; a
/// mismatch shows as a warning, since progress then doesn't sync from this account.
private struct LocalItemLinkView: View {
    let link: LocalItemDetail.LinkStatus

    var body: some View {
        Label {
            Text(verbatim: message)
                .font(.footnote)
        } icon: {
            Image(systemName: isWarning ? "exclamationmark.triangle" : "link")
                .foregroundStyle(isWarning ? AnyShapeStyle(ABSColor.warning) : AnyShapeStyle(ABSColor.mutedForeground))
                .accessibilityHidden(true)
        }
    }

    private var isWarning: Bool {
        switch link {
        case .thisAccount, .linked: false
        case .otherServer, .otherUser, .otherConnection: true
        }
    }

    private var message: String {
        switch link {
        case .thisAccount: L10n.string("MessageMediaLinkedToThisServer")
        case .linked(let address): L10n.string("MessageMediaLinkedToServer", address)
        case .otherServer(let address): L10n.string("MessageMediaLinkedToADifferentServer", address)
        case .otherUser: L10n.string("MessageMediaLinkedToADifferentUser")
        case .otherConnection: L10n.string("MessageMediaLinkedToADifferentConnection")
        }
    }
}

/// An audio track, ebook or other file: number or format, title, type, duration and size.
private struct LocalFileRow: View {
    let file: LocalItemDetail.File

    var body: some View {
        HStack(spacing: ABSSpacing.medium) {
            if let leading {
                Text(verbatim: leading)
                    .font(.subheadline.monospaced().bold())
                    .frame(minWidth: 32)
            }
            VStack(alignment: .leading, spacing: ABSSpacing.xxSmall) {
                Text(verbatim: file.title)
                    .font(.subheadline)
                    .lineLimit(2)
                if file.title != file.filename {
                    Text(verbatim: file.filename)
                        .font(.caption)
                        .foregroundStyle(ABSColor.mutedForeground)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: ABSSpacing.small)
            VStack(alignment: .trailing, spacing: ABSSpacing.xxSmall) {
                if let duration = file.duration {
                    Text(verbatim: TimeFormatting.timestamp(duration))
                        .font(.caption.monospacedDigit())
                }
                Text(verbatim: ByteCountFormatting.string(fromBytes: file.byteCount))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(ABSColor.mutedForeground)
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// The track number, or the ebook format.
    private var leading: String? {
        if let index = file.index { return index.formatted() }
        return file.format?.uppercased()
    }
}

/// A downloaded podcast episode: title, date, duration and size.
private struct LocalEpisodeRow: View {
    let episode: LocalItemDetail.Episode

    var body: some View {
        VStack(alignment: .leading, spacing: ABSSpacing.xxSmall) {
            Text(verbatim: episode.title)
                .font(.subheadline)
                .lineLimit(2)
            Text(verbatim: details)
                .font(.caption.monospacedDigit())
                .foregroundStyle(ABSColor.mutedForeground)
        }
        .accessibilityElement(children: .combine)
    }

    private var details: String {
        var parts: [String] = []
        if let published = episode.publishedAt { parts.append(published.formatted(date: .abbreviated, time: .omitted)) }
        if let duration = episode.duration { parts.append(TimeFormatting.timestamp(duration)) }
        parts.append(ByteCountFormatting.string(fromBytes: episode.byteCount))
        return parts.joined(separator: " · ")
    }
}
