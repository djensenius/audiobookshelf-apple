import ABSAPI
import ABSCore
import Foundation
import Testing

/// Playlist-local exact-ID ledger. Ordinary owners delete their own playlists, never an admin.
/// User deletion is the explicit fallback for inaccessible/auto-deleted playlists; verify every ID.
actor PlaylistContractFixture {
    let admin: ContractSession
    let seed: SeedData
    private var playlists: [(String, ContractSession)] = []
    private var users: [String] = []
    private let captureID = UUID().uuidString
    private var sequence = 0

    init(admin: ContractSession, seed: SeedData) {
        self.admin = admin
        self.seed = seed
    }

    static func withFixture<T: Sendable>(_ body: (PlaylistContractFixture) async throws -> T) async throws -> T {
        let fixture = try await PlaylistContractFixture(
            admin: ContractAdmin.shared.session(), seed: ContractSeed.shared.data())
        let value: T
        do {
            value = try await body(fixture)
        } catch {
            for failure in await fixture.cleanup() { Issue.record("Playlist cleanup failed: \(failure)") }
            throw error
        }
        let failures = await fixture.cleanup()
        if !failures.isEmpty { throw CleanupFailure(resources: failures) }
        return value
    }

    func user(accessibleLibraries: [String]? = nil) async throws -> ContractSession {
        let name = "playlist-" + UUID().uuidString
        let password = UUID().uuidString
        let created = try await admin.client.send(
            Endpoint<CreatedUser>(
                .post, "/api/users",
                body: NewUser(
                    username: name, password: password,
                    permissions: accessibleLibraries == nil ? nil : ["accessAllLibraries": false],
                    librariesAccessible: accessibleLibraries)))
        users.append(created.user.id)
        let session = try await ContractServer.require().signIn(username: name, password: password)
        #expect(session.user.type == .user)
        #expect(!session.user.permissions.update)
        #expect(!session.user.permissions.delete)
        return session
    }

    func restrict(_ session: ContractSession) async throws {
        struct Access: Encodable, Sendable {
            let permissions = ["accessAllLibraries": false]
            let librariesAccessible: [String]
        }
        _ = try await admin.client.send(
            Endpoint<Data>(
                .patch, "/api/users/\(session.user.id)",
                body: Access(librariesAccessible: [seed.podcastLibraryID])))
    }

    var books: [PlaylistItemReference] {
        [PlaylistItemReference(libraryItemID: seed.taleID), PlaylistItemReference(libraryItemID: seed.singleFileID)]
    }

    var episode: PlaylistItemReference {
        PlaylistItemReference(libraryItemID: seed.podcastID, episodeID: seed.episodeID)
    }

    func create(
        as session: ContractSession, items: [PlaylistItemReference]? = nil,
        name: String = "Synthetic playlist", libraryID: String? = nil
    ) async throws -> Playlist {
        try await send(
            PlaylistEndpoints.create(
                PlaylistCreateRequest(
                    name: name, libraryID: libraryID ?? seed.bookLibraryID,
                    items: items ?? books, description: "Initial description")), as: session)
    }

    /// Retain the actual response; never replay a write to obtain JSON. Register before any decode.
    func send(_ endpoint: Endpoint<Playlist>, as session: ContractSession) async throws -> Playlist {
        let rawEndpoint = Endpoint<Data>(
            endpoint.method, endpoint.path, query: endpoint.query, headers: endpoint.headers,
            body: endpoint.body, requiresAuthentication: endpoint.requiresAuthentication)
        let response = try await session.client.response(for: rawEndpoint)
        #expect(response.httpResponse.statusCode == 200)
        let raw = try #require(JSONSerialization.jsonObject(with: response.value) as? [String: Any])
        let id = try #require(raw["id"] as? String)
        if endpoint.method == .post, endpoint.path == "/api/playlists" {
            playlists.append((id, session))
        }
        try capture(response.value, label: "playlist")
        return try verified(response.value)
    }

    private func verified(_ data: Data) throws -> Playlist {
        let raw = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let members = try #require(raw["items"] as? [[String: Any]])
        let value = try JSONDecoder().decode(Playlist.self, from: data)
        #expect(value.items.count == members.count)
        for (member, item) in zip(members, value.items) {
            #expect(item.libraryItemId == member["libraryItemId"] as? String)
            #expect(item.episodeId == member["episodeId"] as? String)
            let libraryData = try JSONSerialization.data(withJSONObject: #require(member["libraryItem"]))
            let library = try JSONDecoder().decode(LibraryItem.self, from: libraryData)
            #expect(item.libraryItem == library)
            #expect(library.id == item.libraryItemId)
            #expect(library.media != nil)
            if let episodeID = item.episodeId {
                let episodeData = try JSONSerialization.data(withJSONObject: #require(member["episode"]))
                let episode = try JSONDecoder().decode(PodcastEpisode.self, from: episodeData)
                #expect(item.episode == episode)
                #expect(episode.id == episodeID)
                #expect(episode.libraryItemId == item.libraryItemId)
                #expect(episode.audioTrack != nil)
            }
        }
        return value
    }

    func list(libraryID: String? = nil, as session: ContractSession) async throws -> [Playlist] {
        let endpoint = LibraryEndpoints.playlists(libraryID: libraryID ?? seed.bookLibraryID)
        let response = try await session.client.response(
            for: Endpoint<Data>(endpoint.method, endpoint.path, query: endpoint.query))
        try capture(response.value, label: "list")
        let raw = try #require(JSONSerialization.jsonObject(with: response.value) as? [String: Any])
        let entries = try #require(raw["results"] as? [[String: Any]])
        let page = try JSONDecoder().decode(PagedResults<Playlist>.self, from: response.value)
        #expect(page.rawCount == entries.count)
        #expect(page.results.count == entries.count)
        for (entry, value) in zip(entries, page.results) {
            #expect(try verified(JSONSerialization.data(withJSONObject: entry)) == value)
        }
        return page.results
    }

    func read(_ id: String, as session: ContractSession) async throws -> Playlist {
        try await send(ItemEndpoints.playlist(id: id), as: session)
    }

    func delete(_ id: String, as session: ContractSession) async throws {
        let response = try await session.client.response(for: PlaylistEndpoints.delete(id: id))
        #expect(response.httpResponse.statusCode == 200)
        // Keep the ID even after explicit deletion for final absence verification.
    }

    func ownedIDs() -> (playlists: [String], users: [String]) {
        (playlists.map(\.0), users)
    }

    /// Dedicated proof of the server's user-delete cascade, not name/count cleanup.
    func deleteUser(_ session: ContractSession) async throws {
        _ = try await admin.client.send(Endpoint<EmptyResponse>(.delete, "/api/users/\(session.user.id)"))
    }

    private func cleanup() async -> [String] {
        var failures: [String] = []
        var results: [String] = []
        for (id, owner) in playlists.reversed() {
            do {
                // A deliberately deleted user cannot authenticate; its cascade is verified below.
                _ = try await admin.client.send(Endpoint<Data>(.get, "/api/users/\(owner.user.id)"))
                _ = try await owner.client.send(PlaylistEndpoints.delete(id: id))
                results.append("owner DELETE \(id): 200")
            } catch APIError.notFound {
                results.append("owner/user already absent or inaccessible \(id): 404; verify after user deletion")
            } catch {
                failures.append("owner delete \(id): \(error)")
            }
        }
        for id in users.reversed() {
            do {
                _ = try await admin.client.send(Endpoint<EmptyResponse>(.delete, "/api/users/\(id)"))
            } catch APIError.notFound {
                // Explicit cascade test already deleted this exact owned user.
            } catch { failures.append("user \(id): \(error)") }
        }
        for (id, _) in playlists {
            do {
                _ = try await admin.client.send(ItemEndpoints.playlist(id: id))
                failures.append("playlist \(id) still exists")
            } catch APIError.notFound {
                results.append("admin GET \(id): 404")
            } catch { failures.append("verify playlist \(id): \(error)") }
        }
        for id in users {
            do {
                _ = try await admin.client.send(Endpoint<Data>(.get, "/api/users/\(id)"))
                failures.append("user \(id) still exists")
            } catch APIError.notFound {
                results.append("admin GET user \(id): 404")
            } catch { failures.append("verify user \(id): \(error)") }
        }
        do {
            try capture(
                JSONSerialization.data(withJSONObject: ["results": results, "failures": failures]), label: "cleanup")
        } catch { failures.append("capture cleanup: \(error)") }
        return failures
    }

    private func capture(_ data: Data, label: String) throws {
        guard let root = ProcessInfo.processInfo.environment["ABS_PLAYLIST_LIVE_CAPTURE_DIR"] else { return }
        let directory = URL(fileURLWithPath: root).appendingPathComponent(captureID)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        sequence += 1
        try data.write(to: directory.appendingPathComponent("\(sequence)-\(label).json"))
    }

    private struct NewUser: Encodable, Sendable {
        let username: String
        let password: String
        let type = "user"
        let isActive = true
        let permissions: [String: Bool]?
        let librariesAccessible: [String]?
    }
    private struct CreatedUser: Decodable, Sendable {
        struct Identity: Decodable, Sendable { let id: String }
        let user: Identity
    }
    private struct CleanupFailure: Error { let resources: [String] }
}

func expectPlaylistStatus<T>(
    _ status: Int, sourceLocation: SourceLocation = #_sourceLocation, _ operation: () async throws -> T
) async {
    let error = await #expect(throws: APIError.self, sourceLocation: sourceLocation) { try await operation() }
    switch error {
    case .forbidden where status == 403, .notFound where status == 404: return
    case .http(let actual, _) where actual == status: return
    default: Issue.record("Expected HTTP \(status), got \(String(describing: error))", sourceLocation: sourceLocation)
    }
}
