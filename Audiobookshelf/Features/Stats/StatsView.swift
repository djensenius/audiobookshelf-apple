import ABSAppModel
import ABSCore
import ABSUI
import Charts
import SwiftUI

extension EnvironmentValues {
    /// The signed-in account's stats endpoints. The app shell (#44) sets it to the active
    /// connection's `APIClient`; `nil` while signed out.
    @Entry var statsService: (any StatsService)?
}

/// The listening stats page (`Route.stats`), a port of `pages/stats.vue`: summary tiles, the
/// last 7 days as a bar chart and the recent sessions. Sessions open their item through the
/// router's typed path. The year in review opens in a sheet, as legacy's banner expands in place.
struct StatsView: View {
    @Environment(\.statsService) private var service
    @State private var model: StatsModel?
    @State private var showsYearInReview = false

    var body: some View {
        content
            .navigationTitle(Text(verbatim: L10n.string("HeaderYourStats")))
            .sheet(isPresented: $showsYearInReview) {
                YearInReviewSheet()
            }
            .task {
                guard let service else { return }
                let model = model ?? StatsModel(service: service)
                self.model = model
                // Also retries a first load cancelled when the view disappeared.
                await model.loadIfNeeded()
            }
    }

    @ViewBuilder private var content: some View {
        if let model, model.hasLoaded {
            StatsContent(model: model) { showsYearInReview = true }
        } else if let model, model.error != nil, !model.isLoading {
            ErrorStateView(title: L10n.string("MessageStatsLoadFailed")) {
                Task { await model.load() }
            }
        } else if service == nil {
            ErrorStateView(title: L10n.string("MessageStatsLoadFailed"))
        } else {
            LoadingView()
        }
    }
}

private struct StatsContent: View {
    let model: StatsModel
    let showYearInReview: () -> Void

    var body: some View {
        List {
            if model.refreshFailed {
                Section {
                    RefreshFailedRow { Task { await model.load() } }
                }
            }
            Section {
                StatsTiles(model: model)
            }
            if model.isEmpty {
                Section {
                    Text(verbatim: L10n.string("MessageNoListeningSessions"))
                        .foregroundStyle(ABSColor.mutedForeground)
                }
            } else {
                Section {
                    DailyListeningChart(days: model.lastSevenDays)
                } header: {
                    Text(verbatim: L10n.string("HeaderStatsMinutesListeningChart"))
                }
                Section {
                    if model.recentSessions.isEmpty {
                        Text(verbatim: L10n.string("MessageNoListeningSessions"))
                            .foregroundStyle(ABSColor.mutedForeground)
                    }
                    ForEach(model.recentSessions) { session in
                        if let route = session.route {
                            NavigationLink(value: route) {
                                RecentSessionRow(session: session)
                            }
                        } else {
                            RecentSessionRow(session: session)
                        }
                    }
                } header: {
                    Text(verbatim: L10n.string("HeaderStatsRecentSessions"))
                }
            }
            Section {
                Button(action: showYearInReview) {
                    Label {
                        Text(verbatim: L10n.string("LabelYearReviewShow"))
                    } icon: {
                        Image(systemName: "calendar")
                    }
                }
            }
        }
        .refreshable { await model.load() }
    }
}

/// The year in review in its own navigation stack, with a Done button.
private struct YearInReviewSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            YearInReviewView()
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button {
                            dismiss()
                        } label: {
                            Text(verbatim: L10n.string("ButtonDone"))
                        }
                    }
                }
        }
        #if os(macOS)
            .frame(minWidth: 480, minHeight: 640)
        #endif
    }
}

/// Shown above the retained stats when a reload fails.
private struct RefreshFailedRow: View {
    let retry: () -> Void

    var body: some View {
        HStack(spacing: ABSSpacing.medium) {
            Label {
                Text(verbatim: L10n.string("MessageStatsRefreshFailed"))
            } icon: {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(ABSColor.mutedForeground)
                    .accessibilityHidden(true)
            }
            Spacer(minLength: ABSSpacing.small)
            Button(action: retry) {
                Text(verbatim: L10n.string("ButtonRetry"))
            }
            .buttonStyle(.borderless)
        }
    }
}

/// Items finished, days listened and minutes listening, side by side when they fit.
private struct StatsTiles: View {
    let model: StatsModel
    @Environment(\.locale) private var locale

    var body: some View {
        let minutes = TimeFormatting.wholeMinutes(seconds: model.totalTime)
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: ABSSpacing.large) { tiles(minutes: minutes) }
            VStack(spacing: ABSSpacing.medium) { tiles(minutes: minutes) }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, ABSSpacing.small)
    }

    @ViewBuilder private func tiles(minutes: Int) -> some View {
        StatTile(value: model.itemsFinished.formatted(.number.locale(locale)), titleKey: "LabelStatsItemsFinished")
        StatTile(value: model.daysListened.formatted(.number.locale(locale)), titleKey: "LabelStatsDaysListened")
        StatTile(
            value: minutes.formatted(.number.locale(locale)), titleKey: "LabelStatsMinutesListening",
            spokenValue: ListeningTimeText.spoken(model.totalTime, locale: locale))
    }
}

private struct StatTile: View {
    let value: String
    let titleKey: String
    /// What VoiceOver reads instead of ``value``.
    var spokenValue: String?

    var body: some View {
        VStack(spacing: ABSSpacing.xxSmall) {
            Text(verbatim: value)
                .font(.largeTitle.bold())
                .monospacedDigit()
            Text(verbatim: L10n.string(titleKey))
                .font(.footnote)
                .foregroundStyle(ABSColor.mutedForeground)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: L10n.string(titleKey)))
        .accessibilityValue(Text(verbatim: spokenValue ?? value))
    }
}

/// The last 7 days as bars, labelled with the server's day keys as is.
private struct DailyListeningChart: View {
    let days: [StatsDay]
    @Environment(\.locale) private var locale

    var body: some View {
        let descriptor = DailyListeningChartDescriptor(
            days: days.map { .init(label: spokenLabel($0), minutes: $0.minutes) }, locale: locale)
        Chart(days) { day in
            BarMark(
                x: .value(Text(verbatim: L10n.string("LabelStatsDays")), shortLabel(day)),
                y: .value(Text(verbatim: L10n.string("LabelStatsMinutesListening")), day.minutes)
            )
            .foregroundStyle(ABSColor.accent)
            .accessibilityLabel(Text(verbatim: spokenLabel(day)))
            .accessibilityValue(
                Text(verbatim: DailyListeningChartDescriptor.minutesText(day.minutes, locale: locale)))
        }
        .frame(minHeight: 200)
        .padding(.vertical, ABSSpacing.small)
        .accessibilityChartDescriptor(descriptor)
    }

    private func shortLabel(_ day: StatsDay) -> String {
        day.formatted(Date.FormatStyle(locale: locale).weekday(.abbreviated))
    }

    private func spokenLabel(_ day: StatsDay) -> String {
        day.formatted(Date.FormatStyle(locale: locale).weekday(.wide).month(.wide).day())
    }
}

private struct RecentSessionRow: View {
    let session: StatsSession
    @Environment(\.locale) private var locale

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: ABSSpacing.medium) {
            VStack(alignment: .leading, spacing: ABSSpacing.xxSmall) {
                Text(verbatim: session.title ?? L10n.string("LabelUnknown"))
                    .lineLimit(2)
                if let updatedAt = session.updatedAt {
                    Text(verbatim: updatedAt.formatted(.relative(presentation: .named).locale(locale)))
                        .font(.footnote)
                        .foregroundStyle(ABSColor.mutedForeground)
                }
            }
            Spacer(minLength: ABSSpacing.small)
            Text(verbatim: ListeningTimeText.session(session.timeListening, locale: locale))
                .font(.footnote.bold())
                .monospacedDigit()
                .accessibilityLabel(
                    Text(verbatim: ListeningTimeText.spokenSession(session.timeListening, locale: locale)))
        }
        .accessibilityElement(children: .combine)
    }
}
