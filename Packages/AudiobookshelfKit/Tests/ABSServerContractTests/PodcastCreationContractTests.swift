import ABSAPI
import ABSCore
import Foundation
import Testing

// Both pinned releases (tags v2.26.0 and v2.37.2 of advplyr/audiobookshelf) answer these from
// `server/controllers/PodcastController.js`: `create` (2.26.0 L39–L173, 2.37.2 L40–L189) and
// `getPodcastFeed` (2.26.0 L184–L200, 2.37.2 L200–L216). Both check `isAdminOrUp` first, and the
// feed fetch in `server/utils/podcastUtils.js` goes through `ssrf-req-filter`, which refuses
// loopback and private addresses unless the server disables it.

extension Trait where Self == ConditionTrait {
    /// Creating a podcast adds an item to the seeded podcast library, whose item count other suites
    /// pin, so `scripts/test-server.sh` runs this suite in its own pass with
    /// `ABS_PODCAST_WRITE_CONTRACT=1`, after the ordinary suites.
    static var podcastWritePass: Self {
        .enabled(
            if: ProcessInfo.processInfo.environment["ABS_PODCAST_WRITE_CONTRACT"] == "1",
            "Runs in the podcast write pass of scripts/test-server.sh (docs/testing/server-contracts.md)")
    }
}

/// Expects `operation` to fail with the server's `status` and, when given, its plain-text message.
private func expectStatus<T>(
    _ status: Int, _ message: String? = nil, sourceLocation: SourceLocation = #_sourceLocation,
    _ operation: () async throws -> T
) async {
    let error = await #expect(throws: APIError.self, sourceLocation: sourceLocation) { try await operation() }
    switch error {
    case .forbidden(let text) where status == 403 && (message == nil || text == message),
        .http(status, let text) where message == nil || text == message:
        return
    case .notFound where status == 404:
        return
    default:
        Issue.record(
            "Expected \(status) \(message ?? ""), got \(String(describing: error))", sourceLocation: sourceLocation)
    }
}

@Suite(
    "Server contract: podcast creation and feed lookup", .requiresServer, .podcastWritePass,
    .tags(.serverContract), .serialized)
struct PodcastCreationContractTests {
    /// The seeded podcast library's folder, loaded with the seed before anything is created, so
    /// `ContractSeed` (which takes the library's first item) can only see the seeded podcast.
    private func seededFolder() async throws -> (SeedData, LibraryFolder, ContractSession) {
        let seed = try await ContractSeed.shared.data()
        let admin = try await ContractAdmin.shared.session()
        let libraries = try await admin.client.send(LibraryEndpoints.libraries()).libraries
        let library = try #require(libraries.first { $0.id == seed.podcastLibraryID })
        let folder = try #require(library.folders?.first, "The seeded podcast library has a folder")
        return (seed, folder, admin)
    }

    /// A request like the app's: the folder's path joined with a title that needs no sanitizing.
    private func request(_ seed: SeedData, _ folder: LibraryFolder, title: String) -> NewPodcastRequest {
        NewPodcastRequest(
            libraryID: seed.podcastLibraryID, folderID: folder.id, path: folder.fullPath + "/" + title,
            media: .init(
                metadata: .init(
                    title: title, author: "Ada Fixture", description: "Created by the contract tests",
                    genres: ["Contract"], feedURL: "https://example.com/contract.xml", language: "en", type: "episodic"),
                autoDownloadEpisodes: false))
    }

    @Test("create returns the expanded item; the same path again is a 400")
    func createThenRefuseTheSamePath() async throws {
        let (seed, folder, admin) = try await seededFolder()
        let title = "Contract Cast " + UUID().uuidString.prefix(8).lowercased()
        let body = request(seed, folder, title: title)
        try await withCreatedPodcasts(admin) { created in
            let (item, raw) = try await create(body, as: admin, registering: created)
            #expect(item.libraryId == seed.podcastLibraryID && item.folderId == folder.id)
            #expect(item.path == body.path)
            // 2.26.0 strips `folder.fullPath`, which its LibraryFolder model doesn't have, so
            // `relPath` is the whole path without its leading slash; 2.37.2 strips `folder.path`.
            switch ContractServer.current?.version {
            case "2.26.0": #expect(item.relPath == String(body.path.drop { $0 == "/" }))
            case "2.37.2": #expect(item.relPath == title)
            default: #expect(item.relPath == title || item.relPath == String(body.path.drop { $0 == "/" }))
            }
            #expect(item.mediaType == .podcast && item.isFile == false && !item.isMissing && !item.isInvalid)
            let podcast = try #require(item.podcast)
            #expect(podcast.metadata.title == title && podcast.metadata.author == "Ada Fixture")
            #expect(podcast.metadata.feedUrl == "https://example.com/contract.xml")
            #expect(podcast.metadata.genres == ["Contract"] && podcast.metadata.type == "episodic")
            #expect(podcast.autoDownloadEpisodes == false && podcast.episodes?.isEmpty == true)
            #expect(podcast.coverPath == nil)
            // `Podcast.episodes` decodes lossily, so check the wire: present and empty.
            let media = try #require(raw["media"] as? [String: Any])
            let episodes = try #require(media["episodes"] as? [Any], "The created podcast has an episodes array")
            #expect(episodes.isEmpty)

            let fetched = try await admin.client.send(ItemEndpoints.item(id: item.id))
            #expect(fetched.path == body.path && fetched.podcast?.metadata.title == title)

            // `libraryItemModel.count({ where: { path } })`: refused before anything is written.
            await expectStatus(400, "Podcast already exists") {
                try await create(body, as: admin, registering: created)
            }
        }
        #expect(try await admin.client.send(LibraryEndpoints.items(libraryID: seed.podcastLibraryID)).total == 1)
    }

    @Test("an unknown folder is a 404 and creates nothing")
    func unknownFolder() async throws {
        let (seed, folder, admin) = try await seededFolder()
        let good = request(seed, folder, title: "Contract Cast " + UUID().uuidString.prefix(8).lowercased())
        let body = NewPodcastRequest(libraryID: good.libraryID, folderID: "missing", path: good.path, media: good.media)
        try await withCreatedPodcasts(admin) { created in
            await expectStatus(404) { try await create(body, as: admin, registering: created) }
        }
        #expect(try await admin.client.send(LibraryEndpoints.items(libraryID: seed.podcastLibraryID)).total == 1)
    }

    @Test("a user who isn't an admin gets 403 Forbidden from create and from feed lookup")
    func nonAdminIsForbidden() async throws {
        let (seed, folder, admin) = try await seededFolder()
        let body = request(seed, folder, title: "Contract Cast " + UUID().uuidString.prefix(8).lowercased())
        // Deleting the user doesn't delete podcasts it created, so the admin cleans those up.
        try await withCreatedPodcasts(admin) { created in
            try await ContractServer.require().withUser { user in
                #expect(user.user.type == .user)
                await expectStatus(403, "Forbidden") { try await create(body, as: user, registering: created) }
                await expectStatus(403, "Forbidden") {
                    try await user.client.send(PodcastEndpoints.feed(rssFeed: "https://example.com/contract.xml"))
                }
            }
        }
        #expect(try await admin.client.send(LibraryEndpoints.items(libraryID: seed.podcastLibraryID)).total == 1)
    }

    @Test("feed lookup: an invalid URL is a 400 with a message; an unusable feed is a 404")
    func feedErrors() async throws {
        let admin = try await ContractAdmin.shared.session()
        await expectStatus(400, #"Invalid request body. "rssFeed" must be a valid URL"#) {
            try await admin.client.send(PodcastEndpoints.feed(rssFeed: "not a url"))
        }
        // The SSRF filter refuses loopback before connecting, so this needs no network and no
        // listener; a feed on the user's LAN fails the same way.
        await expectStatus(404) {
            try await admin.client.send(PodcastEndpoints.feed(rssFeed: "http://127.0.0.1:9/contract.xml"))
        }
    }
}

/// The exact IDs of the podcasts a test created, including ones a request was expected to refuse.
private actor CreatedPodcasts {
    private(set) var ids: [String] = []
    func add(_ id: String) { ids.append(id) }
}

/// `POST /api/podcasts` read as raw JSON, so a created item's ID is registered before decoding
/// or any expectation can fail (as `CollectionContractFixture.send`). Returns the item and the raw object.
@discardableResult
private func create(
    _ body: NewPodcastRequest, as session: ContractSession, registering created: CreatedPodcasts
) async throws -> (LibraryItem, [String: Any]) {
    let endpoint = PodcastEndpoints.create(body)
    let rawEndpoint = Endpoint<Data>(
        endpoint.method, endpoint.path, body: endpoint.body, staysOnOrigin: endpoint.staysOnOrigin)
    let data = try await session.client.send(rawEndpoint)
    let raw = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    await created.add(try #require(raw["id"] as? String, "The created podcast has an id"))
    return (try JSONDecoder().decode(LibraryItem.self, from: data), raw)
}

/// Runs `body`, then hard-deletes every podcast it registered with the admin session, on success
/// and on failure, and checks each is gone.
private func withCreatedPodcasts(
    _ admin: ContractSession, _ body: (CreatedPodcasts) async throws -> Void
) async throws {
    let created = CreatedPodcasts()
    do {
        try await body(created)
    } catch {
        for id in await created.ids { _ = try? await admin.client.send(deleteHard(id)) }
        throw error
    }
    let ids = await created.ids
    for id in ids { _ = try await admin.client.send(deleteHard(id)) }
    for id in ids { await expectNotFound { try await admin.client.send(ItemEndpoints.item(id: id)) } }
}

/// `DELETE /api/items/:id?hard=1`: removes the item and its folder on disk; answers `OK`.
private func deleteHard(_ id: String) -> Endpoint<EmptyResponse> {
    Endpoint(.delete, "/api/items/\(id)", query: [URLQueryItem(name: "hard", value: "1")])
}
