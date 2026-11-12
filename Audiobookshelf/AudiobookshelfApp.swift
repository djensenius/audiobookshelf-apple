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
        // Every window; Open in New Window opens one at a screen (``WindowRoute``).
        WindowGroup(for: WindowRoute.self) { $windowRoute in
            RootView(
                lifecycle: environment.lifecycle, player: environment.player, accounts: environment.accounts,
                library: environment.library,
                imagePipeline: environment.images.pipeline, playback: environment.playback.participant
            )
            .environment(settings)
            .environment(\.windowRoute, $windowRoute)
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

            // The full player; only ``PlayerSlot`` opens it, with a session.
            Window(Text(verbatim: L10n.string("HeaderNowPlaying")), id: NowPlayingWindow.id) {
                NowPlayingWindow(player: environment.player)
                    .environment(settings)
                    .environment(\.imagePipeline, environment.images.pipeline)
                    .environment(\.libraryStore, environment.library?.store)
                    .modifier(PlaybackEnvironment(participant: environment.playback.participant))
                    .modifier(AppThemeModifier(settings: settings))
            }
            .restorationBehavior(.disabled)
            .defaultLaunchBehavior(.suppressed)
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
