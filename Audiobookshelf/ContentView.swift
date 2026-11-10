import ABSAppModel
import ABSCore
import ABSUI
import SwiftUI

struct ContentView: View {
    var version = AppVersion()
    @Environment(AppSettings.self) private var settings: AppSettings?

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                Image(systemName: "headphones")
                    .imageScale(.large)
                Text("Audiobookshelf")
                    .font(.title)
                Text("Version \(version.description)")
                    .foregroundStyle(.secondary)
            }
            .padding()
            // Temporary entry point until the app shell (#44) and Account (#92) link to Logs.
            .toolbar {
                ToolbarItem(placement: .secondaryAction) {
                    NavigationLink(value: Route.logs) {
                        Label {
                            Text(verbatim: L10n.string("ButtonLogs"))
                        } icon: {
                            Image(systemName: "doc.text.magnifyingglass")
                        }
                    }
                }
            }
            .navigationDestination(for: Route.self) { route in
                if route == .logs {
                    LogsView()
                }
            }
            #if os(iOS)
                // Temporary entry point until the app shell (#44) pushes Settings from Account.
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        if let settings {
                            NavigationLink {
                                SettingsView(settings: settings)
                            } label: {
                                Label {
                                    Text(verbatim: L10n.string("HeaderSettings"))
                                } icon: {
                                    Image(systemName: "gearshape")
                                }
                            }
                        }
                    }
                }
            #endif
        }
    }
}

#Preview {
    ContentView()
}
