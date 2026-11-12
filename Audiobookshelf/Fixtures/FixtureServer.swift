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
    /// use ``FixtureURLProtocol``; nothing registers it globally.
    enum FixtureServer {
        static let launchArgument = "-ABSFixtures"
        static let host = "fixtures.audiobookshelf.invalid"
        /// The address to type on the connect screen.
        static let address = "https://\(host)"

        static var isEnabled: Bool { ProcessInfo.processInfo.arguments.contains(launchArgument) }

        /// The app's API session configuration with ``FixtureURLProtocol`` first.
        @Sendable static func sessionConfiguration() -> URLSessionConfiguration {
            fixtureConfiguration(.absConnection())
        }

        /// `configuration` with ``FixtureURLProtocol`` in front of its own protocols.
        static func fixtureConfiguration(_ configuration: URLSessionConfiguration) -> URLSessionConfiguration {
            configuration.protocolClasses = [FixtureURLProtocol.self] + (configuration.protocolClasses ?? [])
            return configuration
        }

        /// The environment for a fixture launch: an in-memory store, Keychain and settings.
        @MainActor static func environment() -> AppEnvironment {
            let suite = "org.davidjensenius.Audiobookshelf.fixtures"
            let defaults = UserDefaults(suiteName: suite) ?? .standard
            defaults.removePersistentDomain(forName: suite)
            return AppEnvironment(
                settings: AppSettings(defaults: defaults), storeLocation: .inMemory, keychain: FixtureKeychain(),
                sessionConfiguration: sessionConfiguration,
                coverSessionConfiguration: fixtureConfiguration(.ephemeral))
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
            default: return nil
            }
        }

        /// The reply to `method` and `path` from `bundle`. A request without a fixture is a 404,
        /// logged with its path so a missing fixture is obvious.
        static func reply(method: String, path: String, bundle: Bundle = .main) -> Reply {
            // `/logout` returns no end-session URL for a local sign-in.
            if method == "POST", path == "/logout" {
                return Reply(status: 200, contentType: "application/json", body: Data(#"{}"#.utf8))
            }
            guard let resource = resource(method: method, path: path),
                let url = bundle.url(forResource: resource.name, withExtension: resource.ext),
                let body = try? Data(contentsOf: url)
            else {
                Log.api.error("Fixture server: no fixture for \(method, privacy: .public) \(path, privacy: .public)")
                return .notFound
            }
            return Reply(
                status: 200, contentType: resource.ext == "png" ? "image/png" : "application/json", body: body)
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
