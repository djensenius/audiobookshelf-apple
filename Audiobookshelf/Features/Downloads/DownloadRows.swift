import ABSAppModel
import ABSCore
import ABSUI
import SwiftUI

/// The space the downloads take and the space left on the device.
struct DownloadsStorageRow: View {
    let used: Int64
    let available: Int64?

    var body: some View {
        VStack(alignment: .leading, spacing: ABSSpacing.xSmall) {
            Text(verbatim: L10n.string("LabelDownloadsUsed", ByteCountFormatting.string(fromBytes: used)))
                .font(.headline)
            if let available {
                Text(verbatim: L10n.string("LabelDownloadsAvailable", ByteCountFormatting.string(fromBytes: available)))
                    .font(.subheadline)
                    .foregroundStyle(ABSColor.mutedForeground)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// How far the downloads under way are, as a ring around their count (legacy
/// `components/widgets/DownloadProgressIndicator.vue`).
struct DownloadProgressIndicator: View {
    let fraction: Double
    let count: Int

    var body: some View {
        ZStack {
            Circle()
                .stroke(ABSColor.mutedForeground.opacity(0.3), lineWidth: 2)
            Circle()
                .trim(from: 0, to: min(max(fraction, 0), 1))
                .stroke(ABSColor.accent, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text(verbatim: count.formatted())
                .font(.caption2.monospacedDigit())
        }
        .frame(width: 22, height: 22)
        .accessibilityHidden(true)
    }
}

/// One download under way (legacy `components/modals/downloads/DownloadItem.vue`).
struct DownloadQueueRow: View {
    let download: DownloadsListing.Download

    var body: some View {
        VStack(alignment: .leading, spacing: ABSSpacing.xSmall) {
            Text(verbatim: download.title)
                .lineLimit(2)
            if let subtitle = download.subtitle {
                Text(verbatim: subtitle)
                    .font(.caption)
                    .foregroundStyle(ABSColor.mutedForeground)
                    .lineLimit(1)
            }
            switch download.status {
            case .downloading(let fraction):
                ProgressView(value: fraction)
            case .queued:
                statusText(L10n.string("LabelDownloadStatusQueued"))
            case .paused:
                statusText(L10n.string("LabelDownloadStatusPaused"))
            case .failed:
                statusText(L10n.string("LabelDownloadStatusFailed"))
            }
            if download.expectedBytes > 0 {
                Text(verbatim: sizes)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(ABSColor.mutedForeground)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var sizes: String {
        let written = ByteCountFormatting.string(fromBytes: min(download.bytesWritten, download.expectedBytes))
        return "\(written) / \(ByteCountFormatting.string(fromBytes: download.expectedBytes))"
    }

    private func statusText(_ text: String) -> some View {
        Text(verbatim: text)
            .font(.caption)
            .foregroundStyle(ABSColor.mutedForeground)
    }
}

/// A downloaded book or podcast: cover, title, author, and what was kept with its size.
struct DownloadedItemRow: View {
    let item: DownloadsListing.Item
    let serverID: UUID?

    var body: some View {
        HStack(spacing: ABSSpacing.medium) {
            CoverView(
                key: coverKey, title: item.title, author: item.author,
                shape: item.mediaType == .podcast ? .square : .book, accessibility: .hidden
            )
            .frame(width: 48)
            VStack(alignment: .leading, spacing: ABSSpacing.xxSmall) {
                Text(verbatim: item.title)
                    .lineLimit(2)
                if let author = item.author {
                    Text(verbatim: author)
                        .font(.subheadline)
                        .foregroundStyle(ABSColor.mutedForeground)
                        .lineLimit(1)
                }
                Text(verbatim: details)
                    .font(.caption)
                    .foregroundStyle(ABSColor.mutedForeground)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var coverKey: ImageKey? {
        guard let serverID else { return nil }
        return CoverRef(entityID: item.libraryItemId, updatedAt: item.coverVersion)
            .key(serverID: serverID, bucket: .small)
    }

    /// For example "12 tracks · Ebook · 412 MB", or "3 episodes · 120 MB".
    private var details: String {
        var parts: [String] = []
        if item.mediaType == .podcast {
            parts.append(
                L10n.plural("LabelPodcastEpisodeCount", count: item.episodes.count, item.episodes.count.formatted()))
        } else if item.trackCount > 0 {
            parts.append(L10n.plural("LabelDownloadTrackCount", count: item.trackCount, item.trackCount.formatted()))
        }
        if item.hasEbook { parts.append(L10n.string("LabelEbook")) }
        parts.append(ByteCountFormatting.string(fromBytes: item.byteCount))
        return parts.joined(separator: " · ")
    }
}

/// A downloaded podcast episode with its size.
struct DownloadedEpisodeRow: View {
    let episode: DownloadsListing.Episode

    var body: some View {
        VStack(alignment: .leading, spacing: ABSSpacing.xxSmall) {
            Text(verbatim: episode.title)
                .lineLimit(2)
            Text(verbatim: details)
                .font(.caption)
                .foregroundStyle(ABSColor.mutedForeground)
        }
        .padding(.leading, ABSSpacing.large)
        .accessibilityElement(children: .combine)
    }

    private var details: String {
        let size = ByteCountFormatting.string(fromBytes: episode.byteCount)
        guard let published = episode.publishedAt else { return size }
        return "\(published.formatted(date: .abbreviated, time: .omitted)) · \(size)"
    }
}
