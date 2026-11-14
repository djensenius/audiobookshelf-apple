import ABSCore
import ABSData
import ABSPlayback
import Foundation

/// What an account session's playback scope lends its readers: the server read for
/// ``EbookProgressModel/resume()`` and the progress syncer that sends saved rows.
public struct EbookProgressSources {
    public let service: any EbookProgressService
    public let syncer: any ProgressDraining

    public init(service: any EbookProgressService, syncer: any ProgressDraining) {
        self.service = service
        self.syncer = syncer
    }
}

/// Builds the ``EbookProgressModel`` for a book opened during one account session (#102, #104):
/// over the one local progress store and that session's syncer, so ebook rows are saved and sent
/// like playback rows (ADR 0003). ``PlaybackSessionParticipant/ebookProgress`` holds one per
/// session.
///
/// It serves only its own connection: a key for another (a reader opened for account A while B's
/// session runs) gets `nil`, so a reader never writes one account's progress under another.
///
/// A book downloaded on this connection links its row to the downloaded item on each save, as the
/// download manager links an existing row when a download completes (#74), so
/// `LocalProgressStore.pruneSynced()` keeps it for an offline reopen.
@MainActor
public final class EbookProgressFactory {
    public let serverConnectionID: UUID
    private let store: LocalProgressStore
    private let sources: EbookProgressSources
    private let localItems: (any LocalItemReading)?

    /// - Parameters:
    ///   - store: The local progress store `sources.syncer` drains.
    ///   - localItems: The downloaded items (the scopes' `LocalDownloadFiles/items`); `nil` links
    ///     no row.
    public init(
        serverConnectionID: UUID, store: LocalProgressStore, sources: EbookProgressSources,
        localItems: (any LocalItemReading)? = nil
    ) {
        self.serverConnectionID = serverConnectionID
        self.store = store
        self.sources = sources
        self.localItems = localItems
    }

    /// The progress model for `key`, read as `kind`, seeded with `serverProgress`; `nil` when
    /// `key` belongs to another connection.
    public func callAsFunction(_ key: MediaKey, _ kind: ReaderKind, _ serverProgress: MediaProgress?)
        -> EbookProgressModel?
    {
        guard key.serverConnectionID == serverConnectionID else { return nil }
        let localItems = localItems
        return EbookProgressModel(
            key: key, kind: kind, store: store, service: sources.service, syncer: sources.syncer,
            localLibraryItemID: { try await Self.downloadedItemID(of: key, in: localItems) },
            serverProgress: serverProgress)
    }

    /// The downloaded item holding `key`'s media on its connection, by the download manager's
    /// test: a book's audio or ebook file, or an episode's file; `nil` when there is none.
    /// Throws when the store can't be read.
    nonisolated static func downloadedItemID(of key: MediaKey, in items: (any LocalItemReading)?) async throws
        -> UUID?
    {
        guard
            let item = try await items?.item(
                serverConnectionID: key.serverConnectionID, libraryItemId: key.libraryItemId)
        else { return nil }
        let holds =
            if let episodeID = key.episodeId {
                item.files.contains { $0.episodeId == episodeID }
            } else {
                item.files.contains { $0.kind == .audio || $0.kind == .ebook }
            }
        return holds ? item.id : nil
    }
}

/// The server read follows the scope's reconnects.
extension AccountPlaybackServices: EbookProgressService {}
