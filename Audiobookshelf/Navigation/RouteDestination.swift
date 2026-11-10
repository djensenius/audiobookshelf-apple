import ABSAppModel
import SwiftUI

/// The screen for a ``Route``, for each tab stack's single `.navigationDestination(for:)`
/// (ADR 0004). The app shell (#44) registers it; routes whose features aren't built yet show
/// nothing.
struct RouteDestination: View {
    let route: Route

    var body: some View {
        switch route {
        case .stats:
            StatsView()
        default:
            EmptyView()
        }
    }
}
