import ABSDownloads
import SwiftUI

@main
struct AudiobookshelfApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        // The system relaunches the app for finished background downloads; this waits until
        // the download engine has processed every event before the system suspends it again.
        .backgroundTask(.urlSession(DownloadEngine.sessionIdentifier)) {
            await DownloadEngine.handleBackgroundEvents()
        }

        #if os(macOS)
            Settings {
                Text("Settings")
                    .padding()
            }
        #endif
    }
}
