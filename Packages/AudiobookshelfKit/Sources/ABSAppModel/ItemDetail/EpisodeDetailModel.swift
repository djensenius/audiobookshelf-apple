import ABSAPI
import ABSCore
import Foundation
import Observation

/// The episode detail screen (legacy `pages/item/_id/_episode/index.vue`): one episode of a
/// podcast, its show notes, the user's progress on it, and what Play and the More menu offer.
///
/// - Loading belongs to the wrapped ``ItemDetailModel``, which fetches the podcast; the episode
///   is read from it on every access, so a reload shows here, and a late reply to an older load
///   is dropped there.
/// - Progress is read from the ``ProgressCache`` on every access, for this episode only.
///
/// Like ``ItemDetailModel``, it belongs to one item and account.
@MainActor
@Observable
public final class EpisodeDetailModel {
    /// The podcast, its loading state and its refresh.
    public let detail: ItemDetailModel
    public let episodeID: String
    @ObservationIgnored private let cache: ProgressCache

    /// - Parameters:
    ///   - detail: The podcast's model, which loads it.
    ///   - episodeID: The episode the screen shows.
    ///   - cache: The account's progress, the same cache `detail` reads.
    public init(detail: ItemDetailModel, episodeID: String, cache: ProgressCache) {
        self.detail = detail
        self.episodeID = episodeID
        self.cache = cache
    }

    // MARK: Episode

    public var itemID: String { detail.itemID }
    /// `nil` until loaded, and for items that aren't podcasts.
    public var podcast: Podcast? { detail.item?.podcast }
    /// `nil` until loaded, and when the podcast has no such episode.
    public var episode: PodcastEpisode? { podcast?.episodes?.first { $0.id == episodeID } }
    /// The podcast loaded without this episode (deleted on the server), or the item isn't a
    /// podcast, so the screen says the episode wasn't found (legacy redirected to the podcast).
    public var isEpisodeMissing: Bool { detail.hasLoaded && episode == nil }
    /// The podcast's title, `nil` when blank.
    public var podcastTitle: String? { Self.nonEmpty(podcast?.metadata.title) }
    /// The show notes' HTML, for ABSUI's `HTMLText`; `nil` when blank.
    public var showNotesHTML: String? { Self.nonEmpty(episode?.description) }
    /// The episode as the play and progress actions take it; `nil` until loaded.
    public var summary: ItemSummary? {
        guard let item = detail.item, let episode else { return nil }
        return ItemSummary(item: item, episode: episode)
    }

    // MARK: Progress

    /// The user's progress on the episode. Reading it registers observation of this episode only.
    public var progress: MediaProgress? {
        cache.progress(libraryItemID: itemID, episodeID: episodeID)
    }

    /// `0...1`, `1` when finished, as on cells (``ItemProgress``).
    public var progressFraction: Double { progress.map { ItemProgress($0).fraction } ?? 0 }
    public var isFinished: Bool { progress?.isFinished ?? false }

    /// When the user finished the episode, if they did and the server recorded it.
    public var finishedAt: Date? {
        guard let progress, progress.isFinished, let finishedAt = progress.finishedAt, finishedAt > 0 else {
            return nil
        }
        return Date(timeIntervalSince1970: Double(finishedAt) / 1000)
    }

    /// What the episode rows show: the duration, the time left, or finished; `nil` until loaded.
    public var status: PodcastDetailModel.EpisodeStatus? {
        episode.map { PodcastDetailModel.status(for: $0, progress: progress) }
    }

    /// Seconds left while in progress (legacy `userTimeRemaining`), else `nil`.
    public var timeRemaining: TimeInterval? {
        if case .inProgress(let remaining) = status { return remaining }
        return nil
    }

    // MARK: Actions

    /// The podcast is on the server and has this episode. `isGone` is the screen's remembered
    /// 404 (the app's `ItemDetailGoneState`); a current 404 counts as gone either way.
    public func isPresent(isGone: Bool) -> Bool {
        guard let item = detail.item, episode != nil else { return false }
        return !item.isMissing && !item.isInvalid && !isGone && (detail.error as? APIError) != .notFound
    }

    /// The primary button: Play, Resume once started, Play Again once finished; unavailable until
    /// the episode loads, and while the podcast is missing or invalid on the server.
    public var playButton: ItemDetailModel.PlayButton {
        guard let item = detail.item, episode != nil, !item.isMissing, !item.isInvalid else { return .unavailable }
        if isFinished { return .playAgain }
        if case .inProgress = status { return .resume }
        return .play
    }

    /// `0` for ``ItemDetailModel/PlayButton/playAgain``, so a finished episode starts over;
    /// `nil` otherwise, so playback resumes from the server's position.
    public var playStartTime: TimeInterval? { playButton == .playAgain ? 0 : nil }

    /// The More menu's entries, in menu order (legacy `moreMenuItems`):
    ///
    /// - Mark as finished, or Mark as not finished once finished, and Discard progress with any
    ///   progress, only while the episode is present (``isPresent(isGone:)``).
    /// - Add to playlist only when the caller can perform it.
    /// - Share whenever the caller can, even for a deleted episode.
    /// - Nothing until the episode loads.
    public func menuActions(canEditPlaylists: Bool, canShare: Bool, isGone: Bool) -> [ItemDetailMenuAction] {
        guard episode != nil else { return [] }
        var actions: [ItemDetailMenuAction] = []
        if isPresent(isGone: isGone) {
            actions.append(isFinished ? .markNotFinished : .markFinished)
            if progressFraction > 0 { actions.append(.discardProgress) }
            if canEditPlaylists { actions.append(.addToPlaylist) }
        }
        if canShare { actions.append(.share) }
        return actions
    }

    /// The key of the question to ask before `action`, or `nil` to perform it straight away, as
    /// on the book screen: marking finished over progress, and discarding.
    public func confirmationMessageKey(for action: ItemDetailMenuAction) -> String? {
        switch action {
        case .markFinished: !isFinished && progressFraction > 0 ? "MessageConfirmMarkAsFinished" : nil
        case .discardProgress: "MessageConfirmDiscardProgress"
        case .markNotFinished, .hideFromContinueListening, .addToPlaylist, .share, .details, .history: nil
        }
    }

    private nonisolated static func nonEmpty(_ text: String?) -> String? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }
}
