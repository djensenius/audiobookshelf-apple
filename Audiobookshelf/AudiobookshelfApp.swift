import ABSCore
import ABSDownloads
import ABSUI
import SwiftUI

@main
struct AudiobookshelfApp: App {
    /// Shared by every scene and CarPlay.
    private let environment = AppEnvironment.shared
    private var settings: AppSettings { environment.settings }
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView(
                lifecycle: environment.lifecycle, player: environment.player, accounts: environment.accounts,
                library: environment.library,
                imagePipeline: environment.images.pipeline
            )
            .environment(settings)
            .modifier(AppThemeModifier(settings: settings))
        }
        .commands {
            SearchCommands()
            RefreshCommands()
            GoCommands()
        }
        // The system relaunches the app for finished background downloads; this waits until
        // the download engine has processed every event before the system suspends it again.
        .backgroundTask(.urlSession(DownloadEngine.sessionIdentifier)) {
            await DownloadEngine.handleBackgroundEvents()
        }
        // In the background, transfers the system cancels wait for the next activation.
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { Task { await DownloadEngine.deactivate() } }
        }
        // Keeps less of the cover cache in memory while in the background.
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { environment.images.didEnterBackground() }
        }

        #if os(macOS)
            Settings {
                SettingsView(settings: settings)
                    .modifier(AppThemeModifier(settings: settings))
            }
            .windowResizability(.contentMinSize)
        #endif
    }
}

/// Applies the user's theme, updating when it changes. Each scene applies it, because new
/// macOS windows don't inherit it.
private struct AppThemeModifier: ViewModifier {
    let settings: AppSettings

    func body(content: Content) -> some View {
        content.absTheme(settings.theme)
    }
}
