import ABSCore
import ABSUI
import ImageIO
import SwiftUI
import WidgetKit

/// Shows the item last played, its progress and cover, and opens it on tap (#89). The app writes
/// the ``WidgetSnapshot`` and reloads this widget; the cover comes read-only from the App Group's
/// cover cache (ADR 0005), and a placeholder stands in when it isn't there.
struct ContinueListeningWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetSnapshot.continueListeningKind, provider: ContinueListeningProvider()) {
            entry in
            ContinueListeningView(entry: entry)
        }
        .configurationDisplayName(L10n.string("LabelContinueListening"))
        .description(L10n.string("MessageWidgetContinueListeningDescription"))
        .supportedFamilies(Self.families)
    }

    private static var families: [WidgetFamily] {
        #if os(iOS)
            [.systemSmall, .systemMedium, .accessoryCircular, .accessoryRectangular, .accessoryInline]
        #else
            [.systemSmall, .systemMedium]
        #endif
    }
}

struct ContinueListeningEntry: TimelineEntry {
    let date: Date
    /// `nil` when nothing has been played, or after a sign-out.
    let snapshot: WidgetSnapshot?
    let cover: CGImage?
}

struct ContinueListeningProvider: TimelineProvider {
    func placeholder(in context: Context) -> ContinueListeningEntry {
        ContinueListeningEntry(date: .now, snapshot: nil, cover: nil)
    }

    func getSnapshot(in context: Context, completion: @escaping (ContinueListeningEntry) -> Void) {
        completion(Self.entry())
    }

    /// One entry, kept until the app reloads the widget after a new snapshot.
    func getTimeline(in context: Context, completion: @escaping (Timeline<ContinueListeningEntry>) -> Void) {
        completion(Timeline(entries: [Self.entry()], policy: .never))
    }

    private static func entry() -> ContinueListeningEntry {
        let snapshot = WidgetSnapshot.defaultFileURL().flatMap(WidgetSnapshot.read(from:))
        return ContinueListeningEntry(date: .now, snapshot: snapshot, cover: snapshot?.cover.flatMap(cover(for:)))
    }

    /// The snapshot's cover from the cache, downsampled; `nil` on a miss. Tries the 300 px file the
    /// snapshot names, then a larger cached rendition of the same version.
    // TODO(#89): once `ImagePipeline.ensureCoverFile` writes the 300 px file before each reload
    // (ADR 0005), the fallback to larger buckets can go.
    private static func cover(for locator: CoverLocator) -> CGImage? {
        let directory = CoverFileStore.defaultDirectory()
        for bucket in ImageWidthBucket.allCases {
            guard let url = CoverFileStore.cachedFile(for: locator.with(bucket: bucket), in: directory),
                let source = CGImageSourceCreateWithURL(
                    url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
            else { continue }
            let options =
                [
                    kCGImageSourceThumbnailMaxPixelSize: 600,
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                ] as CFDictionary
            if let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options) { return image }
        }
        return nil
    }
}

struct ContinueListeningView: View {
    let entry: ContinueListeningEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        content
            .widgetURL(entry.snapshot?.deepLinkURL)
            .containerBackground(.fill.tertiary, for: .widget)
    }

    @ViewBuilder private var content: some View {
        if let snapshot = entry.snapshot {
            switch family {
            #if os(iOS)
                case .accessoryCircular:
                    Gauge(value: snapshot.progress) {
                        Image(systemName: "headphones")
                    }
                    .gaugeStyle(.accessoryCircularCapacity)
                    .accessibilityLabel(Text(verbatim: snapshot.title))
                case .accessoryInline:
                    Label {
                        Text(verbatim: snapshot.title)
                    } icon: {
                        Image(systemName: "headphones")
                    }
                case .accessoryRectangular:
                    VStack(alignment: .leading) {
                        Text(verbatim: snapshot.title).font(.headline).lineLimit(1)
                        Text(verbatim: snapshot.author).lineLimit(1)
                        ProgressView(value: snapshot.progress)
                    }
            #endif
            case .systemMedium:
                HStack(spacing: 12) {
                    CoverView(image: entry.cover)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(verbatim: snapshot.title).font(.headline).lineLimit(2)
                        Text(verbatim: snapshot.author).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                        if let chapter = snapshot.chapterTitle {
                            Text(verbatim: chapter).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                        ProgressView(value: snapshot.progress)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            default:
                VStack(alignment: .leading, spacing: 6) {
                    CoverView(image: entry.cover)
                    Text(verbatim: snapshot.title).font(.caption.weight(.semibold)).lineLimit(1)
                    ProgressView(value: snapshot.progress)
                }
            }
        } else {
            empty
        }
    }

    @ViewBuilder private var empty: some View {
        switch family {
        #if os(iOS)
            case .accessoryCircular, .accessoryInline:
                Image(systemName: "headphones")
                    .accessibilityLabel(Text(verbatim: L10n.string("MessageWidgetNothingPlaying")))
        #endif
        default:
            VStack(spacing: 6) {
                Image(systemName: "headphones")
                    .font(.title)
                    .accessibilityHidden(true)
                Text(verbatim: L10n.string("MessageWidgetNothingPlaying"))
                    .font(.caption)
                    .multilineTextAlignment(.center)
            }
        }
    }
}

/// The cover, or a placeholder when it isn't cached.
private struct CoverView: View {
    let image: CGImage?

    var body: some View {
        Group {
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .scaledToFill()
            } else {
                Rectangle()
                    .fill(.quaternary)
                    .overlay {
                        Image(systemName: "book.closed")
                            .font(.title2)
                            .foregroundStyle(.secondary)
                    }
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .accessibilityHidden(true)
    }
}
