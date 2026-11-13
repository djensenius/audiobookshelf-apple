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
@MainActor
public final class EbookProgressFactory {
    public let serverConnectionID: UUID
    private let store: LocalProgressStore
    private let sources: EbookProgressSources

    /// - Parameters:
    ///   - store: The local progress store `sources.syncer` drains.
    public init(serverConnectionID: UUID, store: LocalProgressStore, sources: EbookProgressSources) {
        self.serverConnectionID = serverConnectionID
        self.store = store
        self.sources = sources
    }

    /// The progress model for `key`, read as `kind`, seeded with `serverProgress`; `nil` when
    /// `key` belongs to another connection.
    public func callAsFunction(_ key: MediaKey, _ kind: ReaderKind, _ serverProgress: MediaProgress?)
        -> EbookProgressModel?
    {
        guard key.serverConnectionID == serverConnectionID else { return nil }
        return EbookProgressModel(
            key: key, kind: kind, store: store, service: sources.service, syncer: sources.syncer,
            serverProgress: serverProgress)
    }
}

/// The server read follows the scope's reconnects.
extension AccountPlaybackServices: EbookProgressService {}
