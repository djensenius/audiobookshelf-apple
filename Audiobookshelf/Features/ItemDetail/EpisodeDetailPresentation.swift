import ABSAppModel
import ABSCore
import ABSUI
import Foundation

/// What ``EpisodeDetailScreen`` shows, from ``EpisodeDetailPresentation/screen(for:)``.
enum EpisodeDetailScreenState: Equatable {
    /// The episode, once its podcast has loaded with it.
    case episode
    /// A load is in flight, or none has run yet.
    case loading
    /// The last load failed for a reason other than the podcast being gone; retry.
    case failed
    /// The podcast loaded without the episode, or the server answered 404; retry.
    case notFound
}

/// The episode screen's text and rules, kept apart from the view so they can be tested.
enum EpisodeDetailPresentation {
    /// Which state the screen shows. A loaded episode stays on screen through refreshes (their
    /// failures show as a banner, and a 404 turns its actions off through
    /// ``ItemDetailGoneState``). Without one, a load in flight shows loading, so a retry from
    /// not found or failed shows its spinner; then a failure other than a 404 shows failed, so a
    /// retry that times out isn't reported as gone; then a load that succeeded without the
    /// episode, or a 404, shows not found.
    @MainActor
    static func screen(for model: EpisodeDetailModel) -> EpisodeDetailScreenState {
        let detail = model.detail
        if model.episode != nil { return .episode }
        if detail.isLoading { return .loading }
        if let error = detail.error {
            return ItemDetailLoadError.isNotFound(error) ? .notFound : .failed
        }
        if model.isEpisodeMissing { return .notFound }
        return .loading
    }

    /// Plays the episode through `play`, from the server's position, or from the start once
    /// finished (``EpisodeDetailModel/playStartTime``). Returns what the alert shows when that
    /// fails, or `nil` once it starts or is cancelled.
    @MainActor
    static func startPlayback(of model: EpisodeDetailModel, with play: PlayItemAction) async
        -> ItemDetailPlayFailure?
    {
        let itemID = model.itemID
        let episodeID = model.episodeID
        do {
            try await play(itemID: itemID, episodeID: episodeID, startTime: model.playStartTime)
            return nil
        } catch {
            guard let failure = ItemDetailPlayFailure(error: error) else { return nil }
            Log.playback.error(
                "Couldn't play \(itemID, privacy: .private(mask: .hash)) episode \(episodeID, privacy: .private(mask: .hash)): \(failure.message, privacy: .private)"
            )
            return failure
        }
    }

    /// The show notes as attributed text: ABSUI's ``HTMLText`` subset, so http and https links
    /// are kept, while images, scripts, styles and other links are dropped and nothing is loaded
    /// from the network. `nil` when there's nothing to show.
    nonisolated static func showNotes(html: String?) -> AttributedString? {
        guard let html else { return nil }
        let text = HTMLText.attributedString(from: html)
        guard !String(text.characters).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return text
    }

    /// The line under the title: when it was published and how long it is, as legacy showed the
    /// published date; the parts that are known, joined with " · ".
    static func detailLine(_ episode: PodcastEpisode, locale: Locale) -> String? {
        var parts: [String] = []
        if let published = PodcastDetailPresentation.publishedText(episode.publishedAt, locale: locale) {
            parts.append(published)
        }
        if let duration = episode.duration, duration.isFinite, duration > 0 {
            let text = DurationStyle.elapsed(showSeconds: false).string(duration, locale: locale)
            if !text.isEmpty { parts.append(text) }
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// The Play button: the book screen's labels, for the episode's ``EpisodeDetailModel/playButton``.
    /// `canPlay` is a `playItem` action (`nil` while signed out), no start in progress, and the
    /// podcast not gone from the server (``ItemDetailGoneState``).
    @MainActor
    static func play(for model: EpisodeDetailModel, canPlay: Bool, isGone: Bool) -> ItemDetailPlayPresentation {
        ItemDetailPlayPresentation(
            button: model.playButton, isMissing: model.detail.isMissing, canPlay: canPlay && !isGone)
    }

    /// What Share links to: the podcast's page in the web client, which shows episodes in a
    /// dialog rather than at their own address.
    @MainActor
    static func shareURL(serverURL: URL, itemID: String) -> URL {
        ItemDetailModel.webURL(serverURL: serverURL, itemID: itemID)
    }
}
