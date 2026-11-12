import ABSAppModel
import ABSCore
import ABSUI
import Foundation

/// The episode screen's text and rules, kept apart from the view so they can be tested.
enum EpisodeDetailPresentation {
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
