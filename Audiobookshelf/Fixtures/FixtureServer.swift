#if DEBUG
    import ABSAPI
    import ABSAppModel
    import ABSCore
    import Foundation
    import Synchronization

    /// A canned Audiobookshelf server for UI tests (#46). Launched with ``launchArgument``, the
    /// app answers requests to ``address`` from the bundled `fixture-*` files instead of the
    /// network, and keeps its store, Keychain and settings in memory, so every launch starts
    /// signed out. Debug builds only: Release compiles this out and leaves the files out.
    ///
    /// Only the API sessions the app is given (``sessionConfiguration()``) and the cover pipeline
    /// use ``FixtureURLProtocol``; nothing registers it globally. Playback scopes get
    /// ``trackURL(_:bundle:)``, so a fixture session's tracks play the bundled ``audio``.
    enum FixtureServer {
        static let launchArgument = "-ABSFixtures"
        static let host = "fixtures.audiobookshelf.invalid"
        /// The address to type on the connect screen.
        static let address = "https://\(host)"

        static var isEnabled: Bool { ProcessInfo.processInfo.arguments.contains(launchArgument) }

        /// The session ID in `fixture-play-*.json`, which each reply replaces: every `/play` opens a
        /// new session, as on a real server, and `GET /api/session/:id` answers with the ID asked for.
        static let sessionPlaceholder = "fixture-session-id"
        /// What every fixture session's direct-play tracks play: a minute of silence.
        static let audio = (name: "fixture-silence", ext: "m4a")

        /// The app's API session configuration with ``FixtureURLProtocol`` first.
        @Sendable static func sessionConfiguration() -> URLSessionConfiguration {
            fixtureConfiguration(.absConnection())
        }

        /// `configuration` with ``FixtureURLProtocol`` in front of its own protocols.
        static func fixtureConfiguration(_ configuration: URLSessionConfiguration) -> URLSessionConfiguration {
            configuration.protocolClasses = [FixtureURLProtocol.self] + (configuration.protocolClasses ?? [])
            return configuration
        }

        /// The environment for a fixture launch: an in-memory store, Keychain and settings, and no
        /// download stack, whose sweep would otherwise check the app's real downloads against the
        /// empty store.
        @MainActor static func environment() -> AppEnvironment {
            let suite = "org.davidjensenius.Audiobookshelf.fixtures"
            let defaults = UserDefaults(suiteName: suite) ?? .standard
            defaults.removePersistentDomain(forName: suite)
            return AppEnvironment(
                settings: AppSettings(defaults: defaults), storeLocation: .inMemory, keychain: FixtureKeychain(),
                sessionConfiguration: sessionConfiguration, downloadsRoot: nil, covers: coverSource(), realtime: false)
        }

        /// A fixture launch's covers: answered by ``FixtureURLProtocol``, so they never wait for
        /// the network monitor, and cached in ``coverDirectory``, so they never share the app's
        /// cache or evict its covers.
        static func coverSource() -> CoverSource {
            try? FileManager.default.removeItem(at: coverDirectory)
            return CoverSource(
                sessionConfiguration: fixtureConfiguration(.ephemeral), directory: coverDirectory, isOnline: { true })
        }

        /// The fixture cover cache, in the temporary directory and emptied on every fixture launch.
        static var coverDirectory: URL {
            URL.temporaryDirectory.appending(path: "AudiobookshelfFixtures/Covers", directoryHint: .isDirectory)
        }

        /// A reply: the status, content type and body.
        struct Reply: Equatable {
            let status: Int
            let contentType: String
            let body: Data

            static let notFound = Reply(status: 404, contentType: "application/json", body: Data(#"{}"#.utf8))
        }

        /// The fixture resource that answers `method` and `path`, or `nil` for a request without one.
        static func resource(method: String, path: String) -> (name: String, ext: String)? {
            let parts = path.split(separator: "/").map(String.init)
            let library = "/api/libraries/\(SampleLibrary.libraryID)"
            switch (method, path) {
            case ("GET", "/status"): return ("fixture-status", "json")
            case ("GET", "/ping"): return ("fixture-ping", "json")
            case ("POST", "/login"), ("POST", "/api/authorize"): return ("fixture-login", "json")
            case ("GET", "/api/me"): return ("fixture-me", "json")
            case ("GET", "/api/libraries"): return ("fixture-libraries", "json")
            case ("GET", library): return ("fixture-library", "json")
            case ("GET", library + "/personalized"): return ("fixture-personalized", "json")
            case ("GET", library + "/items"): return ("fixture-items", "json")
            case ("GET", _) where parts.count == 4 && parts[0...1] == ["api", "items"] && parts[3] == "cover":
                return ("fixture-cover", "png")
            case ("GET", _) where parts.count == 3 && parts[0...1] == ["api", "items"]:
                return ("fixture-item-\(parts[2])", "json")
            case ("POST", _) where parts.count == 4 && parts[0...1] == ["api", "items"] && parts[3] == "play":
                return ("fixture-play-\(parts[2])", "json")
            // Only Pride and Prejudice has a session fixture, so every open session is one of its.
            case ("GET", _) where parts.count == 3 && parts[0...1] == ["api", "session"]:
                return ("fixture-play-\(SampleLibrary.prideAndPrejudice.id)", "json")
            default: return nil
            }
        }

        /// The reply to `method` and `path` from `bundle`. A request without a fixture is a 404,
        /// logged with its path so a missing fixture is obvious.
        static func reply(method: String, path: String, bundle: Bundle = .main) -> Reply {
            // `/logout` returns no end-session URL for a local sign-in, and a session's `/sync` and
            // `/close` return nothing the app reads.
            if method == "POST", path == "/logout" || isSessionReport(path) {
                return Reply(status: 200, contentType: "application/json", body: Data(#"{}"#.utf8))
            }
            guard let resource = resource(method: method, path: path),
                let url = bundle.url(forResource: resource.name, withExtension: resource.ext),
                var body = try? Data(contentsOf: url)
            else {
                Log.api.error("Fixture server: no fixture for \(method, privacy: .public) \(path, privacy: .public)")
                return .notFound
            }
            if let sessionID = sessionID(method: method, path: path) {
                body = Data(String(decoding: body, as: UTF8.self).replacing(sessionPlaceholder, with: sessionID).utf8)
            }
            return Reply(
                status: 200, contentType: resource.ext == "png" ? "image/png" : "application/json", body: body)
        }

        /// What AVPlayer loads for a resolved track `url`: the bundled ``audio`` for a fixture
        /// session's direct-play track (`/public/session/:id/track/:index` on ``host``), and `url`
        /// itself for anything else. AVPlayer loads media outside the app's URL sessions, so
        /// ``FixtureURLProtocol`` can't answer it.
        static func trackURL(_ url: URL, bundle: Bundle = .main) -> URL {
            let parts = url.path().split(separator: "/").map(String.init)
            guard url.host() == host, parts.count == 5, parts[0...1] == ["public", "session"], parts[3] == "track"
            else { return url }
            guard let file = bundle.url(forResource: audio.name, withExtension: audio.ext) else {
                Log.api.error("Fixture server: no fixture audio")
                return url
            }
            return file
        }

        /// Whether `path` is a session's `/api/session/:id/sync` or `/api/session/:id/close`.
        private static func isSessionReport(_ path: String) -> Bool {
            let parts = path.split(separator: "/").map(String.init)
            return parts.count == 4 && parts[0...1] == ["api", "session"] && ["sync", "close"].contains(parts[3])
        }

        /// The ID a session reply carries: a new one for each `/play`, the one asked for by
        /// `GET /api/session/:id`, and `nil` for any other reply.
        private static func sessionID(method: String, path: String) -> String? {
            let parts = path.split(separator: "/").map(String.init)
            switch method {
            case "POST" where parts.count == 4 && parts[0...1] == ["api", "items"] && parts[3] == "play":
                return UUID().uuidString.lowercased()
            case "GET" where parts.count == 3 && parts[0...1] == ["api", "session"]: return parts[2]
            default: return nil
            }
        }
    }

    /// Answers requests to ``FixtureServer/host`` from the fixture files. Registered only on the
    /// session configurations ``FixtureServer`` builds.
    final class FixtureURLProtocol: URLProtocol {
        /// Set once URLSession stops this load.
        private let isStopped = Mutex(false)

        override class func canInit(with request: URLRequest) -> Bool {
            request.url?.host() == FixtureServer.host
        }

        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            guard let url = request.url else { return }
            let reply = FixtureServer.reply(method: request.httpMethod ?? "GET", path: url.path())
            let response = HTTPURLResponse(
                url: url, statusCode: reply.status, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": reply.contentType])!
            guard !isStopped.withLock({ $0 }) else { return }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: reply.body)
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {
            isStopped.withLock { $0 = true }
        }
    }

    /// An in-memory Keychain, so a fixture launch neither reads nor leaves saved sessions.
    final class FixtureKeychain: KeychainStoring {
        private let items = Mutex<[KeychainItem: Data]>([:])

        func data(for item: KeychainItem) throws(KeychainError) -> Data? {
            items.withLock { $0[item] }
        }

        func add(_ data: Data, for item: KeychainItem, accessibility: KeychainAccessibility) throws(KeychainError)
            -> Bool
        {
            items.withLock {
                guard $0[item] == nil else { return false }
                $0[item] = data
                return true
            }
        }

        func delete(_ item: KeychainItem) throws(KeychainError) {
            items.withLock { $0[item] = nil }
        }
    }
#endif
