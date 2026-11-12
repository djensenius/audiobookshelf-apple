import SwiftUI
import WidgetKit

/// The widget extension: widgets, controls and Live Activities share it (#89, #90). It declares
/// the shared playback intents (`AudiobookshelfShared/Intents`), which run in the app process.
@main
struct AudiobookshelfWidgets: WidgetBundle {
    var body: some Widget {
        PlaceholderWidget()
    }
}

/// Shows the app's name until the continue-listening widget (#89) replaces it.
struct PlaceholderWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "org.davidjensenius.Audiobookshelf.Placeholder", provider: PlaceholderProvider()) {
            _ in
            PlaceholderWidgetView()
        }
        .configurationDisplayName("Audiobookshelf")
        .description("Open Audiobookshelf.")
        .supportedFamilies([.systemSmall])
    }
}

struct PlaceholderEntry: TimelineEntry {
    let date: Date
}

struct PlaceholderProvider: TimelineProvider {
    func placeholder(in context: Context) -> PlaceholderEntry {
        PlaceholderEntry(date: .now)
    }

    func getSnapshot(in context: Context, completion: @escaping (PlaceholderEntry) -> Void) {
        completion(PlaceholderEntry(date: .now))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<PlaceholderEntry>) -> Void) {
        completion(Timeline(entries: [PlaceholderEntry(date: .now)], policy: .never))
    }
}

struct PlaceholderWidgetView: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "headphones")
                .font(.largeTitle)
                .accessibilityHidden(true)
            Text(verbatim: "Audiobookshelf")
                .font(.headline)
        }
        .containerBackground(.fill.tertiary, for: .widget)
    }
}
