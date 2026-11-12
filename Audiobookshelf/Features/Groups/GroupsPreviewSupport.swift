#if DEBUG
    import ABSAPI
    import ABSAppModel
    import ABSCore
    import ABSUI
    import Foundation

    /// Serves ``SampleLibrary``'s collections and playlists, or fails every request when `fails`.
    struct GroupsPreviewService: GroupsService {
        struct Failure: Error {}

        var fails = false

        static let description = """
            Novels that shaped the English language: courtship and manners in Regency England, and the \
            scientist whose creature turns on him.
            """

        func collectionsPage(libraryID: String, page: Int, limit: Int) async throws -> PagedResults<LibraryCollection> {
            try check()
            let collections = SampleLibrary.collections
            return PagedResults(results: collections, total: collections.count, limit: limit, page: page)
        }

        func playlistsPage(libraryID: String, page: Int, limit: Int) async throws -> PagedResults<Playlist> {
            try check()
            let playlists = SampleLibrary.playlists
            return PagedResults(results: playlists, total: playlists.count, limit: limit, page: page)
        }

        func collectionDetail(id: String) async throws -> LibraryCollection {
            try check()
            let collection = SampleLibrary.collections[0]
            return LibraryCollection(
                id: id, libraryId: collection.libraryId, name: collection.name, description: Self.description,
                books: collection.books)
        }

        func playlistDetail(id: String) async throws -> Playlist {
            try check()
            return SampleLibrary.playlists[0]
        }

        private func check() throws {
            if fails { throw Failure() }
        }
    }

    /// Fixture models for the collection and playlist previews, served from ``SampleLibrary``.
    @MainActor
    enum GroupsPreviewData {
        /// The first book of the collection is finished, so Play offers the second.
        static let progress: ProgressCache = {
            let cache = ProgressCache()
            cache.apply(
                MediaProgress(
                    id: "mp_1", libraryItemId: SampleLibrary.prideAndPrejudice.id, progress: 1, isFinished: true))
            cache.apply(MediaProgress(id: "mp_2", libraryItemId: SampleLibrary.frankenstein.id, progress: 0.4))
            cache.apply(
                MediaProgress(id: "mp_3", libraryItemId: SampleLibrary.podcast.id, episodeId: "ep_1", progress: 0.6))
            return cache
        }()

        static let progressReader = BrowsePresentation.progressReader(progress)

        static func list(_ kind: GroupSummary.Kind, fails: Bool = false) -> GroupListModel {
            let service = GroupsPreviewService(fails: fails)
            return switch kind {
            case .collection: .collections(service: service, libraryID: SampleLibrary.libraryID)
            case .playlist: .playlists(service: service, libraryID: SampleLibrary.libraryID)
            }
        }

        static func collection(fails: Bool = false) -> CollectionDetailModel {
            CollectionDetailModel(id: "col_classics", service: GroupsPreviewService(fails: fails), cache: progress)
        }

        static func playlist(fails: Bool = false) -> PlaylistDetailModel {
            PlaylistDetailModel(id: "pl_commute", service: GroupsPreviewService(fails: fails), cache: progress)
        }
    }
#endif
