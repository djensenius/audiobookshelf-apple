import ABSAppModel
import ABSCore
import ABSData
import ABSDownloads
import ABSUI
import SwiftUI

@main
struct AudiobookshelfApp: App {
    /// Shared by every scene and CarPlay.
    private let environment = AppEnvironment.shared
    private var settings: AppSettings { environment.settings }
    /// The Downloads tab's services, built once.
    private let downloads = AppEnvironment.shared.makeDownloadsServices()
    @Environment(\.scenePhase) private var scenePhase
    /// Readers open an ebook's downloaded copy when there is one.
    private let downloadedEbookFile = AppEnvironment.shared.dataStack.map {
        EbookFileLoader.downloadedFileLookup(
            items: LocalItemStore(modelContainer: $0.container), locations: DownloadLocations())
    }

    init() {
        // Here rather than in `AppEnvironment`, so the environments tests build don't replace it.
        environment.playback.registerIntents(settings: settings, lifecycle: environment.lifecycle)
    }

    var body: some Scene {
        // Every window; Open in New Window opens one at a screen (``WindowRoute``).
        WindowGroup(for: WindowRoute.self) { $windowRoute in
            RootView(
                lifecycle: environment.lifecycle, player: environment.player, accounts: environment.accounts,
                library: environment.library,
                imagePipeline: environment.images.pipeline, playback: environment.playback.participant
            )
            .environment(\.downloads, downloads)
            .environment(settings)
            .environment(\.windowRoute, $windowRoute)
            .environment(\.downloadedEbookFile, downloadedEbookFile)
            .environment(\.downloadAccess, environment.downloads?.access)
            .environment(\.currentPlayback, environment.playback.current)
            .modifier(AppThemeModifier(settings: settings))
        }
        .commands {
            SearchCommands()
            RefreshCommands()
            PlaybackCommands(player: environment.player, participant: environment.playback.participant)
            GoCommands()
            // View > Show/Hide Inspector toggles the scene's queue inspector (ADR 0004).
            InspectorCommands()
        }
        // The system relaunches the app for finished background downloads; this waits until
        // the download engine has processed every event before the system suspends it again,
        // once the download folders are prepared.
        .backgroundTask(.urlSession(DownloadEngine.sessionIdentifier)) {
            if let downloads = await environment.downloads {
                await downloads.lifecycle.handleBackgroundEvents()
            } else {
                await DownloadEngine.handleBackgroundEvents()
            }
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
            // Each ebook opened with Read; reopening one brings its window forward.
            WindowGroup(id: ReaderWindow.id, for: ReaderPresentation.self) { $presentation in
                ReaderWindow(presentation: presentation, store: environment.library?.store)
                    // macOS can restore a reader window alone, without the window that starts it.
                    .task { await environment.lifecycle.start() }
                    .environment(settings)
                    .environment(\.downloadedEbookFile, downloadedEbookFile)
                    .modifier(AppThemeModifier(settings: settings))
            }

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
