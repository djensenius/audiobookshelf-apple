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

/// Opens Logs and, on iOS, Settings (a Mac has the Settings window). Temporary: the Account
/// screen (S6) pushes both. Needs the stack's `Route` destination.
struct DiagnosticsToolbar: ToolbarContent {
    var body: some ToolbarContent {
        ToolbarItem(placement: .secondaryAction) {
            NavigationLink(value: Route.logs) {
                Label {
                    Text(verbatim: L10n.string("ButtonLogs"))
                } icon: {
                    Image(systemName: "doc.text.magnifyingglass")
                }
            }
        }
        #if os(iOS)
            ToolbarItem(placement: .primaryAction) {
                NavigationLink(value: Route.settings) {
                    Label {
                        Text(verbatim: L10n.string("HeaderSettings"))
                    } icon: {
                        Image(systemName: "gearshape")
                    }
                }
            }
        #endif
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
