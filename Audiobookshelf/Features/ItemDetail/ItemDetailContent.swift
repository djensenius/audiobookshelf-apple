import ABSAppModel
import ABSCore
import ABSUI
import SwiftUI

/// The loaded book: cover, title, actions, progress, metadata and description (legacy
/// `index.vue`). Compact width stacks everything; regular width puts the cover, actions and
/// progress beside the title, metadata and description.
struct ItemDetailContent: View {
    let model: ItemDetailModel
    let details: ItemDetailModel.Details
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var showsFullscreenCover = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: ABSSpacing.large) {
                if model.refreshFailed {
                    ItemDetailRefreshFailedBanner { Task { await model.load() } }
                }
                if horizontalSizeClass == .compact {
                    cover(maxWidth: 240)
                        .frame(maxWidth: .infinity)
                    ItemDetailHeader(details: details)
                    ItemDetailActions(model: model)
                    ItemDetailProgress(model: model)
                    ItemDetailMetadata(details: details)
                    description
                } else {
                    HStack(alignment: .top, spacing: ABSSpacing.xLarge) {
                        VStack(alignment: .leading, spacing: ABSSpacing.large) {
                            cover(maxWidth: 300)
                            ItemDetailActions(model: model)
                            ItemDetailProgress(model: model)
                        }
                        .frame(width: 300)
                        VStack(alignment: .leading, spacing: ABSSpacing.large) {
                            ItemDetailHeader(details: details)
                            ItemDetailMetadata(details: details)
                            description
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .padding(ABSSpacing.large)
            .frame(maxWidth: 1_000)
            .frame(maxWidth: .infinity)
        }
        .refreshable { await model.load() }
        .absBackground()
        #if os(iOS)
            .fullScreenCover(isPresented: $showsFullscreenCover) { fullscreenCover }
        #else
            .sheet(isPresented: $showsFullscreenCover) {
                fullscreenCover.frame(minWidth: 480, minHeight: 640)
            }
        #endif
    }

    private func cover(maxWidth: CGFloat) -> some View {
        Button {
            showsFullscreenCover = true
        } label: {
            ItemDetailCover(model: model, details: details, bucket: .medium, showsProgress: true)
                .frame(maxWidth: maxWidth)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(verbatim: L10n.string("LabelItemDetailCover")))
        .accessibilityHint(Text(verbatim: L10n.string("LabelItemDetailCoverHint")))
    }

    private var fullscreenCover: some View {
        NavigationStack {
            ItemDetailCover(model: model, details: details, bucket: .large, showsProgress: false)
                .padding(ABSSpacing.large)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(verbatim: L10n.string("LabelItemDetailCover")))
                .accessibilityValue(Text(verbatim: details.title))
                .accessibilityAddTraits(.isImage)
                .absBackground()
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button {
                            showsFullscreenCover = false
                        } label: {
                            Label {
                                Text(verbatim: L10n.string("ButtonItemDetailClose"))
                            } icon: {
                                Image(systemName: "xmark")
                            }
                        }
                    }
                }
        }
    }

    @ViewBuilder private var description: some View {
        if let description = details.description {
            VStack(alignment: .leading, spacing: ABSSpacing.small) {
                Text(verbatim: L10n.string("LabelDescription"))
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                ExpandableText(html: description)
            }
        }
    }
}

/// The cover through the environment's image pipeline; hidden from VoiceOver, since its button
/// or container speaks for it.
private struct ItemDetailCover: View {
    let model: ItemDetailModel
    let details: ItemDetailModel.Details
    let bucket: ImageWidthBucket
    let showsProgress: Bool
    @Environment(\.serverID) private var serverID

    var body: some View {
        let progress = model.progressFraction
        CoverView(
            key: serverID.flatMap { model.summary?.coverKey(serverID: $0, bucket: bucket) }, title: details.title,
            author: details.authors.first?.name, progress: showsProgress && progress > 0 ? progress : nil,
            isFinished: showsProgress && model.isFinished, accessibility: .hidden)
    }
}

/// The title with its badges, and the subtitle.
private struct ItemDetailHeader: View {
    let details: ItemDetailModel.Details

    var body: some View {
        VStack(alignment: .leading, spacing: ABSSpacing.xSmall) {
            HStack(alignment: .firstTextBaseline, spacing: ABSSpacing.xSmall) {
                Text(verbatim: details.title)
                    .font(.title2.bold())
                    .accessibilityAddTraits(.isHeader)
                if details.isExplicit { ExplicitBadge() }
                if details.isAbridged { AbridgedBadge() }
            }
            .font(.title2)
            .accessibilityElement(children: .combine)
            if let subtitle = details.subtitle {
                Text(verbatim: subtitle)
                    .font(.title3)
                    .foregroundStyle(ABSColor.mutedForeground)
            }
        }
    }
}

/// Play (or Resume, Play again, Missing), Read and Download.
///
/// Play goes through the environment's `playItem`, which is `nil` while signed out (and until
/// the shell provides it), so the button is disabled then. Read stays disabled until the ebook
/// readers exist, and Download until downloads exist.
private struct ItemDetailActions: View {
    let model: ItemDetailModel
    @Environment(\.playItem) private var playItem
    @State private var isStarting = false

    var body: some View {
        let play = ItemDetailPlayPresentation(
            button: model.playButton, isMissing: model.isMissing, canPlay: playItem != nil && !isStarting)
        HStack(spacing: ABSSpacing.small) {
            Button(action: start) {
                Label {
                    Text(verbatim: L10n.string(play.titleKey))
                } icon: {
                    Image(systemName: play.systemImage)
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!play.isEnabled)
            if model.hasEbook {
                Button {
                } label: {
                    Label {
                        Text(verbatim: L10n.string("ButtonRead"))
                    } icon: {
                        Image(systemName: "book")
                    }
                    .labelStyle(.iconOnly)
                }
                .buttonStyle(.bordered)
                .disabled(!model.isReadEnabled)
            }
            if model.hasAudio {
                Button {
                    model.download()
                } label: {
                    Label {
                        Text(verbatim: L10n.string("LabelDownload"))
                    } icon: {
                        Image(systemName: "arrow.down.circle")
                    }
                    .labelStyle(.iconOnly)
                }
                .buttonStyle(.bordered)
                .disabled(!model.isDownloadAvailable)
            }
        }
        .controlSize(.large)
    }

    private func start() {
        guard let playItem else { return }
        let itemID = model.itemID
        // `0` for Play again, so a finished book starts over; `nil` resumes from the server's
        // position.
        let startTime = model.playStartTime
        isStarting = true
        Task {
            defer { isStarting = false }
            do {
                try await playItem(itemID: itemID, startTime: startTime)
            } catch {
                // The player owns the error UI (#183); there's nothing to show here.
                Log.playback.error(
                    "Couldn't play \(itemID, privacy: .private(mask: .hash)): \(error.localizedDescription, privacy: .private)"
                )
            }
        }
    }
}

/// The user's progress: a bar with the percentage, and the time left or when they finished.
private struct ItemDetailProgress: View {
    let model: ItemDetailModel
    @Environment(\.locale) private var locale

    var body: some View {
        let fraction = model.progressFraction
        if let text = ItemDetailProgressText(
            fraction: fraction, isFinished: model.isFinished, timeRemaining: model.timeRemaining,
            finishedAt: model.finishedAt, locale: locale)
        {
            VStack(alignment: .leading, spacing: ABSSpacing.xSmall) {
                HStack {
                    Text(verbatim: L10n.string("LabelYourProgress"))
                    Spacer(minLength: ABSSpacing.small)
                    Text(verbatim: text.percent)
                        .monospacedDigit()
                }
                .font(.subheadline.weight(.semibold))
                ProgressView(value: model.isFinished ? 1 : min(max(fraction, 0), 1))
                    .tint(model.isFinished ? ABSColor.success : ABSColor.progress)
                    .accessibilityHidden(true)
                if let detail = text.detail {
                    Text(verbatim: detail)
                        .font(.footnote)
                        .foregroundStyle(ABSColor.mutedForeground)
                }
            }
            .padding(ABSSpacing.medium)
            .background(ABSColor.secondarySurface, in: .rect(cornerRadius: ABSRadius.medium))
            .accessibilityElement(children: .combine)
        }
    }
}

/// Shown above the retained item when a reload fails.
private struct ItemDetailRefreshFailedBanner: View {
    let retry: () -> Void

    var body: some View {
        HStack(spacing: ABSSpacing.medium) {
            Label {
                Text(verbatim: L10n.string("MessageItemDetailRefreshFailed"))
            } icon: {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(ABSColor.mutedForeground)
                    .accessibilityHidden(true)
            }
            Spacer(minLength: ABSSpacing.small)
            Button(action: retry) {
                Text(verbatim: L10n.string("ButtonRetry"))
            }
            .buttonStyle(.borderless)
        }
        .font(.footnote)
        .padding(ABSSpacing.medium)
        .background(ABSColor.secondarySurface, in: .rect(cornerRadius: ABSRadius.medium))
    }
}
