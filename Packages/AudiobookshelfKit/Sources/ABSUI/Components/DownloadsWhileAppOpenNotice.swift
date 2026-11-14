import SwiftUI

/// Tells the user that a connection's downloads continue only while the app is open (#467): it has
/// custom headers, so they don't run in the background session (`DownloadAccess.onlyWhileOpen`).
/// Shown as a footer where its downloads are listed or started.
public struct DownloadsWhileAppOpenNotice: View {
    /// The text, for places that can't show a view, such as an alert's message.
    public static var message: String { L10n.string("MessageDownloadsWhileAppOpen") }

    public init() {}

    public var body: some View {
        Label {
            Text(verbatim: Self.message)
        } icon: {
            Image(systemName: "info.circle")
                .accessibilityHidden(true)
        }
        .font(.footnote)
        .foregroundStyle(ABSColor.mutedForeground)
    }
}

#Preview {
    List {
        Section {
            Text(verbatim: "Book")
        } footer: {
            DownloadsWhileAppOpenNotice()
        }
    }
}
