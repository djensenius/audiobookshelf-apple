import ABSAPI
import ABSAppModel
import ABSCore
import SwiftUI

/// Sample items and progress for the item detail previews.
enum ItemDetailPreviewData {
    static let book = makeBook()

    /// ``book`` with ten long tags, to check the metadata wraps at narrow widths.
    static let longTags = makeBook(tags: [
        "Interplanetary Romance", "Planetary Adventure Fiction", "Sword and Planet", "Early Twentieth Century",
        "Pulp Magazine Serials", "Public Domain Classics", "Science Fantasy", "Lost Civilizations",
        "Swashbuckling Heroes", "A Very Long Tag Without Any Natural Place To Break It Up",
    ])

    /// A Princess of Mars, with rich metadata; the parameters vary it for previews and tests.
    static func makeBook(
        authors: [Author] = [Author(id: "aut_burroughs", name: "Edgar Rice Burroughs")],
        narrators: [String] = ["Grover Gardner", "Stefan Rudnicki"],
        tags: [String] = ["Public Domain", "Pulp"],
        duration: Double = 32_760,
        size: Int = 412_000_000
    ) -> ABSCore.LibraryItem {
        let metadata = BookMetadata(
            title: "A Princess of Mars", subtitle: "Barsoom, Book 1", authors: authors, narrators: narrators,
            series: [Series(id: "ser_barsoom", name: "Barsoom", sequence: "1")],
            genres: ["Science Fiction", "Adventure", "Classics"], publishedYear: "1917",
            publisher: "A. C. McClurg",
            description: """
                <p>John Carter, a Confederate veteran, is <b>mysteriously transported</b> to Mars, where the \
                low gravity makes him a formidable warrior.</p><p>Captured by the four-armed Green Martians, he \
                wins their respect and meets Dejah Thoris, the princess of Helium.</p><ul><li>First published \
                as a serial in 1912</li><li>Public domain</li></ul>
                """,
            language: "English", explicit: true, abridged: true)
        let book = Book(
            id: "book_li_barsoom_1", libraryItemId: "li_barsoom_1", metadata: metadata,
            coverPath: "/metadata/items/li_barsoom_1/cover.jpg", tags: tags,
            tracks: [AudioTrack(index: 1, duration: duration)], duration: duration, numTracks: 1)
        return ABSCore.LibraryItem(
            id: "li_barsoom_1", libraryId: SampleLibrary.libraryID, updatedAt: 14, mediaType: .book,
            media: .book(book), size: size)
    }

    /// An ebook with no audio tracks.
    static let ebookOnly = ABSCore.LibraryItem(
        id: "li_ebook", libraryId: SampleLibrary.libraryID, updatedAt: 18, mediaType: .book,
        media: .book(
            Book(
                id: "book_li_ebook", metadata: BookMetadata(title: "Emma", authors: [SampleLibrary.authors[0]]),
                tracks: [], numTracks: 0, ebookFormat: .epub)))

    static let inProgress = MediaProgress(
        id: "mp_1", libraryItemId: "li_barsoom_1", duration: 32_760, progress: 0.42, currentTime: 13_759,
        lastUpdate: 1)

    static let finished = MediaProgress(
        id: "mp_1", libraryItemId: "li_barsoom_1", duration: 32_760, progress: 1, currentTime: 32_760,
        isFinished: true, lastUpdate: 1, finishedAt: 1_762_000_000_000)
}

/// An ``ItemDetailService`` for previews.
struct PreviewItemDetailService: ItemDetailService {
    enum Behavior {
        case succeed, hang, fail, notFound
    }

    let item: ABSCore.LibraryItem
    let behavior: Behavior

    func item(id: String) async throws -> ABSCore.LibraryItem {
        switch behavior {
        case .succeed: return item
        case .hang:
            try await Task.sleep(for: .seconds(3_600))
            return item
        case .fail: throw APIError.timedOut
        case .notFound: throw APIError.notFound
        }
    }
}

/// ``ItemDetailScreen`` over a preview model, with a `playItem` that does nothing unless
/// `canPlay` is off.
struct ItemDetailPreview: View {
    @State private var model: ItemDetailModel
    private let canPlay: Bool

    init(
        item: ABSCore.LibraryItem, progress: MediaProgress? = nil,
        behavior: PreviewItemDetailService.Behavior = .succeed,
        canPlay: Bool = true
    ) {
        let cache = ProgressCache()
        if let progress { cache.apply(progress) }
        _model = State(
            initialValue: ItemDetailModel(
                itemID: item.id, service: PreviewItemDetailService(item: item, behavior: behavior), cache: cache))
        self.canPlay = canPlay
    }

    var body: some View {
        NavigationStack {
            ItemDetailScreen(model: model)
                .task { await model.loadIfNeeded() }
        }
        .environment(\.playItem, canPlay ? PlayItemAction { _, _, _ in } : nil)
    }
}
