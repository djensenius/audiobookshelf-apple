import ABSAppModel
import ABSCore
import ABSUI
import SwiftUI

/// The top of the podcast screen (legacy `index.vue` with a podcast): the cover, the title with
/// its Explicit badge, Next Episode, the metadata and the description. Compact width, or any
/// width too narrow for two columns (``ItemDetailLayout``, as on the book screen), stacks them;
/// otherwise the cover and Next Episode sit beside the rest.
struct PodcastDetailHeader: View {
    let model: PodcastDetailModel
    /// The screen's scroll view width; `nil` until measured.
    let width: CGFloat?
    /// Next Episode can start: there is a player, the podcast is still on the server, and no
    /// other episode is starting.
    let canPlay: Bool
    /// Next Episode is starting.
    let isStarting: Bool
    let playNext: () -> Void
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.locale) private var locale

    var body: some View {
        if ItemDetailLayout.usesStackedLayout(width: width, sizeClass: horizontalSizeClass) {
            VStack(alignment: .leading, spacing: ABSSpacing.large) {
                cover
                    .frame(maxWidth: 240)
                    .frame(maxWidth: .infinity)
                title
                nextEpisode
                details
            }
        } else {
            HStack(alignment: .top, spacing: ABSSpacing.xLarge) {
                VStack(alignment: .leading, spacing: ABSSpacing.large) {
                    cover
                    nextEpisode
                }
                .frame(width: 240)
                VStack(alignment: .leading, spacing: ABSSpacing.large) {
                    title
                    details
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var cover: some View {
        PodcastDetailCover(summary: model.summary, title: model.title, author: model.author)
    }

    private var title: some View {
        HStack(alignment: .firstTextBaseline, spacing: ABSSpacing.xSmall) {
            Text(verbatim: model.title)
                .font(.title2.bold())
                .accessibilityAddTraits(.isHeader)
            if model.isExplicit { ExplicitBadge() }
        }
        .accessibilityElement(children: .combine)
    }

    /// Shown while the podcast can play (legacy `showPlay`); disabled without a player.
    @ViewBuilder private var nextEpisode: some View {
        if model.canPlay {
            Button(action: playNext) {
                Label {
                    Text(verbatim: L10n.string("ButtonNextEpisode"))
                } icon: {
                    if isStarting {
                        ProgressView()
                    } else {
                        Image(systemName: "play.fill")
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!canPlay)
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: ABSSpacing.large) {
            ItemDetailMetadata(rows: PodcastDetailPresentation.metadataRows(for: model, locale: locale))
            if let description = model.descriptionHTML {
                VStack(alignment: .leading, spacing: ABSSpacing.small) {
                    Text(verbatim: L10n.string("LabelDescription"))
                        .font(.headline)
                        .accessibilityAddTraits(.isHeader)
                    ExpandableText(html: description)
                }
            }
        }
    }
}

/// The square cover through the environment's image pipeline; hidden from VoiceOver, since the
/// title speaks for it.
private struct PodcastDetailCover: View {
    let summary: ItemSummary?
    let title: String
    let author: String?
    @Environment(\.serverID) private var serverID

    var body: some View {
        CoverView(
            key: serverID.flatMap { summary?.coverKey(serverID: $0, bucket: .medium) }, title: title,
            author: author, shape: .square, accessibility: .hidden)
    }
}
