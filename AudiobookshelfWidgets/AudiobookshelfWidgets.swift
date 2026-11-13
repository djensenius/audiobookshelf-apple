import SwiftUI
import WidgetKit

/// The widget extension: widgets, controls and Live Activities share it (#89, #90). It declares
/// the shared playback intents (`AudiobookshelfShared/Intents`), which run in the app process.
@main
struct AudiobookshelfWidgets: WidgetBundle {
    var body: some Widget {
        ContinueListeningWidget()
    }
}
