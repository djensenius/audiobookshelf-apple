import ABSAppModel
import SwiftUI

extension EnvironmentValues {
    /// What the Downloads tab is built from; `nil` where the app has no download stack (the
    /// store couldn't be opened, the app test host, previews). Set once for every scene by
    /// `AudiobookshelfApp`.
    @Entry var downloads: DownloadsServices?
}
