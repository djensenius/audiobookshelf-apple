import ABSAppModel
import ABSUI
import SwiftUI

/// Sets `itemDownloadReader`, the downloaded mark on item cards and rows, from one
/// ``DownloadedItemsFeed`` of `connectionID`: the shell observes the connection's downloaded items
/// once, and every cell reads them, so a completed download or a deletion shows without a reload.
///
/// Only completed downloads count (``ItemDownloadState/isDownloaded(libraryItemID:episodeID:connectionID:localItems:)``).
/// Without a download stack, or a connection (signed out, or a switch's outgoing shell), it knows
/// no downloads.
struct DownloadedItemsEnvironment: ViewModifier {
    /// The connection whose downloads are marked; `nil` marks none.
    let connectionID: UUID?
    @Environment(\.downloads) private var downloads
    @State private var feed: DownloadedItemsFeed?
    /// Built once per feed, so a body evaluation hands the cells the same reader.
    @State private var reader = ItemDownloadReader.none

    func body(content: Content) -> some View {
        content
            // Until the task below replaces a feed of the previous connection, mark nothing.
            .environment(\.itemDownloadReader, feed?.connectionID == connectionID ? reader : .none)
            .task(id: connectionID) {
                guard let connectionID, let downloads else {
                    feed = nil
                    reader = .none
                    return
                }
                let feed = DownloadedItemsFeed(connectionID: connectionID, services: downloads)
                self.feed = feed
                reader = ItemDownloadReader { itemID, episodeID in
                    feed.isDownloaded(libraryItemID: itemID, episodeID: episodeID)
                }
                await feed.observe()
            }
    }
}
