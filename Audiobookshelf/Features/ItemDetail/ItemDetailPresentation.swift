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
                    $0.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted).locale(locale)), locale: locale)
            }
        } else if let timeRemaining {
            let remaining = DurationStyle.elapsed(showSeconds: false).string(timeRemaining, locale: locale)
            detail = remaining.isEmpty ? nil : L10n.string("LabelTimeRemaining", remaining, locale: locale)
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

/// Whether the retained item is gone from the server: a reload answered 404, and no reload has
/// succeeded since. It stays gone while a retry is pending and after a retry fails some other
/// way, both of which replace or hide the model's 404, so Play stays disabled until the item
/// loads again.
struct ItemDetailGoneState: Equatable {
    /// What the state follows from the model.
    struct Snapshot: Equatable {
        let hasLoaded: Bool
        let isLoading: Bool
        let hasError: Bool
        let isNotFound: Bool

        @MainActor init(model: ItemDetailModel) {
            hasLoaded = model.hasLoaded
            isLoading = model.isLoading
            hasError = model.error != nil
            isNotFound = ItemDetailLoadError.isNotFound(model.error)
        }
    }

    /// A 404 seen since the last successful load.
    private var sawNotFound = false

    /// Records `snapshot`; call it whenever the snapshot changes.
    mutating func update(_ snapshot: Snapshot) {
        sawNotFound = isGone(snapshot)
    }

    /// Whether the item is gone in `snapshot`, given the snapshots recorded so far. Reads the
    /// current 404 directly, so it's right before ``update(_:)`` records it.
    func isGone(_ snapshot: Snapshot) -> Bool {
        if snapshot.hasLoaded, snapshot.isNotFound { return true }
        // Only a load that finished without an error clears it.
        return sawNotFound && (snapshot.isLoading || snapshot.hasError)
    }
}

/// The banner over a retained item whose reload failed.
struct ItemDetailRefreshFailure: Equatable {
    /// The `L10n` key of the banner's message.
    let messageKey: String

    /// `nil` unless the model's last reload failed. `isGone` (``ItemDetailGoneState``) says the
    /// item isn't on the server anymore instead of that the reload failed.
    @MainActor init?(model: ItemDetailModel, isGone: Bool) {
        guard model.refreshFailed else { return nil }
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
