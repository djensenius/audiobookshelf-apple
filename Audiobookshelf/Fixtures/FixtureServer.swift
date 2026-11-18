#if DEBUG
    import ABSAPI
    import ABSAppModel
    import ABSCore
    import ABSDownloads
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

        /// Followed by an ``AppTheme`` raw value (`-ABSTheme dark`), sets a fixture launch's theme,
        /// so UI tests audit dark and black without switching the simulator's appearance, which a
        /// newly created simulator ignores until it's rebooted (#641).
        static let themeArgument = "-ABSTheme"

        /// The theme `arguments` ask for with ``themeArgument``, or `nil` for none or an unknown one.
        static func theme(arguments: [String]) -> AppTheme? {
            guard let index = arguments.firstIndex(of: themeArgument), index + 1 < arguments.endIndex else {
                return nil
            }
            return AppTheme(rawValue: arguments[index + 1])
        }

        /// With ``launchArgument``, keeps every track download under way (#685): its reply sends the headers and the
        /// first half of the audio, then nothing more, so the download queue and the tab roots' queue indicator stay
        /// up for UI tests and screenshots. Only for about a minute: the download session's request timeout (a minute
        /// without data, by default) can then end the transfer.
        static let stallDownloadsArgument = "-ABSStallDownloads"

        /// Whether a fixture launch with `arguments` stalls a `method` request for `path` (``stallDownloadsArgument``):
        /// only a track's download does.
        static func stalls(method: String, path: String, arguments: [String]) -> Bool {
            arguments.contains(stallDownloadsArgument) && method == "GET" && isTrackDownload(path)
        }

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

        /// The environment for a fixture launch: an in-memory store, Keychain and settings, and a
        /// download stack of its own: its files in ``downloadsDirectory``, emptied on every fixture
        /// launch, so it never sees the app's real downloads, and sessions and a redirect preflight
        /// that only ``FixtureURLProtocol`` answers (``downloadSession``,
        /// ``foregroundDownloadSession``, ``downloadPreflight``), so a transfer never reaches the network.
        /// The settings take ``themeArgument``'s theme, if the launch has one.
        @MainActor static func environment() -> AppEnvironment {
            let suite = "org.davidjensenius.Audiobookshelf.fixtures"
            let defaults = UserDefaults(suiteName: suite) ?? .standard
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: downloadsDirectory)
            let settings = AppSettings(defaults: defaults)
            if let theme = theme(arguments: ProcessInfo.processInfo.arguments) { settings.theme = theme }
            return AppEnvironment(
                settings: settings, storeLocation: .inMemory, keychain: FixtureKeychain(),
                sessionConfiguration: sessionConfiguration, downloadsRoot: downloadsDirectory,
                makeDownloadSession: downloadSession, makeForegroundDownloadSession: foregroundDownloadSession,
                downloadPreflight: downloadPreflight, covers: coverSource(), realtime: false)
        }

        /// The fixture download engine's session: a non-background one, which ``FixtureURLProtocol`` can answer.
        static let downloadSession: DownloadSessionFactory = {
            URLSession(configuration: fixtureConfiguration(.ephemeral), delegate: $0, delegateQueue: nil)
        }

        /// The fixture download engine's session for connections with custom headers.
        static let foregroundDownloadSession: DownloadSessionFactory = {
            URLSession(configuration: fixtureConfiguration(.absForegroundDownloads()), delegate: $0, delegateQueue: nil)
        }

        /// The fixture download engine's redirect check, answered by ``FixtureURLProtocol``.
        static let downloadPreflight = DownloadRedirectPreflight { fixtureConfiguration(.ephemeral) }

        /// The fixture download stack's root (`Downloads/` and `ResumeData/`), in the temporary
        /// directory.
        static var downloadsDirectory: URL {
            URL.temporaryDirectory.appending(path: "AudiobookshelfFixtures/Downloads", directoryHint: .isDirectory)
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

        /// The fixture resource that answers `method` and `path` with `query`, or `nil` for a request without one.
        /// An item's cover is its own `fixture-cover-<id>.png` in `bundle` (`scripts/fixture-covers.swift`),
        /// or the shared `fixture-cover.png` for an item without one. Only the items list reads `query`: a
        /// series filter (``seriesID(filter:)``) answers with that series' page, and any other query with every item.
        static func resource(method: String, path: String, query: [URLQueryItem] = [], bundle: Bundle = .main) -> (
            name: String, ext: String
        )? {
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
            // A series' books (`SeriesDetailModel.booksQuery`) are the series' own page; an unknown series has none.
            // The Library's "no series" filter (`LibraryFilter.noSeries`) isn't a series, so it gets every item.
            case ("GET", library + "/items"):
                guard let filter = query.first(where: { $0.name == "filter" })?.value, filter.hasPrefix("series.")
                else { return ("fixture-items", "json") }
                let id = seriesID(filter: filter)
                if id == LibraryFilter.noSeries.value { return ("fixture-items", "json") }
                return id.map { ("fixture-items-series-\($0)", "json") }
            case ("GET", library + "/series"): return ("fixture-series", "json")
            // A series' metadata and progress (`SeriesEndpoints.detail(id:)`).
            case ("GET", _) where parts.count == 3 && parts[0...1] == ["api", "series"]:
                return ("fixture-series-\(parts[2])", "json")
            case ("GET", _) where parts.count == 4 && parts[0...1] == ["api", "items"] && parts[3] == "cover":
                let own = "fixture-cover-\(parts[2])"
                return (bundle.url(forResource: own, withExtension: "png") == nil ? "fixture-cover" : own, "png")
            case ("GET", _) where parts.count == 3 && parts[0...1] == ["api", "items"]:
                return ("fixture-item-\(parts[2])", "json")
            case ("POST", _) where parts.count == 4 && parts[0...1] == ["api", "items"] && parts[3] == "play":
                return ("fixture-play-\(parts[2])", "json")
            // Only Pride and Prejudice has a session fixture, so every open session is one of its.
            case ("GET", _) where parts.count == 3 && parts[0...1] == ["api", "session"]:
                return ("fixture-play-\(SampleLibrary.prideAndPrejudice.id)", "json")
            // A track's download (`DownloadRequests.filePath(itemID:ino:)`): every fixture file is the bundled audio.
            case ("GET", _) where isTrackDownload(path):
                return audio
            default: return nil
            }
        }

        /// The series ID in a `series.<value>` filter, or `nil` when the value doesn't decode to one. `filter` is the
        /// query value `URLComponents` decoded once, still the percent-encoded Base64 of `LibraryFilter.encode`, so
        /// this decodes it as the server does: percent-decoding, then Base64. Only letters, digits, `_` and `-` make
        /// an ID, so it names a fixture file.
        static func seriesID(filter: String) -> String? {
            let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-"))
            guard let encoded = filter.dropFirst("series.".count).removingPercentEncoding,
                let data = Data(base64Encoded: encoded), let id = String(data: data, encoding: .utf8), !id.isEmpty,
                id.unicodeScalars.allSatisfy(allowed.contains)
            else { return nil }
            return id
        }

        /// The reply to `method` and `path` with `query` from `bundle`. A request without a fixture is a 404,
        /// logged with its path and query so a missing fixture is obvious.
        static func reply(method: String, path: String, query: [URLQueryItem] = [], bundle: Bundle = .main) -> Reply {
            // `/logout` returns no end-session URL for a local sign-in, and a session's `/sync` and
            // `/close` return nothing the app reads.
            if method == "POST", path == "/logout" || isSessionReport(path) {
                return Reply(status: 200, contentType: "application/json", body: Data(#"{}"#.utf8))
            }
            guard let resource = resource(method: method, path: path, query: query, bundle: bundle),
                let url = bundle.url(forResource: resource.name, withExtension: resource.ext),
                var body = try? Data(contentsOf: url)
            else {
                var components = URLComponents()
                components.queryItems = query.isEmpty ? nil : query
                let target = components.percentEncodedQuery.map { "\(path)?\($0)" } ?? path
                Log.api.error("Fixture server: no fixture for \(method, privacy: .public) \(target, privacy: .public)")
                return .notFound
            }
            if let sessionID = sessionID(method: method, path: path) {
                body = Data(String(decoding: body, as: UTF8.self).replacing(sessionPlaceholder, with: sessionID).utf8)
            }
            return Reply(status: 200, contentType: contentType(ext: resource.ext), body: body)
        }

        /// The `Content-Type` of a fixture file with extension `ext`.
        private static func contentType(ext: String) -> String {
            switch ext {
            case "png": "image/png"
            case audio.ext: "audio/mp4"
            default: "application/json"
            }
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

        /// Whether `path` is a track's download, `/api/items/:id/file/:ino/download` (`DownloadRequests.filePath(itemID:ino:)`).
        private static func isTrackDownload(_ path: String) -> Bool {
            let parts = path.split(separator: "/").map(String.init)
            return parts.count == 6 && parts[0...1] == ["api", "items"] && parts[3] == "file" && parts[5] == "download"
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
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let reply = FixtureServer.reply(method: request.httpMethod ?? "GET", path: url.path(), query: query)
            let response = HTTPURLResponse(
                url: url, statusCode: reply.status, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": reply.contentType, "Content-Length": String(reply.body.count)])!
            guard !isStopped.withLock({ $0 }) else { return }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            let stalls =
                reply.status == 200
                && FixtureServer.stalls(
                    method: request.httpMethod ?? "GET", path: url.path(), arguments: ProcessInfo.processInfo.arguments)
            guard !stalls else {
                client?.urlProtocol(self, didLoad: reply.body.prefix(reply.body.count / 2))
                return
            }
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
