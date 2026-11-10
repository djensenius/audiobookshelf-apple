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
/// router's typed path.
struct StatsView: View {
    @Environment(\.statsService) private var service
    @State private var model: StatsModel?

    /// The Year in review entry point stays hidden until #98 adds the screen.
    private static let showsYearInReview = false

    var body: some View {
        content
            .navigationTitle(Text(verbatim: L10n.string("HeaderYourStats")))
            .task {
                guard model == nil, let service else { return }
                let model = StatsModel(service: service)
                self.model = model
                await model.load()
            }
    }

    @ViewBuilder private var content: some View {
        if let model, model.hasLoaded {
            StatsContent(model: model, showsYearInReview: Self.showsYearInReview)
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
    let showsYearInReview: Bool

    var body: some View {
        List {
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
            if showsYearInReview {
                Section {
                    Text(verbatim: L10n.string("LabelYearReviewShow"))
                }
            }
        }
        .refreshable { await model.load() }
    }
}

/// Items finished, days listened and minutes listening, side by side when they fit.
private struct StatsTiles: View {
    let model: StatsModel
    @Environment(\.locale) private var locale

    var body: some View {
        let minutes = model.totalTime.isFinite ? Int((max(model.totalTime, 0) / 60).rounded()) : 0
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
        StatTile(value: minutes.formatted(.number.locale(locale)), titleKey: "LabelStatsMinutesListening")
            .accessibilityValue(
                Text(verbatim: DurationStyle.elapsed(showSeconds: false).accessibilityString(model.totalTime)))
    }
}

private struct StatTile: View {
    let value: String
    let titleKey: String

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
        .accessibilityValue(Text(verbatim: value))
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
            DurationText(seconds: session.timeListening, style: .elapsed())
                .font(.footnote.bold())
        }
        .accessibilityElement(children: .combine)
    }
}
