import ABSCore
import Foundation
import Testing

@testable import ABSAPI

@Suite("Server contract: libraries and items", .requiresServer, .tags(.serverContract))
struct LibraryContractTests {
    private func fixtures() async throws -> (client: APIClient, seed: SeedData) {
        (try await ContractAdmin.shared.session().client, try await ContractSeed.shared.data())
    }

    @Test("the seeded libraries decode with their folders and settings")
    func libraries() async throws {
        let (client, seed) = try await fixtures()
        let libraries = try await client.send(LibraryEndpoints.libraries()).libraries
        #expect(libraries.count == 2)
        let books = try #require(libraries.first { $0.id == seed.bookLibraryID })
        #expect(books.name == "Books")
        #expect(books.mediaType == .book)
        #expect(books.folders?.map(\.fullPath).map { $0.hasSuffix("/audiobooks") } == [true])
        #expect(books.settings?.markAsFinishedTimeRemaining == 10)
        let podcasts = try #require(libraries.first { $0.id == seed.podcastLibraryID })
        #expect(podcasts.mediaType == .podcast)
        #expect(podcasts.folders?.map(\.fullPath).map { $0.hasSuffix("/podcasts") } == [true])
    }

    @Test("library filter data lists the seeded author")
    func filterData() async throws {
        let (client, seed) = try await fixtures()
        let response = try await client.send(LibraryEndpoints.library(id: seed.bookLibraryID))
        #expect(response.library.id == seed.bookLibraryID)
        #expect(response.filterData.authors.map(\.name) == ["Ada Fixture"])
        #expect(response.issues == 0)
    }

    @Test("minified book items carry counts and durations, not files")
    func minifiedBooks() async throws {
        let (client, seed) = try await fixtures()
        let page = try await client.send(LibraryEndpoints.items(libraryID: seed.bookLibraryID))
        #expect(page.total == 2)
        #expect(page.rawCount == page.results.count)

        let tale = try #require(page.results.first { $0.id == seed.taleID }?.book)
        #expect(tale.metadata.title == "The Synthetic Tale")
        #expect(tale.metadata.authorName == "Ada Fixture")
        #expect(tale.numAudioFiles == 2)
        #expect(tale.numTracks == 2)
        #expect(approximately(tale.duration, 50))
        #expect(tale.audioFiles == nil)

        let single = try #require(page.results.first { $0.id == seed.singleFileID }?.book)
        #expect(single.numAudioFiles == 1)
        #expect(single.numChapters == 3)
        #expect(approximately(single.duration, 40))
    }

    @Test("an expanded multi-file book has audio files, 1-based tracks and generated chapters")
    func expandedBook() async throws {
        let (client, seed) = try await fixtures()
        let item = try await client.send(ItemEndpoints.item(id: seed.taleID))
        let book = try #require(item.book)
        #expect(item.mediaType == .book)
        #expect(item.libraryId == seed.bookLibraryID)
        #expect(book.metadata.authors?.map(\.name) == ["Ada Fixture"])
        #expect(book.metadata.series?.isEmpty != false)
        #expect(approximately(book.duration, 50))

        let files = try #require(book.audioFiles)
        #expect(files.map(\.mimeType) == ["audio/mpeg", "audio/mpeg"])
        #expect(files.allSatisfy { $0.chapters?.isEmpty != false })
        #expect(files.allSatisfy { ($0.metadata?.size ?? 0) > 0 })

        // The player and `TrackURLResolver` depend on these: indexes start at 1 and each
        // `contentUrl` ends in the file's inode.
        let tracks = try #require(book.tracks)
        #expect(tracks.map(\.index) == [1, 2])
        #expect(tracks[0].startOffset == 0)
        #expect(approximately(tracks[1].startOffset, 30))
        #expect(tracks.map(\.contentUrl) == files.map { "/api/items/\(item.id)/file/\($0.ino)" })

        // Without embedded chapters the server makes one chapter per file, titled from its tags.
        let chapters = try #require(book.chapters)
        #expect(chapters.map(\.title) == ["Part One", "Part Two"])
        #expect(approximately(chapters[0].start, 0))
        #expect(approximately(chapters[1].start, 30))
        #expect(approximately(chapters[1].end, 50))
    }

    @Test("an M4B's embedded chapters decode on the book and on its audio file")
    func embeddedChapters() async throws {
        let (client, seed) = try await fixtures()
        let book = try #require(try await client.send(ItemEndpoints.item(id: seed.singleFileID)).book)
        let chapters = try #require(book.chapters)
        #expect(chapters.map(\.title) == ["Opening", "Middle", "Ending"])
        #expect(zip(chapters.map(\.start), [0, 10, 25]).allSatisfy { approximately($0, $1) })
        #expect(approximately(chapters.last?.end, 40))

        let file = try #require(book.audioFiles?.first)
        #expect(file.mimeType == "audio/mp4")
        #expect(file.chapters?.count == 3)
        #expect(book.tracks?.count == 1)
    }

    @Test("a podcast and its episode decode, minified and expanded")
    func podcast() async throws {
        let (client, seed) = try await fixtures()
        let page = try await client.send(LibraryEndpoints.items(libraryID: seed.podcastLibraryID))
        #expect(page.total == 1)
        let listed = try #require(page.results.first?.podcast)
        #expect(listed.metadata.title == "Synthetic Cast")
        #expect(listed.numEpisodes == 1)

        let podcast = try #require(try await client.send(ItemEndpoints.item(id: seed.podcastID)).podcast)
        let episode = try #require(podcast.episodes?.first)
        #expect(episode.id == seed.episodeID)
        #expect(episode.libraryItemId == seed.podcastID)
        #expect(episode.title == "Episode One")
        #expect(approximately(episode.duration, 20))
        #expect(episode.audioFile?.mimeType == "audio/mpeg")
        // A scanned episode has track index 1, not null: `TrackURLResolver` only needs its token
        // fallback for servers before 2.26.3 when the index is null.
        #expect(episode.audioTrack?.index == 1)
    }

    @Test("home shelves, search, authors, series and recent episodes decode")
    func browse() async throws {
        let (client, seed) = try await fixtures()

        // `personalized` skips shelves that fail to decode, so compare with the raw count.
        let shelves = try await client.send(LibraryEndpoints.personalized(libraryID: seed.bookLibraryID)).elements
        let listing = LibraryEndpoints.personalized(libraryID: seed.bookLibraryID)
        let raw = try await client.send(Endpoint<Data>(listing.method, listing.path, query: listing.query))
        #expect(shelves.count == (try JSONSerialization.jsonObject(with: raw) as? [Any])?.count)
        let recent = try #require(shelves.first { $0.id == "recently-added" })
        guard case .libraryItems(let recentItems) = recent.entities else {
            Issue.record("recently-added should hold library items")
            return
        }
        #expect(Set(recentItems.map(\.id)) == [seed.taleID, seed.singleFileID])
        #expect(shelves.contains { $0.id == "newest-authors" })

        let found = try await client.send(LibraryEndpoints.search(libraryID: seed.bookLibraryID, query: "Synthetic"))
        #expect(found.books.map(\.id) == [seed.taleID])
        let author = try await client.send(LibraryEndpoints.search(libraryID: seed.bookLibraryID, query: "Ada"))
        #expect(author.authors.map(\.name) == ["Ada Fixture"])

        let authors = try await client.send(LibraryEndpoints.authors(libraryID: seed.bookLibraryID)).authors
        #expect(authors.map(\.name) == ["Ada Fixture"])
        let series = try await client.send(LibraryEndpoints.series(libraryID: seed.bookLibraryID))
        #expect(series.results.isEmpty)
        #expect(series.rawCount == 0)

        let episodes = try await client.send(LibraryEndpoints.recentEpisodes(libraryID: seed.podcastLibraryID))
        #expect(episodes.episodes.map(\.episode.id) == [seed.episodeID])
        let cast = try await client.send(LibraryEndpoints.search(libraryID: seed.podcastLibraryID, query: "Synthetic"))
        #expect(cast.podcasts.map(\.id) == [seed.podcastID])
    }
}
