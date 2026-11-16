import ABSAPI
import ABSAppModel
import ABSCore
import ABSData
import CryptoKit
import Foundation
import Synchronization
import Testing

@testable import ABSDownloads

private func fetch(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    let (data, response) = try await URLSession(configuration: .ephemeral).data(for: request)
    return (data, try #require(response as? HTTPURLResponse))
}

/// A connection with custom headers downloads a seeded book end to end in the engine's foreground
/// session (#467), through the production stack: `ServerValidator` and `APIClient` for the
/// connection, `AccountDownloadCredentials`, `DownloadManager` and `DownloadEngine` with the
/// production foreground session and redirect check. The connection is to `HeaderGateProxy`, an
/// access gate in front of the server that refuses any request without the headers, so a request
/// sent without them fails the download.
///
/// Not covered here: a transfer paused by suspension and resumed with `Range`
/// (`DownloadEngineForegroundTests` and `DownloadForegroundResumeIntegrationTests` cover it), and the
/// app's `AccountManager` and `DownloadsController` wiring.
@Suite(
    "Server contract: custom-header downloads", .requiresServer, .tags(.serverContract), .serialized,
    .timeLimit(.minutes(2)))
struct CustomHeaderDownloadContractTests {
    enum Book: String, CaseIterable, Sendable {
        /// Two MP3 files.
        case tale
        /// One M4B file.
        case singleFile
    }

    /// The headers a Cloudflare Access service token sends.
    static let headers = [
        "CF-Access-Client-Id": "contract-client.access", "CF-Access-Client-Secret": UUID().uuidString,
    ]

    @Test("a book downloads through a header gate in the foreground session", arguments: Book.allCases)
    func download(_ book: Book) async throws {
        let seed = try await ContractSeed.shared.data()
        let itemID = book == .tale ? seed.taleID : seed.singleFileID
        try await ContractServer.require().withUser { session in
            let gate = try HeaderGateProxy(upstream: session.configuration.baseURL, required: Self.headers)
            let sessions = SessionRecorder()
            let root = FileManager.default.temporaryDirectory.appending(
                path: "abs-custom-header-downloads-\(UUID().uuidString)", directoryHint: .isDirectory)
            defer {
                sessions.invalidate()
                gate.stop()
                try? FileManager.default.removeItem(at: root)
            }
            try await gate.start()

            // The gate refuses a request without the headers.
            #expect(try await fetch(URLRequest(url: gate.url.appending(path: "ping"))).1.statusCode == 403)

            let server = try await ServerValidator().validate(
                address: gate.url.absoluteString, customHeaders: Self.headers)
            let client = server.makeClient(tokenProvider: InMemoryTokenProvider(session.tokens.current))
            let item = try await client.send(ItemEndpoints.item(id: itemID))
            let audioFiles = try #require(item.book?.audioFiles)
            #expect(audioFiles.count == (book == .tale ? 2 : 1))

            let locations = DownloadLocations(root: root)
            let (local, partIDs) = try await Self.download(
                item, of: session, with: client, from: server, locations: locations, sessions: sessions)
            let requests = gate.requests

            // Every task was a foreground one, one per part; the background session made none.
            let tasks = sessions.tasks
            #expect(tasks.allSatisfy { $0.inForegroundSession && $0.task.isForeground })
            #expect(Set(tasks.compactMap { $0.task.partID }) == partIDs)
            #expect(sessions.foregroundSessions == 1)

            // Each file came through the gate with the bearer token, never a token in the query.
            let downloads = requests.filter { $0.target.hasPrefix("/api/items/\(itemID)/file/") }
            #expect(downloads.allSatisfy { $0.method == "GET" && $0.allowed })
            #expect(downloads.allSatisfy { $0.headers["authorization"]?.hasPrefix("Bearer ") == true })
            #expect(!downloads.contains { $0.target.contains("token=") })
            for file in audioFiles {
                #expect(downloads.contains { $0.target == DownloadRequests.filePath(itemID: itemID, ino: file.ino) })
            }

            // Every file is on disk as the server serves it, and ranges pass through the gate.
            #expect(local.files.map(\.kind) == Array(repeating: .audio, count: audioFiles.count))
            #expect(Set(local.files.compactMap(\.serverIno)) == Set(audioFiles.map(\.ino)))
            let token = try #require(session.tokens.current).accessToken
            for file in local.files {
                let ino = try #require(file.serverIno)
                let size = try #require(audioFiles.first { $0.ino == ino }?.metadata?.size)
                let bytes = try Data(contentsOf: try locations.fileURL(forRelativePath: file.relativePath))
                #expect(bytes.count == size)
                #expect(file.size == Int64(size))
                let path = DownloadRequests.filePath(itemID: itemID, ino: ino)
                let direct = try await fetch(
                    try DownloadRequests.request(path: path, configuration: session.configuration, accessToken: token))
                #expect(direct.1.statusCode == 200)
                #expect(bytes == direct.0)
                var ranged = try DownloadRequests.request(
                    path: path, configuration: server.configuration, accessToken: token)
                ranged.setValue("bytes=10-19", forHTTPHeaderField: "Range")
                let partial = try await fetch(ranged)
                #expect(partial.1.statusCode == 206)
                #expect(partial.0 == bytes[10...19])
            }

            // The probe was the only request without the headers.
            #expect(gate.requests.filter { !$0.allowed }.map(\.target) == ["/ping"])
        }
    }

    /// Downloads `item` with the production manager and engine as the app wires them, and returns
    /// the local item and the record's part IDs. The engine is deactivated before it returns, as
    /// on suspension, so no transfer outlives the test.
    private static func download(
        _ item: LibraryItem, of session: ContractSession, with client: APIClient, from server: ValidatedServer,
        locations: DownloadLocations, sessions: SessionRecorder
    ) async throws -> (LocalLibraryItemDTO, Set<UUID>) {
        let container = try DataStack(location: .inMemory).container
        let store = DownloadStore(modelContainer: container)
        let localItems = LocalItemStore(modelContainer: container)
        let connectionID = try await ServerConnectionStore(modelContainer: container).upsertLogin(
            address: server.address, userId: session.user.id, username: session.user.username, authMethod: .local,
            serverVersion: server.status.serverVersion
        ).id
        let credentials = AccountDownloadCredentials { $0 == connectionID ? client : nil }
        #expect(await credentials.usesForegroundSession(for: connectionID))
        let engine = DownloadEngine(
            store: store, localItems: localItems, credentials: credentials,
            vault: ResumeDataVault(directory: locations.resumeDataRoot, keyStore: MemoryResumeDataKeys()),
            locations: locations, networkAccess: { NetworkAccess(policy: .always) },
            makeSession: sessions.backgroundStandIn(),
            makeForegroundSession: sessions.recording(DownloadEngine.foregroundSession()),
            preflight: DownloadRedirectPreflight())
        let manager = DownloadManager(
            store: store, localItems: localItems, engine: engine, locations: locations,
            capacity: VolumeStorageCapacity(locations: locations))
        do {
            try await manager.start()
            let events = await manager.events()
            #expect(await engine.activate())
            let result = try await manager.enqueue(item: item, episodeID: nil, connectionID: connectionID)
            guard case .started(let recordID) = result else { throw ExpectationFailed("Enqueued as \(result)") }
            var partIDs = Set<UUID>()
            var outcome: DownloadManagerEvent?
            events: for await event in events {
                switch event {
                case .recordChanged(let record) where record.id == recordID:
                    partIDs.formUnion(record.parts.map(\.id))
                case .completed(recordID, _, _), .failed(recordID, _, _), .recordRemoved(recordID):
                    outcome = event
                    break events
                default: break
                }
            }
            guard case .completed(_, let itemID, _) = outcome else {
                throw ExpectationFailed("The download ended with \(String(describing: outcome))")
            }
            await engine.deactivate()
            return (try #require(try await localItems.item(id: itemID)), partIDs)
        } catch {
            await engine.deactivate()
            throw error
        }
    }
}

private struct ExpectationFailed: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// The resume data key in memory, so the test doesn't use the Keychain.
private final class MemoryResumeDataKeys: ResumeDataKeyStore {
    private let key = SymmetricKey(size: .bits256)
    func loadKey() throws -> SymmetricKey? { key }
    func createKey() throws -> SymmetricKey { key }
}

/// Makes the engine's sessions and records the tasks it creates in them. The foreground session is
/// the production one. The background session is a stand-in: the production one has a fixed
/// identifier an installed app may hold. It makes an ephemeral session with the engine's delegate
/// only if a task is asked of it, which a custom-header connection must never do.
private final class SessionRecorder: Sendable {
    struct RecordedTask: Sendable {
        let task: URLSessionDownloadTask
        let inForegroundSession: Bool
    }

    private let state = Mutex<(sessions: [URLSession], foreground: Int, tasks: [RecordedTask])>(([], 0, []))

    var tasks: [RecordedTask] { state.withLock { $0.tasks } }
    /// How many sessions the production foreground factory made.
    var foregroundSessions: Int { state.withLock { $0.foreground } }

    func recording(_ make: @escaping DownloadSessionFactory) -> DownloadSessionFactory {
        { [self] delegate in
            let session = make(delegate)
            state.withLock {
                $0.foreground += 1
                if let session = session as? URLSession { $0.sessions.append(session) }
            }
            return RecordedSession(inForeground: true, recorder: self) { session }
        }
    }

    func backgroundStandIn() -> DownloadSessionFactory {
        { [self] delegate in
            RecordedSession(inForeground: false, recorder: self) { [self] in
                let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
                state.withLock { $0.sessions.append(session) }
                return session
            }
        }
    }

    func record(_ task: URLSessionDownloadTask, inForeground: Bool) -> URLSessionDownloadTask {
        state.withLock { $0.tasks.append(RecordedTask(task: task, inForegroundSession: inForeground)) }
        return task
    }

    /// Cancels and invalidates every session made.
    func invalidate() {
        for session in state.withLock({ $0.sessions }) { session.invalidateAndCancel() }
    }
}

/// A session made on first use, recording the tasks created in it.
private final class RecordedSession: DownloadSession {
    private let inForeground: Bool
    private let recorder: SessionRecorder
    private let make: @Sendable () -> any DownloadSession
    private let made = Mutex<(any DownloadSession)?>(nil)

    init(inForeground: Bool, recorder: SessionRecorder, make: @escaping @Sendable () -> any DownloadSession) {
        self.inForeground = inForeground
        self.recorder = recorder
        self.make = make
    }

    private var session: any DownloadSession {
        made.withLock { made in
            if let made { return made }
            let session = make()
            made = session
            return session
        }
    }

    func downloadTask(with request: URLRequest) -> URLSessionDownloadTask {
        recorder.record(session.downloadTask(with: request), inForeground: inForeground)
    }

    func downloadTask(withResumeData resumeData: Data) -> URLSessionDownloadTask {
        recorder.record(session.downloadTask(withResumeData: resumeData), inForeground: inForeground)
    }

    var allTasks: [URLSessionTask] {
        get async {
            guard let session = made.withLock({ $0 }) else { return [] }
            return await session.allTasks
        }
    }

    func finishTasksAndInvalidate() {
        session.finishTasksAndInvalidate()
    }
}
