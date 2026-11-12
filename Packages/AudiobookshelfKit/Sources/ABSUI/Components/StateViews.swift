import SwiftUI

/// A centred spinner with a message, "Loading..." by default.
public struct LoadingView: View {
    private let message: String

    public init(message: String? = nil) {
        self.message = message ?? L10n.string("MessageLoading")
    }

    public var body: some View {
        ProgressView {
            Text(verbatim: message)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }
}

/// A full-screen error with an optional Retry button at least 44×44 points.
public struct ErrorStateView: View {
    private let title: String
    private let message: String?
    private let systemImage: String
    private let retry: (() -> Void)?

    /// - Parameters:
    ///   - title: A short localized summary, from `L10n`.
    ///   - message: Optional localized detail.
    ///   - retry: Shows a Retry button that calls this.
    public init(
        title: String,
        message: String? = nil,
        systemImage: String = "exclamationmark.triangle",
        retry: (() -> Void)? = nil
    ) {
        self.title = title
        self.message = message
        self.systemImage = systemImage
        self.retry = retry
    }

    public var body: some View {
        ContentUnavailableView {
            Label {
                Text(verbatim: title)
            } icon: {
                Image(systemName: systemImage)
                    .accessibilityHidden(true)
            }
        } description: {
            if let message {
                Text(verbatim: message)
            }
        } actions: {
            if let retry {
                Button(action: retry) {
                    Text(verbatim: L10n.string("ButtonRetry"))
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(.rect)
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }
}
