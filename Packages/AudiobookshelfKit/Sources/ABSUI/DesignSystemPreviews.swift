import ABSCore
import SwiftUI

#Preview("Components") {
    ScrollView {
        VStack(alignment: .leading, spacing: ABSSpacing.large) {
            AdaptiveStack(spacing: ABSSpacing.small) {
                Text(verbatim: "Project Hail Mary")
                ExplicitBadge()
                AbridgedBadge()
            }
            .font(.headline)

            AdaptiveStack(spacing: ABSSpacing.medium) {
                ProgressRing(progress: 0)
                ProgressRing(progress: 0.42)
                ProgressRing(progress: 1, tint: ABSColor.success)
            }

            HStack(spacing: ABSSpacing.medium) {
                ForEach(PreviewData.statuses, id: \.self) { ConnectionIndicator(status: $0) }
            }
            .font(.title3)

            RoundedRectangle(cornerRadius: ABSRadius.small)
                .fill(ABSColor.secondarySurface)
                .frame(width: 120, height: 120)
                .overlay { ProgressBarOverlay(progress: 0.6) }

            VStack(alignment: .leading) {
                DurationText(seconds: 3725)
                DurationText(seconds: 95_400, style: .elapsed())
                DurationText(seconds: 95_400, style: .elapsed(showSeconds: false, useDays: false))
            }

            ExpandableText(html: PreviewData.description, collapsedLineLimit: 3)
        }
        .padding()
    }
    .absBackground()
}

#Preview("Black theme") {
    VStack(spacing: ABSSpacing.large) {
        Text(verbatim: "True black")
            .foregroundStyle(ABSColor.foreground)
        ProgressRing(progress: 0.7)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .absBackground()
    .absTheme(.black)
}

#Preview("Loading") {
    LoadingView()
}

#Preview("Error") {
    ErrorStateView(title: L10n.string("MessageNoNetworkConnection"), retry: {})
}

#Preview("ExpandableText under ancestor lineLimit") {
    // Read more must still appear: the measurement ignores the ancestor's line limit.
    ExpandableText(html: PreviewData.description, collapsedLineLimit: 4)
        .lineLimit(1)
        .padding()
}

#Preview("AX5") {
    VStack(alignment: .leading, spacing: ABSSpacing.large) {
        AdaptiveStack(spacing: ABSSpacing.small) {
            Text(verbatim: "Project Hail Mary")
            ExplicitBadge()
        }
        DurationText(seconds: 95_400, style: .elapsed())
        ExpandableText(html: PreviewData.description, collapsedLineLimit: 3)
    }
    .padding()
    .dynamicTypeSize(.accessibility5)
}

private enum PreviewData {
    static let statuses: [ConnectionStatus] = [
        .connecting, .offline, .serverUnreachable,
        .connected(cellular: false, metered: false), .connected(cellular: true, metered: true),
    ]

    static let description = """
        <p>Ryland Grace is the <b>sole survivor</b> on a desperate, <i>last-chance</i> mission.</p>
        <ul><li>Science</li><li>Friendship</li></ul>
        <p>Read more at <a href="https://example.com">example.com</a> &amp; elsewhere.</p>
        """
}
