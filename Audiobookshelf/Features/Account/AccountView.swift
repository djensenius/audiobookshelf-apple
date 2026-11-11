import ABSAppModel
import ABSUI
import SwiftUI

/// The Account tab (legacy `pages/account.vue`), with the entry points to Logs and Settings. A
/// stub until the Account feature replaces this file.
struct AccountView: View {
    var body: some View {
        FeatureStub(titleKey: AppTab.account.titleKey, systemImage: AppTab.account.systemImage)
            .toolbar { DiagnosticsToolbar() }
    }
}

/// The saved server connections (`Route.servers`). A stub until the Account feature replaces
/// this file.
struct ServersView: View {
    var body: some View {
        FeatureStub(titleKey: "ButtonSwitchServerUser", systemImage: "server.rack")
    }
}

#Preview("Account") {
    NavigationStack {
        AccountView()
            .navigationDestination(for: Route.self) { RouteDestination(route: $0) }
    }
}

#Preview("Servers") {
    NavigationStack { ServersView() }
}
