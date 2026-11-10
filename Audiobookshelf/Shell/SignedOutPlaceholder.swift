import ABSAppModel
import ABSUI
import SwiftUI

/// What the signed-out gate shows until the connect flow (S6) replaces it. Keeps Logs and
/// Settings reachable while nobody is signed in.
struct SignedOutPlaceholder: View {
    var body: some View {
        NavigationStack {
            ContentUnavailableView {
                Label {
                    Text(verbatim: L10n.string("MessageAudiobookshelfServerNotConnected"))
                } icon: {
                    Image(systemName: "headphones")
                }
            }
            .toolbar { DiagnosticsToolbar() }
            .navigationDestination(for: Route.self) { RouteDestination(route: $0) }
        }
    }
}

#Preview {
    SignedOutPlaceholder()
}
