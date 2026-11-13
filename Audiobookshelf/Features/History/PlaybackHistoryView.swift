import ABSAppModel
import ABSCore
import ABSData
import ABSUI
import SwiftUI

/// The playback history recorded on this device for one item, grouped by day; tap an event to
/// play from its position. Port of `pages/media/_id/history.vue`, the destination of
/// `Route.history(itemID:episodeID:)`, for a book or one podcast episode.
struct PlaybackHistoryView: View {
    @State private var model: PlaybackHistoryModel
    @State private var tapCount = 0
    @Environment(AppSettings.self) private var settings: AppSettings?
    @Environment(\.scenePhase) private var scenePhase

    init(model: PlaybackHistoryModel) {
        _model = State(initialValue: model)
    }

    var body: some View {
        content
            .navigationTitle(Text(verbatim: L10n.string("ButtonHistory")))
            .navigationSubtitle(Text(verbatim: model.title ?? ""))
            .task(id: model.loadAttempt) { await model.observe() }
            // Keep "Today" and "Yesterday" right across midnight and time zone changes.
            .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged).receive(on: RunLoop.main)) {
                _ in
                model.regroup()
            }
            .onReceive(NotificationCenter.default.publisher(for: .NSSystemTimeZoneDidChange).receive(on: RunLoop.main))
        { _ in
            model.regroup()
        }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { model.regroup() }
            }
            .absHaptic(settings?.hapticFeedback ?? .off, trigger: tapCount)
    }

    @ViewBuilder private var content: some View {
        if !model.isLoaded {
            LoadingView()
        } else if model.error != nil {
            ErrorStateView(title: L10n.string("MessageHistoryLoadFailed"), retry: model.retry)
        } else if model.isEmpty {
            ContentUnavailableView {
                Label {
                    Text(verbatim: L10n.string("MessageNoHistory"))
                } icon: {
                    Image(systemName: "clock.arrow.circlepath")
                        .accessibilityHidden(true)
                }
            }
        } else {
            List {
                ForEach(model.sections) { section in
                    Section {
                        ForEach(section.rows) { row in
                            PlaybackHistoryRow(
                                row: row, canPlay: model.canPlay(row), isDisabled: model.isStartingPlayback
                            ) {
                                tapCount += 1
                                Task { await model.play(from: row) }
                            }
                        }
                    } header: {
                        Text(verbatim: Self.title(for: section))
                    }
                }
            }
        }
    }

    private static func title(for section: PlaybackHistoryModel.DaySection) -> String {
        switch section.day {
        case .today: L10n.string("LabelToday")
        case .yesterday: L10n.string("LabelYesterday")
        case .earlier: section.dateText
        }
    }
}

/// One event: time of day, event, sync outcome, collapsed count and position.
private struct PlaybackHistoryRow: View {
    let row: PlaybackHistoryModel.Row
    /// The row has a position and there is a player; otherwise it is disabled, without a play hint.
    let canPlay: Bool
    let isDisabled: Bool
    let play: () -> Void
    @Environment(\.locale) private var locale

    var body: some View {
        Button(action: play) {
            // Time, event and position on one line; one line each at accessibility sizes.
            AdaptiveStack(spacing: ABSSpacing.small) {
                Text(verbatim: row.timeText)
                    .font(.subheadline)
                    .monospacedDigit()
                    .foregroundStyle(ABSColor.mutedForeground)
                HStack(spacing: ABSSpacing.small) {
                    Image(systemName: row.name.systemImage)
                        .foregroundStyle(row.name.tint)
                    Text(verbatim: row.name.label)
                    if let image = row.sync.systemImage {
                        Image(systemName: image)
                            .foregroundStyle(row.sync == .succeeded ? ABSColor.success : ABSColor.error)
                    }
                    if row.collapsedCount > 0 {
                        Text(verbatim: "+" + row.collapsedCount.formatted(.number.locale(locale)))
                            .font(.subheadline)
                            .italic()
                            .foregroundStyle(ABSColor.mutedForeground)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if let positionText = row.positionText {
                    Text(verbatim: positionText)
                        .monospacedDigit()
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(!canPlay || isDisabled)
        // Set on the button itself so VoiceOver keeps its action; the label replaces the
        // children's text.
        .accessibilityLabel(Text(verbatim: accessibilityLabel))
        .accessibilityValue(Text(verbatim: accessibilityValue))
        .accessibilityHint(Text(verbatim: canPlay ? L10n.string("LabelHistoryPlayFromHint") : ""))
    }

    private var accessibilityLabel: String {
        guard let position = row.shownPosition else {
            return L10n.string("LabelHistoryEventNoPositionAccessibility", row.name.label, row.timeText)
        }
        let spoken = DurationStyle.timestamp.accessibilityString(position, locale: locale)
        return L10n.string("LabelHistoryEventAccessibility", row.name.label, spoken, row.timeText)
    }

    private var accessibilityValue: String {
        var parts: [String] = []
        switch row.sync {
        case .notAttempted: break
        case .succeeded: parts.append(L10n.string("LabelHistorySynced"))
        case .failed: parts.append(L10n.string("LabelHistorySyncFailed"))
        }
        if row.collapsedCount > 0 {
            parts.append(L10n.string("LabelHistoryMoreEvents", row.collapsedCount.formatted(.number.locale(locale))))
        }
        return parts.formatted(.list(type: .and).locale(locale))
    }
}

extension PlaybackHistoryEventName {
    /// Event nouns ("Play", "Finished") have their own `LabelHistoryEvent*` keys instead of
    /// reusing `ButtonPlay` or `LabelFinished`: a language can translate the noun for a logged
    /// event differently from a button's verb or a status.
    fileprivate var label: String {
        switch self {
        case .play: L10n.string("LabelHistoryEventPlay")
        case .pause: L10n.string("LabelHistoryEventPause")
        case .stop: L10n.string("LabelHistoryEventStop")
        case .seek: L10n.string("LabelHistoryEventSeek")
        case .save: L10n.string("LabelHistoryEventSave")
        case .finished: L10n.string("LabelHistoryEventFinished")
        case .sync: L10n.string("LabelHistoryEventSync")
        }
    }

    /// The legacy page's Material icons, as SF Symbols.
    fileprivate var systemImage: String {
        switch self {
        case .play: "play.circle.fill"
        case .pause: "pause.circle.fill"
        case .stop: "stop.circle.fill"
        case .seek: "arrow.left.and.right.circle"
        case .save: "arrow.triangle.2.circlepath"
        case .finished: "checkmark.circle.fill"
        case .sync: "icloud.and.arrow.down"
        }
    }

    fileprivate var tint: Color {
        switch self {
        case .play: ABSColor.success
        case .stop: ABSColor.error
        case .sync: ABSColor.accent
        case .pause, .seek: .secondary
        case .save, .finished: ABSColor.info
        }
    }
}

extension PlaybackHistoryModel.SyncStatus {
    fileprivate var systemImage: String? {
        switch self {
        case .notAttempted: nil
        case .succeeded: "checkmark.icloud"
        case .failed: "exclamationmark.circle"
        }
    }
}

// MARK: - Previews

#Preview("History") {
    let key = MediaKey(serverConnectionID: UUID(), libraryItemId: "li_1")
    let now = Date.now
    let samples: [(PlaybackHistoryEventName, TimeInterval, Double, Bool, Bool?)] = [
        (.pause, 0, 3723, true, true),
        (.save, 15, 3708, true, true),
        (.save, 30, 3693, true, true),
        (.seek, 600, 3600, false, nil),
        (.play, 900, 3000, false, nil),
        (.stop, 90_000, 2990, true, false),
        (.sync, 200_000, 1200, false, nil),
    ]
    let events = samples.map { name, ago, position, attempted, success in
        PlaybackHistoryEventDTO(
            serverConnectionID: key.serverConnectionID,
            mediaKey: key,
            mediaDisplayTitle: "The Book",
            name: name,
            type: name == .sync ? .sync : .playback,
            currentTime: position,
            serverSyncAttempted: attempted,
            serverSyncSuccess: success,
            timestamp: now.addingTimeInterval(-ago)
        )
    }
    let model = PlaybackHistoryModel(
        mediaKey: key,
        source: { _ in AsyncStream { $0.yield(events) } },
        playFromTime: { _, _ in }
    )
    NavigationStack {
        PlaybackHistoryView(model: model)
    }
}

#Preview("Empty") {
    let model = PlaybackHistoryModel(
        mediaKey: MediaKey(serverConnectionID: UUID(), libraryItemId: "li_1"),
        source: { _ in AsyncStream { $0.yield([]) } },
        playFromTime: { _, _ in }
    )
    NavigationStack {
        PlaybackHistoryView(model: model)
    }
}
