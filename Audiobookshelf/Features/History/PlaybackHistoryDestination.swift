import ABSAppModel
import ABSCore
import ABSData
import ABSUI
import SwiftUI

extension EnvironmentValues {
    /// This device's recorded playback history, for ``PlaybackHistoryDestination``; `nil` where the
    /// app has no history store, and the screen then shows no history.
    @Entry var playbackHistorySource: PlaybackHistoryModel.EventSource?
}

/// The `Route.history(itemID:episodeID:)` screen: ``PlaybackHistoryView`` for the item, or its
/// episode, on the active server connection (`\.serverID`), reading `\.playbackHistorySource`.
/// Tapping an event plays from its position through `\.playItem`, which seeks in the current
/// session when the media is already loaded (legacy `history.vue`'s `play-item` with a start
/// time). Signed out, it says no server is connected.
struct PlaybackHistoryDestination: View {
    let itemID: String
    let episodeID: String?
    @Environment(\.serverID) private var serverID
    @Environment(\.playbackHistorySource) private var source
    @Environment(\.playItem) private var playItem

    var body: some View {
        if let key = Self.mediaKey(serverID: serverID, itemID: itemID, episodeID: episodeID) {
            // The view keeps its first model, so a new connection or player builds a new one.
            PlaybackHistoryView(model: Self.model(mediaKey: key, source: source, playItem: playItem))
                .id(ModelIdentity(mediaKey: key, canPlay: playItem != nil))
        } else {
            ContentUnavailableView {
                Label {
                    Text(verbatim: L10n.string("MessageAudiobookshelfServerNotConnected"))
                } icon: {
                    Image(systemName: "clock.arrow.circlepath")
                        .accessibilityHidden(true)
                }
            }
            .navigationTitle(Text(verbatim: L10n.string("ButtonHistory")))
        }
    }

    private struct ModelIdentity: Hashable {
        let mediaKey: MediaKey
        let canPlay: Bool
    }

    /// The media whose history to show on `serverID`'s connection; `nil` while signed out.
    static func mediaKey(serverID: UUID?, itemID: String, episodeID: String?) -> MediaKey? {
        serverID.map { MediaKey(serverConnectionID: $0, libraryItemId: itemID, episodeId: episodeID) }
    }

    /// One empty snapshot, then the end: no history to follow.
    private static let noHistory: PlaybackHistoryModel.EventSource = { _ in
        AsyncStream {
            $0.yield([])
            $0.finish()
        }
    }

    /// The model for `mediaKey`'s events from `source` (none without one), playing from an
    /// event's position with `playItem` (nothing without one).
    static func model(
        mediaKey: MediaKey, source: PlaybackHistoryModel.EventSource?, playItem: PlayItemAction?
    ) -> PlaybackHistoryModel {
        PlaybackHistoryModel(
            mediaKey: mediaKey,
            source: source ?? noHistory,
            playFromTime: { key, position in
                guard let playItem else { return }
                do {
                    try await playItem(itemID: key.libraryItemId, episodeID: key.episodeId, startTime: position)
                } catch {
                    Log.playback.error(
                        "Couldn't play history position of \(key.libraryItemId, privacy: .private(mask: .hash)): \(error, privacy: .private)"
                    )
                }
            })
    }
}

#Preview("Signed out") {
    NavigationStack { PlaybackHistoryDestination(itemID: "li_1", episodeID: nil) }
}

#Preview("No history") {
    NavigationStack { PlaybackHistoryDestination(itemID: "li_1", episodeID: nil) }
        .environment(\.serverID, UUID())
}
