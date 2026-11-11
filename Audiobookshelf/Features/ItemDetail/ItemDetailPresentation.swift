import ABSAPI
import ABSAppModel
import ABSUI
import Foundation

/// The primary button's label, icon and state for an ``ItemDetailModel/PlayButton``, kept apart
/// from the view so it can be tested.
struct ItemDetailPlayPresentation: Equatable {
    /// The `L10n` key of the label.
    let titleKey: String
    let systemImage: String
    let isEnabled: Bool

    /// - Parameters:
    ///   - button: The model's ``ItemDetailModel/playButton``.
    ///   - isMissing: The item is missing on the server, so an unavailable button says Missing,
    ///     as legacy does (`index.vue:69-72`).
    ///   - canPlay: The environment has a `playItem` action (`nil` while signed out) and no
    ///     playback request from this screen is still starting.
    init(button: ItemDetailModel.PlayButton, isMissing: Bool, canPlay: Bool) {
        switch button {
        case .play:
            titleKey = "ButtonPlay"
            systemImage = "play.fill"
        case .resume:
            titleKey = "ButtonItemDetailResume"
            systemImage = "play.fill"
        case .playAgain:
            titleKey = "ButtonItemDetailPlayAgain"
            systemImage = "arrow.counterclockwise"
        case .unavailable:
            titleKey = isMissing ? "LabelMissing" : "ButtonPlay"
            systemImage = isMissing ? "exclamationmark.triangle" : "play.fill"
        }
        isEnabled = button != .unavailable && canPlay
    }
}

/// The progress block's text: the percentage and the line under it.
struct ItemDetailProgressText: Equatable {
    /// "42%".
    let percent: String
    /// "3h 20m remaining", "Finished Nov 11, 2026", or `nil`.
    let detail: String?

    /// `nil` when there's nothing to show: no progress and not finished (legacy shows the block
    /// only above 0%, `index.vue:73`).
    init?(fraction: Double, isFinished: Bool, timeRemaining: TimeInterval?, finishedAt: Date?, locale: Locale) {
        guard fraction > 0 || isFinished else { return nil }
        let fraction = isFinished ? 1 : min(max(fraction, 0), 1)
        percent = fraction.formatted(.percent.precision(.fractionLength(0)).locale(locale))
        if isFinished {
            detail = finishedAt.map {
                L10n.string(
                    "LabelItemDetailFinishedAt",
                    $0.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted).locale(locale)))
            }
        } else if let timeRemaining {
            let remaining = DurationStyle.elapsed(showSeconds: false).string(timeRemaining, locale: locale)
            detail = remaining.isEmpty ? nil : L10n.string("LabelTimeRemaining", remaining)
        } else {
            detail = nil
        }
    }
}

enum ItemDetailLoadError {
    /// The server answered 404: the item was deleted or never existed.
    static func isNotFound(_ error: (any Error)?) -> Bool {
        (error as? APIError) == .notFound
    }
}

/// The banner over a retained item whose reload failed.
struct ItemDetailRefreshFailure: Equatable {
    /// The `L10n` key of the banner's message.
    let messageKey: String
    /// The reload answered 404, so the item is gone from the server and can't be played.
    let isGone: Bool

    /// `nil` unless the model's last reload failed.
    @MainActor init?(model: ItemDetailModel) {
        guard model.refreshFailed else { return nil }
        isGone = ItemDetailLoadError.isNotFound(model.error)
        messageKey = isGone ? "MessageItemDetailNotFound" : "MessageItemDetailRefreshFailed"
    }
}

/// A Play that failed to start, for the alert.
struct ItemDetailPlayFailure: Equatable {
    /// The error's description, shown under the alert's title.
    let message: String

    /// `nil` for a cancellation, which isn't a failure to tell anyone about.
    init?(error: any Error) {
        guard !(error is CancellationError) else { return nil }
        message = error.localizedDescription
    }
}
