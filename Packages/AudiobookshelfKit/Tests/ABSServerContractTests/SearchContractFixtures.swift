import ABSAPI
import ABSCore
import Foundation
import Testing

struct SearchLedger: Encodable, Sendable {
    let bookLibrary: String
    let podcastLibrary: String
    let books: [LibraryItem]
    let podcast: LibraryItem
    let authors: [Author]
    let series: [Series]
    let token: String
}

/// Exact-ID ownership is local to this isolated invocation, never used to filter shared seed lists.
actor SearchContractFixture {
    let configuration: SearchContractConfiguration
    let admin: ContractSession
    private var libraries: [String] = []
    private var items: Set<String> = []
    private var authors: Set<String> = []
    private var series: Set<String> = []
    private var users: [String] = []
    private var scanning: Set<String> = []
    private var seedSnapshots: [String: Data] = [:]
    private var captureSequence = 0

    init(configuration: SearchContractConfiguration, admin: ContractSession) {
        self.configuration = configuration
        self.admin = admin
    }

    static func withFixture<T: Sendable>(
        _ body: (SearchContractFixture, SearchLedger, ContractSession) async throws -> T
    ) async throws -> T {
        // This must precede ContractAdmin: no configured-server fallback, including absent URL.
        let configuration = try SearchContractConfiguration()
        let fixture = try await SearchContractFixture(
            configuration: configuration, admin: ContractAdmin.shared.session())
        let value: T
        do {
            let ledger = try await fixture.prepare()
            let user = try await fixture.user()
            value = try await body(fixture, ledger, user)
        } catch {
            // A cancelled body must still get a bounded, uncancelled cleanup attempt.
            let failures = await Task.detached { await fixture.cleanup() }.value
            for failure in failures { Issue.record("Owned search cleanup: \(failure)") }
            throw error
        }
        let failures = await fixture.cleanup()
        if !failures.isEmpty { throw Failure(description: failures.joined(separator: "; ")) }
        return value
    }

    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    func capture(_ data: Data, label: String) throws {
        guard let directory = configuration.captureDirectory else { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        captureSequence += 1
        try data.write(to: directory.appendingPathComponent("\(captureSequence)-\(label).json"))
    }

    func request(
        _ path: String, query: [URLQueryItem] = [], as session: ContractSession? = nil
    ) async throws -> Data {
        try await request(.get, path, query: query, as: session)
    }

    func request(
        _ method: HTTPMethod, _ path: String, body: (any Encodable & Sendable)? = nil,
        query: [URLQueryItem] = [], as session: ContractSession? = nil
    ) async throws -> Data {
        let response = try await (session ?? admin).client.response(
            for: Endpoint<Data>(method, path, query: query, body: body, timeout: 5, followsRedirects: false))
        try #require(response.httpResponse.statusCode == 200)
        return response.value
    }

    private func prepare() async throws -> SearchLedger {
        try capture(configuration.provenance, label: "provenance")
        let status = try await request("/status")
        try capture(status, label: "status")
        try #require(try SearchRaw.object(status)["serverVersion"] as? String == configuration.version)
        try #require(admin.user.type == .root || admin.user.type == .admin)
        try #require(admin.configuration.baseURL.absoluteString == configuration.address)

        let seed = try await ContractSeed.shared.data()
        let seedLibraries = [seed.bookLibraryID, seed.podcastLibraryID]
        for id in seedLibraries { try await waitForScan(id, seconds: 60) }
        let listed = try await request("/api/libraries")
        let rawLibraries = try SearchRaw.rows(SearchRaw.object(listed)["libraries"])
        try #require(Set(try rawLibraries.map { try SearchRaw.string($0, "id") }) == Set(seedLibraries))
        for library in rawLibraries {
            for folder in try SearchRaw.rows(library["folders"]) {
                let path = try SearchRaw.string(folder, "fullPath")
                for owned in [configuration.books, configuration.podcasts] {
                    // Deliberately stronger than a slash-boundary test: old watchers use startsWith.
                    try #require(!owned.hasPrefix(path) && !path.hasPrefix(owned))
                }
            }
        }
        seedSnapshots["/api/libraries"] = listed
        for id in [seed.taleID, seed.singleFileID, seed.podcastID] {
            seedSnapshots["/api/items/\(id)"] = try await request("/api/items/\(id)")
        }
        for (path, data) in seedSnapshots {
            try capture(data, label: "seed-before-\(path.split(separator: "/").last!)")
        }

        let bookLibrary = try await createLibrary(type: "book", folder: configuration.books)
        let podcastLibrary = try await createLibrary(type: "podcast", folder: configuration.podcasts)
        let scannedBooks = try await scan(bookLibrary, expected: 2)
        let scannedPodcasts = try await scan(podcastLibrary, expected: 1)
        let castID = try #require(scannedPodcasts.first).id
        let castBefore = try await readItem(castID)
        let episodes = try #require(castBefore.podcast?.episodes)
        try #require(episodes.count == 2)
        try #require(Set(episodes.map(\.title)) == Set((1...2).map { "\(configuration.token) Episode \($0)" }))
        try #require(Set(episodes.map(\.id)).count == 2)
        for episode in episodes {
            let number = episode.title.hasSuffix(" 1") ? 1 : 2
            try #require(approximately(episode.duration, Double(number * 20)))
            try #require(episode.audioFile?.metadata?.filename == "\(configuration.token) Episode \(number).mp3")
            try #require(episode.audioTrack?.index == 1)
            try #require(episode.publishedAt == nil && episode.pubDate == nil)
        }
        let ordered = scannedBooks.sorted { ($0.book?.metadata.title ?? "") < ($1.book?.metadata.title ?? "") }
        try #require(ordered.compactMap { $0.book?.metadata.title } == ["First", "Second"])
        let token = configuration.token
        for (offset, item) in ordered.enumerated() {
            let unique = offset == 0
            let metadata = BookMetadata(
                title: "\(token) Book \(offset + 1)",
                authors: names("Author", unique: unique).map { Author(id: "new", name: $0) },
                narrators: names("Narrator", unique: unique),
                series: [
                    Series(id: "new", name: "\(token) Shared Series", sequence: "\(offset + 1)")
                ] + (unique ? [Series(id: "new", name: "\(token) Unique Series", sequence: "7")] : []),
                genres: names("Genre", unique: unique))
            let data = try await request(
                .patch, "/api/items/\(item.id)/media",
                body: BookPatch(metadata: metadata, tags: names("Tag", unique: unique)))
            try registerRelations(SearchRaw.object(data)["libraryItem"])
            try capture(data, label: "book-patch")
        }
        let patchedCast = try await request(
            .patch, "/api/items/\(castID)/media",
            body: PodcastPatch(
                metadata: PodcastMetadata(title: "\(token) Podcast", genres: ["\(token) Podcast Genre"]),
                tags: ["\(token) Podcast Tag"]))
        try capture(patchedCast, label: "podcast-patch")

        // Independent detail reads, not patch responses or search, establish the expected ledger.
        var books: [LibraryItem] = []
        for (offset, item) in ordered.enumerated() {
            let read = try await readItem(item.id)
            let book = try #require(read.book)
            let unique = offset == 0
            try #require(approximately(book.duration, unique ? 30 : 40))
            try #require(book.audioFiles?.count == 1 && book.tracks?.count == 1)
            try #require(read.libraryId == bookLibrary)
            try #require(book.metadata.title == "\(token) Book \(offset + 1)")
            try #require(Set(book.metadata.authors?.map(\.name) ?? []) == Set(names("Author", unique: unique)))
            try #require(Set(book.metadata.narrators ?? []) == Set(names("Narrator", unique: unique)))
            try #require(Set(book.metadata.genres ?? []) == Set(names("Genre", unique: unique)))
            try #require(Set(book.tags ?? []) == Set(names("Tag", unique: unique)))
            let associations = try #require(book.metadata.series)
            try #require(associations.count == (unique ? 2 : 1))
            try #require(associations.first { $0.name == "\(token) Shared Series" }?.sequence == "\(offset + 1)")
            if unique { try #require(associations.first { $0.name == "\(token) Unique Series" }?.sequence == "7") }
            books.append(read)
        }
        let podcast = try await readItem(castID)
        try #require(podcast.libraryId == podcastLibrary)
        try #require(podcast.podcast?.metadata.title == "\(token) Podcast")
        try #require(podcast.podcast?.metadata.genres == ["\(token) Podcast Genre"])
        try #require(podcast.podcast?.tags == ["\(token) Podcast Tag"])
        try #require(podcast.podcast?.episodes == episodes)

        var verifiedAuthors: [Author] = []
        for id in authors.sorted() {
            let data = try await request("/api/authors/\(id)", query: [URLQueryItem(name: "include", value: "items")])
            try capture(data, label: "author-detail")
            let raw = try SearchRaw.object(data)
            let author = try SearchRaw.decode(Author.self, raw)
            let expected = books.filter { $0.book?.metadata.authors?.contains { $0.id == id } == true }.map(\.id)
            try #require(!expected.isEmpty)
            try #require(
                Set(try SearchRaw.rows(raw["libraryItems"]).map { try SearchRaw.string($0, "id") }) == Set(expected))
            verifiedAuthors.append(author)
        }
        var verifiedSeries: [Series] = []
        for id in series.sorted() {
            let data = try await request(
                "/api/series/\(id)", query: [URLQueryItem(name: "include", value: "progress")])
            try capture(data, label: "series-detail")
            let raw = try SearchRaw.object(data)
            let value = try SearchRaw.decode(Series.self, raw)
            let expected = books.filter { $0.book?.metadata.series?.contains { $0.id == id } == true }.map(\.id)
            let progress = try SearchRaw.dictionary(raw["progress"])
            let memberIDs = try #require(progress["libraryItemIds"] as? [String])
            try #require(memberIDs.count == expected.count)
            try #require(Set(memberIDs) == Set(expected))
            let detail = try SearchRaw.decode(SeriesDetailResponse.self, raw)
            try #require(detail.progress?.libraryItemIds == memberIDs)
            verifiedSeries.append(value)
        }
        let ledger = SearchLedger(
            bookLibrary: bookLibrary, podcastLibrary: podcastLibrary, books: books, podcast: podcast,
            authors: verifiedAuthors, series: verifiedSeries, token: token)
        try capture(JSONEncoder().encode(ledger), label: "verified-ledger")
        return ledger
    }

    private func names(_ kind: String, unique: Bool) -> [String] {
        ["\(configuration.token) Shared \(kind)"] + (unique ? ["\(configuration.token) Unique \(kind)"] : [])
    }

    private func createLibrary(type: String, folder: String) async throws -> String {
        let data = try await request(
            .post, "/api/libraries",
            body: NewLibrary(
                name: "\(configuration.token) \(type)", folders: [.init(fullPath: folder)], mediaType: type))
        let raw = try SearchRaw.object(data)
        let id = try SearchRaw.string(raw, "id")
        libraries.append(id)  // Before any model decoding or capture can fail.
        try capture(data, label: "library-create")
        let settings = try SearchRaw.dictionary(raw["settings"])
        try #require(settings["disableWatcher"] as? Bool == true)
        try #require(raw["lastScan"] == nil || raw["lastScan"] is NSNull)
        return id
    }

    private func scan(_ id: String, expected: Int) async throws -> [LibraryItem] {
        scanning.insert(id)  // The HTTP response is not a completion signal.
        _ = try await request(.post, "/api/libraries/\(id)/scan")
        try await waitForScan(id, seconds: 60)
        scanning.remove(id)
        let data = try await request("/api/libraries/\(id)/items", query: [URLQueryItem(name: "limit", value: "20")])
        let raw = try SearchRaw.object(data)
        let rows = try SearchRaw.rows(raw["results"])
        for row in rows {
            items.insert(try SearchRaw.string(row, "id"))
            try registerRelations(row)
        }
        try capture(data, label: "scan-items")
        try #require(raw["total"] as? Int == expected)
        try #require(rows.count == expected)
        return try rows.map { try SearchRaw.item($0) }
    }

    private func waitForScan(_ id: String, seconds: Int) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(seconds))
        while clock.now < deadline {
            try Task.checkCancellation()
            let data = try await request("/api/libraries/\(id)")
            let library = try SearchRaw.object(data)
            if let lastScan = library["lastScan"] as? Int, lastScan > 0,
                library["lastScanVersion"] as? String == configuration.version
            {
                try capture(data, label: "scan-complete")
                return
            }
            try await clock.sleep(for: .milliseconds(100))
        }
        throw Failure(
            description: "Scan \(id) did not persist completion within \(seconds)s; scanner may still be active")
    }

    private func registerRelations(_ value: Any?) throws {
        let item = try SearchRaw.dictionary(value)
        guard item["mediaType"] as? String == "book" else { return }
        let metadata = try SearchRaw.dictionary(SearchRaw.dictionary(item["media"])["metadata"])
        for author in try SearchRaw.rows(metadata["authors"] ?? []) {
            authors.insert(try SearchRaw.string(author, "id"))
        }
        for value in try SearchRaw.rows(metadata["series"] ?? []) {
            series.insert(try SearchRaw.string(value, "id"))
        }
    }

    private func readItem(_ id: String) async throws -> LibraryItem {
        let data = try await request("/api/items/\(id)", query: [URLQueryItem(name: "expanded", value: "1")])
        try registerRelations(SearchRaw.object(data))
        try capture(data, label: "item-detail")
        return try SearchRaw.item(SearchRaw.object(data))
    }

    private func user() async throws -> ContractSession {
        let name = "search-" + UUID().uuidString
        let password = UUID().uuidString
        let data = try await request(.post, "/api/users", body: NewUser(username: name, password: password))
        let raw = try SearchRaw.dictionary(SearchRaw.object(data)["user"])
        users.append(try SearchRaw.string(raw, "id"))
        let session = try await ContractServer.require().signIn(username: name, password: password)
        try #require(session.user.type == .user)
        try #require(!session.user.permissions.update && !session.user.permissions.delete)
        return session
    }

    func ownedPaths() -> [String] {
        libraries.map { "/api/libraries/\($0)" } + items.sorted().map { "/api/items/\($0)" }
            + authors.sorted().map { "/api/authors/\($0)" } + series.sorted().map { "/api/series/\($0)" }
            + users.map { "/api/users/\($0)" }
    }

    private func cleanup() async -> [String] {
        var failures: [String] = []
        var results: [String] = []
        // No guessed sleep that claims the scanner stopped. If completion cannot be proved,
        // do not race deletion against it: report failure and rely on the outer owned-server trap.
        for id in scanning.sorted() {
            do {
                try await waitForScan(id, seconds: 5)
                scanning.remove(id)
            } catch { failures.append("Uncontained scan \(id): \(error); outer server teardown required") }
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(60))
        for path in libraries.reversed().map({ "/api/libraries/\($0)" }) + users.reversed().map({ "/api/users/\($0)" })
        {
            guard scanning.isEmpty, ContinuousClock.now < deadline else {
                failures.append("Deferred \(path) to outer server containment")
                continue
            }
            do {
                _ = try await request(.delete, path)
                results.append("DELETE \(path): 200")
            } catch { failures.append("DELETE \(path): \(error)") }
        }
        for path in ownedPaths() {
            guard ContinuousClock.now < deadline else { failures.append("Cleanup deadline at \(path)"); break }
            do {
                _ = try await request(path)
                failures.append("GET \(path) still exists")
            } catch APIError.notFound {
                results.append("GET \(path): 404")
            } catch { failures.append("GET \(path): \(error)") }
        }
        for (path, before) in seedSnapshots {
            do {
                let after = try await request(path)
                try capture(after, label: "seed-after-\(path.split(separator: "/").last!)")
                if try !SearchRaw.equalJSON(before, after) {
                    failures.append("Seed changed: \(path)")
                } else {
                    results.append("Seed unchanged: \(path)")
                }
            } catch { failures.append("Seed verification \(path): \(error)") }
        }
        do {
            try capture(
                JSONSerialization.data(withJSONObject: ["results": results, "failures": failures]), label: "cleanup")
        } catch { failures.append("Cleanup capture: \(error)") }
        return failures
    }

    private struct NewLibrary: Encodable, Sendable {
        struct Folder: Encodable, Sendable { let fullPath: String }
        let name: String
        let folders: [Folder]
        let mediaType: String
        let settings = ["disableWatcher": true]
    }
    private struct BookPatch: Encodable, Sendable {
        let metadata: BookMetadata
        let tags: [String]
    }
    private struct PodcastPatch: Encodable, Sendable {
        let metadata: PodcastMetadata
        let tags: [String]
        let autoDownloadEpisodes = false
    }
    private struct NewUser: Encodable, Sendable {
        let username: String
        let password: String
        let type = "user"
        let isActive = true
    }
}
