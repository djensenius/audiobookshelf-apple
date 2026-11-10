import SwiftUI

@main
struct AudiobookshelfApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }

        #if os(macOS)
            Settings {
                Text("Settings")
                    .padding()
            }
        #endif
    }
}
