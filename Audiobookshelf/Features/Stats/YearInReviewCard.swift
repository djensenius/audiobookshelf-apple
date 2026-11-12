import ABSAppModel
import ABSCore
import ABSUI
import SwiftUI

/// Cover images loaded before the card is rendered: `ImageRenderer` draws a single frame and
/// doesn't wait for async images, so the card only draws what is already here.
struct YearInReviewCovers {
    /// The decoded covers by library item ID.
    private(set) var images: [String: CGImage] = [:]
    /// The pipeline's wrappers, kept so the bitmaps stay charged against its memory cap while
    /// the card shows them.
    private var held: [CoverImage] = []

    init(images: [String: CGImage] = [:]) {
        self.images = images
    }

    /// The side the card's cover tiles need, in pixels at the largest share scale (3x).
    static let pixelSide: Double = 3 * YearInReviewCard.tileSide

    /// Loads the covers of `ids` from `pipeline`, at most ``YearInReviewCard/maxCovers`` of them.
    /// Covers that fail are left out; the card shows tiles only for those that loaded.
    static func load(ids: [String], serverID: UUID?, pipeline: ImagePipeline?) async -> YearInReviewCovers {
        guard let serverID, let pipeline else { return YearInReviewCovers() }
        let box = PixelBox(width: pixelSide, height: pixelSide)
        let bucket = ImageWidthBucket(pixelWidth: pixelSide)
        let loaded = await withTaskGroup(of: (String, CoverImage?).self) { group in
            for id in ids.prefix(YearInReviewCard.maxCovers) {
                // The stats give only IDs and nothing in the app caches items by ID, so the key has
                // no `updatedAt`: a cover changed on the server shows its cached version until
                // the cache ages it out. Fetching every item for its `updatedAt` would cost up to
                // 30 extra requests per card.
                let key = ImageKey(serverID: serverID, kind: .itemCover, entityID: id, updatedAt: nil, bucket: bucket)
                group.addTask { (id, try? await pipeline.image(for: key, pixelBox: box)) }
            }
            var images: [(String, CoverImage)] = []
            for await (id, image) in group {
                if let image { images.append((id, image)) }
            }
            return images
        }
        var covers = YearInReviewCovers()
        for (id, image) in loaded {
            covers.images[id] = image.cgImage
            covers.held.append(image)
        }
        return covers
    }
}

/// The shareable year in review card, a port of the legacy canvas in
/// `components/stats/YearInReview.vue` and `YearInReviewServer.vue`: totals, the top authors and
/// genres, and the covers of the books finished (or added, for the server) over a tilted
/// wall of covers. It has a fixed size and fixed text sizes, because it is shared as an image.
struct YearInReviewCard: View {
    static let size = CGSize(width: 400, height: 600)
    nonisolated static let tileSide: Double = 108
    /// The server lists up to 25 books with covers, plus 5 finished ones for the user.
    nonisolated static let maxCovers = 30
    /// Tiles per side of the backdrop's wall: 7 × 108 pt covers the 400 × 600 pt card tilted
    /// by 25°.
    private static let wallSide = 7

    let content: YearInReviewContent
    let year: Int
    let covers: YearInReviewCovers
    var locale = Locale.autoupdatingCurrent

    fileprivate static let tan = Color(.sRGB, red: 1, green: 219 / 255, blue: 112 / 255)
    private static let background = Color(.sRGB, red: 35 / 255, green: 35 / 255, blue: 35 / 255)
    private static let gold = Color(.sRGB, red: 205 / 255, green: 157 / 255, blue: 73 / 255)

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            header
            tiles
            HStack(alignment: .top, spacing: 20) {
                topList(titleKey: "LabelYearInReviewTopAuthors", names: topAuthors)
                topList(titleKey: "LabelYearInReviewTopGenres", names: topGenres)
            }
            Spacer(minLength: 0)
            coverRow
        }
        .padding(24)
        .frame(width: Self.size.width, height: Self.size.height, alignment: .topLeading)
        .background { backdrop }
        .clipped()
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
    }

    // MARK: Parts

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: "audiobookshelf")
                .font(.system(size: 22))
                .foregroundStyle(Self.tan)
            Text(verbatim: L10n.string("HeaderYearInReviewYear", String(year)))
                .font(.system(size: 14, weight: .bold))
                .textCase(.uppercase)
                .kerning(1)
        }
    }

    private var tiles: some View {
        let stats = Self.tiles(for: content, locale: locale)
        return Grid(horizontalSpacing: 12, verticalSpacing: 12) {
            GridRow {
                StatTile(stat: stats[0])
                StatTile(stat: stats[1])
            }
            GridRow {
                StatTile(stat: stats[2])
                StatTile(stat: stats[3])
            }
        }
    }

    private func topList(titleKey: String, names: [String]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(verbatim: L10n.string(titleKey))
                .font(.system(size: 13))
                .kerning(1)
                .textCase(.uppercase)
                .foregroundStyle(Self.tan)
            if names.isEmpty {
                Text(verbatim: "–").font(.system(size: 20, weight: .heavy))
            }
            ForEach(Array(names.prefix(3).enumerated()), id: \.offset) { _, name in
                Text(verbatim: name)
                    .font(.system(size: 20, weight: .heavy))
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var coverRow: some View {
        let ids = rowIDs.filter { covers.images[$0] != nil }
        if !ids.isEmpty {
            VStack(spacing: 10) {
                Text(verbatim: L10n.string(rowTitleKey))
                    .font(.system(size: 16))
                    .foregroundStyle(Self.tan)
                HStack(spacing: 8) {
                    ForEach(ids, id: \.self) { id in
                        if let image = covers.images[id] {
                            CoverTile(image: image, side: 64)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    private var backdrop: some View {
        let ids = content.coverItemIDs.filter { covers.images[$0] != nil }
        return Self.background
            .overlay {
                if !ids.isEmpty {
                    // A wall cycling through the covers, tilted like the legacy canvas, and large
                    // enough to cover the card's corners once tilted. An overlay, so its overflow
                    // doesn't grow the card.
                    Grid(horizontalSpacing: 0, verticalSpacing: 0) {
                        ForEach(0..<Self.wallSide, id: \.self) { row in
                            GridRow {
                                ForEach(0..<Self.wallSide, id: \.self) { column in
                                    if let image = covers.images[ids[(row * Self.wallSide + column) % ids.count]] {
                                        CoverTile(image: image, side: Self.tileSide)
                                    }
                                }
                            }
                        }
                    }
                    .rotationEffect(.degrees(-25))
                    .opacity(0.25)
                }
            }
            .overlay {
                LinearGradient(
                    colors: [.black.opacity(0.67), Self.gold.opacity(0.67)],
                    startPoint: .topLeading, endPoint: .bottomTrailing)
            }
            .accessibilityHidden(true)
    }

    // MARK: Values

    private var topAuthors: [String] {
        switch content {
        case .user(let stats): stats.topAuthors.map(\.name)
        case .server(let stats): stats.topAuthors.map(\.name)
        }
    }

    private var topGenres: [String] {
        switch content {
        case .user(let stats): stats.topGenres.map(\.genre)
        case .server(let stats): stats.topGenres.map(\.genre)
        }
    }

    private var rowIDs: [String] {
        switch content {
        case .user: content.finishedItemIDs
        case .server(let stats): Array(stats.booksAddedWithCovers.prefix(5))
        }
    }

    private var rowTitleKey: String {
        switch content {
        case .user: "LabelYearInReviewFinishedBooks"
        case .server: "LabelYearInReviewAdditions"
        }
    }

    /// One of the four totals: a value, its label key and an SF Symbol, plus the whole total as
    /// one localized phrase for VoiceOver ("1 book finished"), since the card stacks the value
    /// above the label.
    struct Stat: Hashable {
        var value: String
        var labelKey: String
        var systemImage: String
        var spoken: String
    }

    /// The four totals, in the legacy order.
    static func tiles(for content: YearInReviewContent, locale: Locale) -> [Stat] {
        func number(_ value: Int) -> String { value.formatted(.number.locale(locale)) }
        func count(_ key: String, _ value: Int) -> String { L10n.plural(key, count: value, locale: locale) }
        func time(_ seconds: Double) -> String {
            L10n.string("LabelYearInReviewTimeSpentListening", listeningTime(seconds, locale: locale), locale: locale)
        }
        switch content {
        case .user(let stats):
            return [
                Stat(
                    value: number(stats.numBooksFinished), labelKey: "LabelYearInReviewBooksFinished",
                    systemImage: "checkmark.seal.fill",
                    spoken: count("LabelYearInReviewBooksFinishedCount", stats.numBooksFinished)),
                Stat(
                    value: listeningTime(stats.totalListeningTime, locale: locale),
                    labelKey: "LabelYearInReviewSpentListening", systemImage: "clock.fill",
                    spoken: time(stats.totalListeningTime)),
                Stat(
                    value: number(stats.totalListeningSessions), labelKey: "LabelYearInReviewSessions",
                    systemImage: "headphones",
                    spoken: count("LabelYearInReviewSessionCount", stats.totalListeningSessions)),
                Stat(
                    value: number(stats.numBooksListened), labelKey: "LabelYearInReviewBooksListened",
                    systemImage: "books.vertical.fill",
                    spoken: count("LabelYearInReviewBooksListenedCount", stats.numBooksListened)),
            ]
        case .server(let stats):
            return [
                Stat(
                    value: number(stats.numBooksAdded), labelKey: "LabelYearInReviewBooksAdded",
                    systemImage: "plus.circle.fill",
                    spoken: count("LabelYearInReviewBooksAddedCount", stats.numBooksAdded)),
                Stat(
                    value: listeningTime(stats.totalListeningTime, locale: locale),
                    labelKey: "LabelYearInReviewSpentListening", systemImage: "clock.fill",
                    spoken: time(stats.totalListeningTime)),
                Stat(
                    value: number(stats.numListeningSessions), labelKey: "LabelYearInReviewSessions",
                    systemImage: "headphones",
                    spoken: count("LabelYearInReviewSessionCount", stats.numListeningSessions)),
                Stat(
                    value: number(stats.numAuthorsAdded), labelKey: "LabelYearInReviewAuthorsAdded",
                    systemImage: "person.2.fill",
                    spoken: count("LabelYearInReviewAuthorsAddedCount", stats.numAuthorsAdded)),
            ]
        }
    }

    /// Like legacy `$elapsedPrettyExtended(time, true, false)`: days, hours and minutes, with
    /// "0m" for none.
    static func listeningTime(_ seconds: Double, locale: Locale) -> String {
        let text = DurationStyle.elapsed(showSeconds: false).string(seconds, locale: locale)
        guard text.isEmpty else { return text }
        return Duration.zero.formatted(
            Duration.UnitsFormatStyle(allowedUnits: [.minutes], width: .narrow).locale(locale))
    }

    /// What VoiceOver reads for the rendered card: the title, the totals and the top lists.
    static func summary(for content: YearInReviewContent, year: Int, locale: Locale) -> String {
        var parts = [L10n.string("HeaderYearInReviewYear", String(year))]
        parts += tiles(for: content, locale: locale).map(\.spoken)
        let (authors, genres): ([String], [String]) =
            switch content {
            case .user(let stats): (stats.topAuthors.map(\.name), stats.topGenres.map(\.genre))
            case .server(let stats): (stats.topAuthors.map(\.name), stats.topGenres.map(\.genre))
            }
        if !authors.isEmpty {
            parts.append(
                "\(L10n.string("LabelYearInReviewTopAuthors")): \(authors.formatted(.list(type: .and).locale(locale)))")
        }
        if !genres.isEmpty {
            parts.append(
                "\(L10n.string("LabelYearInReviewTopGenres")): \(genres.formatted(.list(type: .and).locale(locale)))")
        }
        return parts.joined(separator: ", ")
    }
}

/// A total in a translucent rounded box, like the legacy canvas's boxes.
private struct StatTile: View {
    let stat: YearInReviewCard.Stat

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: stat.systemImage)
                .font(.system(size: 24))
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: stat.value)
                    .font(.system(size: 26, weight: .bold))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                Text(verbatim: L10n.string(stat.labelKey))
                    .font(.system(size: 13))
                    .foregroundStyle(YearInReviewCard.tan)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 80)
        .background {
            let shape = RoundedRectangle(cornerRadius: 10)
            shape
                .fill(
                    LinearGradient(
                        colors: [.black.opacity(0.33), .white.opacity(0.07)], startPoint: .topLeading,
                        endPoint: .bottomTrailing)
                )
                .stroke(Color.gray.opacity(0.53), lineWidth: 1)
        }
    }
}

/// A square, centre-cropped cover drawn from an already decoded image.
private struct CoverTile: View {
    let image: CGImage
    let side: Double

    var body: some View {
        Image(decorative: image, scale: 1)
            .resizable()
            .scaledToFill()
            .frame(width: side, height: side)
            .clipped()
    }
}

#Preview("User") {
    YearInReviewCard(
        content: .user(
            UserYearStats(
                totalListeningSessions: 42, totalListeningTime: 360_000,
                topAuthors: [YearStatsNameTime(name: "Mary Shelley", time: 1)],
                topGenres: [YearStatsGenreTime(genre: "Horror", time: 1)], numBooksFinished: 7, numBooksListened: 9)),
        year: 2025, covers: YearInReviewCovers())
}
