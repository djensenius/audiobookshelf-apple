import SwiftUI

/// What the connection banner shows while the server can't be used (#76). The caller maps its
/// connection state to it, so this view doesn't depend on the app model.
public enum ConnectionBannerStatus: Hashable, Sendable {
    /// The device has no network (legacy `MessageNoNetworkConnection`).
    case offline
    /// Checking whether the server answers (legacy `MessageAttemptingServerConnection`).
    case checking
    /// The server didn't answer; it's checked again at `retryAt`.
    case serverUnreachable(retryAt: Date)

    /// The SF Symbol, as in ``ConnectionStatus``.
    public var systemImage: String {
        switch self {
        case .offline: "wifi.slash"
        case .checking: "arrow.clockwise.icloud"
        case .serverUnreachable: "icloud.slash"
        }
    }

    /// The String Catalog key of the banner's message.
    var messageKey: String {
        switch self {
        case .offline: "MessageNoNetworkConnection"
        case .checking: "MessageAttemptingServerConnection"
        case .serverUnreachable: "MessageAudiobookshelfServerNotConnected"
        }
    }

    /// The localized message.
    public var message: String { L10n.string(messageKey) }

    /// Whether Retry is offered: only for an unreachable server. Without a network there's nothing
    /// to retry, and a check is already running while checking.
    public var offersRetry: Bool {
        if case .serverUnreachable = self { true } else { false }
    }

    /// When the next automatic check is, at `now`: "Retrying in 5s", or `nil` when none is due.
    public func retryDescription(at now: Date, locale: Locale = .current) -> String? {
        guard case .serverUnreachable(let retryAt) = self else { return nil }
        let seconds = max(Int(retryAt.timeIntervalSince(now).rounded(.up)), 0)
        let wait = Duration.seconds(seconds).formatted(
            .units(allowed: [.minutes, .seconds], width: .narrow).locale(locale))
        return L10n.string("MessageConnectionRetryingIn", wait, locale: locale)
    }

    var tint: AnyShapeStyle {
        switch self {
        case .offline: AnyShapeStyle(ABSColor.error)
        case .checking: AnyShapeStyle(ABSColor.mutedForeground)
        case .serverUnreachable: AnyShapeStyle(ABSColor.warning)
        }
    }
}

/// A strip across the top of the signed-in shell saying the network or the server is unavailable,
/// with Retry while the server is unreachable. Legacy showed the same messages from its
/// `ConnectionIndicator.vue` icon; a banner keeps them visible while offline. VoiceOver reads it as
/// one element, with Retry as its action.
public struct ConnectionBanner: View {
    private let status: ConnectionBannerStatus
    private let retry: () -> Void
    @Environment(\.locale) private var locale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(status: ConnectionBannerStatus, retry: @escaping () -> Void) {
        self.status = status
        self.retry = retry
    }

    public var body: some View {
        HStack(spacing: ABSSpacing.medium) {
            Image(systemName: status.systemImage)
                .foregroundStyle(status.tint)
                .symbolEffect(.pulse, isActive: status == .checking && !reduceMotion)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: status.message)
                    .font(.subheadline.weight(.semibold))
                if case .serverUnreachable = status {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        if let text = status.retryDescription(at: context.date, locale: locale) {
                            Text(verbatim: text)
                                .font(.caption)
                                .foregroundStyle(ABSColor.mutedForeground)
                                .monospacedDigit()
                        }
                    }
                }
            }
            Spacer(minLength: 0)
            if status.offersRetry {
                Button(action: retry) {
                    Text(verbatim: L10n.string("ButtonRetry"))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(.horizontal, ABSSpacing.large)
        .padding(.vertical, ABSSpacing.small)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.updatesFrequently)
    }
}

#Preview("Connection banner") {
    VStack(spacing: 0) {
        ConnectionBanner(status: .offline) {}
        ConnectionBanner(status: .checking) {}
        ConnectionBanner(status: .serverUnreachable(retryAt: .now.addingTimeInterval(20))) {}
    }
}
