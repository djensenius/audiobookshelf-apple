import ABSCore
import ABSUI
import SwiftUI

@main
struct AudiobookshelfApp: App {
    /// Shared by every scene. The app shell's `AppEnvironment` (#44) takes it over.
    @State private var settings = AppSettings()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(settings)
                .modifier(AppThemeModifier(settings: settings))
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
