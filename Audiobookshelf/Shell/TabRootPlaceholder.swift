import ABSAppModel
import ABSUI
import SwiftUI

/// The root of a tab, until the screen for it is built: the tab's name and icon. The Account
/// tab also has the entry points to Logs and Settings.
struct TabRootPlaceholder: View {
    let tab: AppTab

    var body: some View {
        ContentUnavailableView {
            Label {
                Text(verbatim: L10n.string(tab.titleKey))
            } icon: {
                Image(systemName: tab.systemImage)
            }
        }
        .navigationTitle(Text(verbatim: L10n.string(tab.titleKey)))
        .toolbar {
            if tab == .account {
                DiagnosticsToolbar()
            }
        }
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
        TabRootPlaceholder(tab: .account)
            .navigationDestination(for: Route.self) { RouteDestination(route: $0) }
    }
}

#Preview("Series") {
    NavigationStack {
        TabRootPlaceholder(tab: .series)
    }
}
