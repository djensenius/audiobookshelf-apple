import ABSCore
import ABSData
import ABSRealtime
import Observation

/// The "Jump to latest position" offer (#59): newer progress from another session for the item
/// the player has open and paused, which ``RealtimeBridge/onRemoteProgress`` delivers. The player
/// doesn't seek on its own, unlike the legacy `layouts/default.vue`; it seeks only if the user
/// accepts.
///
/// A newer offer replaces the pending one. The offer ends when the user accepts or dismisses it,
/// and on its own once playback starts or the player's media changes.
@MainActor
@Observable
public final class RemoteProgressOffer {
    /// Another session's position for the media the player has open.
    public struct Pending: Sendable, Hashable {
        public var key: MediaKey
        /// Global seconds.
        public var position: Double
        /// The other session's device, as the server describes it.
        public var deviceDescription: String?

        public init(key: MediaKey, position: Double, deviceDescription: String? = nil) {
            self.key = key
            self.position = position
            self.deviceDescription = deviceDescription
        }
    }

    /// The offer, until it's accepted, dismissed or ends. It's cleared on the turn after playback
    /// starts or the media changes; ``shown`` drops it at once.
    public private(set) var pending: Pending?

    /// ``pending`` while the player still has its media open and paused; what to present.
    public var shown: Pending? {
        guard let pending, stillApplies(pending) else { return nil }
        return pending
    }

    @ObservationIgnored private let playback: any PlayerPlaybackControlling
    @ObservationIgnored private var isTracking = false

    public init(playback: any PlayerPlaybackControlling) {
        self.playback = playback
    }

    /// Offers `update`'s position, if the player has its media open and paused.
    public func offer(_ update: UserItemProgressUpdate) {
        let progress = update.progress
        guard let key = playback.mediaKey, key.libraryItemId == progress.libraryItemId,
            key.episodeId == progress.episodeId, !playback.isPlaybackRequested
        else { return }
        pending = Pending(key: key, position: progress.currentTime, deviceDescription: update.deviceDescription)
        track()
    }

    /// Newer progress from another session that offers no jump, such as one back at the player's
    /// position: ends the offer for its media.
    public func supersede(_ update: UserItemProgressUpdate) {
        guard let pending, pending.key.libraryItemId == update.progress.libraryItemId,
            pending.key.episodeId == update.progress.episodeId
        else { return }
        self.pending = nil
    }

    /// Accepts `offer`, the one the user was shown. Unless a newer offer replaced it, it ends, and
    /// the player seeks to its position if it still has the media open and paused when the seek
    /// runs. Returns the seek, if it started one.
    @discardableResult
    public func accept(_ offer: Pending) -> Task<Void, Never>? {
        guard offer == pending else { return nil }
        pending = nil
        guard stillApplies(offer) else { return nil }
        return Task { [weak self] in
            guard let self, self.stillApplies(offer) else { return }
            await self.playback.seek(to: offer.position)
        }
    }

    /// Ends the offer without seeking.
    public func dismiss() {
        pending = nil
    }

    private func stillApplies(_ offer: Pending) -> Bool {
        playback.mediaKey == offer.key && !playback.isPlaybackRequested
    }

    /// Ends the offer once playback starts or the media changes. Observation reports a change
    /// before it's made, so the new state is checked on the next turn.
    private func track() {
        guard !isTracking else { return }
        isTracking = true
        withObservationTracking {
            _ = playback.mediaKey
            _ = playback.isPlaybackRequested
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.isTracking = false
                if let pending = self.pending, !self.stillApplies(pending) { self.pending = nil }
                if self.pending != nil { self.track() }
            }
        }
    }
}
