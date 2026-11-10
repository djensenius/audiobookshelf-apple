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
