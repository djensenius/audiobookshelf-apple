import ABSAppModel
import ABSCore
import SwiftUI

/// The screen for a ``Route``, for each tab stack's single `.navigationDestination(for:)`
/// (ADR 0004). The app shell (#44) registers it; routes whose features aren't built yet show
/// nothing.
struct RouteDestination: View {
    let route: Route
    @Environment(AppSettings.self) private var settings: AppSettings?

    var body: some View {
        switch route {
        case .stats:
            StatsView()
        case .logs:
            LogsView()
        case .settings:
            if let settings {
                SettingsView(settings: settings)
            }
        default:
            EmptyView()
        }
    }
}
