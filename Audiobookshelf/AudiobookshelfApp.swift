import ABSAppModel
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
        // Every phase from launch on, in order: activating resumes transfers and sweeps orphaned
        // downloads; in the background, transfers the system cancels wait for the next
        // activation. Without a store there's no stack; the registry's engine, if any, is still
        // deactivated as before.
        .onChange(of: scenePhase, initial: true) { _, phase in
            if let downloads = environment.downloads {
                downloads.lifecycle.handle(scenePhase: SessionScenePhase(phase))
            } else if phase == .background {
                Task { await DownloadEngine.deactivate() }
            }
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
