import CoreGraphics
import Foundation
import ImageIO
import Synchronization
import UniformTypeIdentifiers

@testable import ABSCore

/// A one-shot gate: `wait()` returns once `open()` is called, or once the waiting task is
/// cancelled, so a test whose gate never opens fails at its time limit instead of hanging.
final class Gate: Sendable {
    private struct State {
        var isOpen = false
        var nextID = 0
        var waiters: [Int: CheckedContinuation<Void, Never>] = [:]
    }

    private let state = Mutex(State())

    func open() {
        let waiters = state.withLock { state in
            state.isOpen = true
            defer { state.waiters = [:] }
            return state.waiters.values
        }
        for waiter in waiters { waiter.resume() }
    }

    func wait() async {
        let id = state.withLock { state in
            defer { state.nextID += 1 }
            return state.nextID
        }
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let resumes = state.withLock { state in
                    guard !state.isOpen, !Task.isCancelled else { return true }
                    state.waiters[id] = continuation
                    return false
                }
                if resumes { continuation.resume() }
            }
        } onCancel: {
            state.withLock { $0.waiters.removeValue(forKey: id) }?.resume()
        }
    }
}

/// Answers image requests for registered hosts and records them. Kept separate from
/// ABSAPITests' stub so ABSCore tests don't depend on ABSAPI.
final class ImageStubProtocol: URLProtocol {
    struct Route: Sendable {
        var status = 200
        var body = Data()
        var mimeType = "image/png"
        /// Delivery waits for this gate (then `delay`).
        var gate: Gate?
        var delay: Duration?
        /// Sends the body in chunks of this size, `chunkDelay` apart, stopping if cancelled.
        var chunkSize: Int?
        var chunkDelay = Duration.milliseconds(20)
        /// The last chunk waits for this gate.
        var finalChunkGate: Gate?
        /// The `Content-Length` header: the body size by default, `nil` to omit it.
        var contentLength: Int?? = .none
        /// More response headers, such as `Set-Cookie`.
        var headers: [String: String] = [:]
        /// Answers with a 302 to this URL instead of the body.
        var redirectTo: String?
        /// Sends the response again after the first chunk, like a multipart body.
        var repeatsResponse = false
        var requests: [URLRequest] = []
        var stopped = 0
        var chunksSent = 0
    }

    private struct Waiter {
        var host: String
        var condition: @Sendable (Route) -> Bool
        var continuation: CheckedContinuation<Void, Never>
    }

    private static let state = Mutex<(routes: [String: Route], waiters: [Waiter])>(([:], []))
    /// Whether the load finished or stopped.
    private let isDone = Mutex(false)

    static func register(_ route: Route) -> String {
        let host = "\(UUID().uuidString.lowercased()).images.test"
        state.withLock { $0.routes[host] = route }
        return host
    }

    static func route(_ host: String) -> Route? {
        state.withLock { $0.routes[host] }
    }

    /// Returns once `host`'s route satisfies `condition`.
    static func wait(for host: String, until condition: @escaping @Sendable (Route) -> Bool) async {
        await withCheckedContinuation { continuation in
            let isMet = state.withLock { state in
                guard let route = state.routes[host], !condition(route) else { return true }
                state.waiters.append(Waiter(host: host, condition: condition, continuation: continuation))
                return false
            }
            if isMet { continuation.resume() }
        }
    }

    private static func update(_ host: String, _ change: (inout Route) -> Void) {
        let ready = state.withLock { state -> [CheckedContinuation<Void, Never>] in
            guard var route = state.routes[host] else { return [] }
            change(&route)
            state.routes[host] = route
            let (met, waiting) = state.waiters.reduce(into: ([Waiter](), [Waiter]())) { result, waiter in
                if waiter.host == host, waiter.condition(route) {
                    result.0.append(waiter)
                } else {
                    result.1.append(waiter)
                }
            }
            state.waiters = waiting
            return met.map(\.continuation)
        }
        for continuation in ready { continuation.resume() }
    }

    static func configuration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ImageStubProtocol.self]
        return configuration
    }

    override class func canInit(with request: URLRequest) -> Bool {
        guard let host = request.url?.host() else { return false }
        return state.withLock { $0.routes[host] != nil }
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let host = url.host(), let route = Self.route(host) else { return }
        Self.update(host) { $0.requests.append(request) }
        let box = UncheckedProtocol(value: self)
        Task {
            await route.gate?.wait()
            if let delay = route.delay { try? await Task.sleep(for: delay) }
            await box.value.deliver(route, url: url, host: host)
        }
    }

    /// Counts loads stopped before they finished, i.e. cancelled.
    override func stopLoading() {
        if !markDone(), let host = request.url?.host() {
            Self.update(host) { $0.stopped += 1 }
        }
    }

    /// Marks the load done and returns whether it already was.
    private func markDone() -> Bool {
        isDone.withLock { done in
            defer { done = true }
            return done
        }
    }

    private func deliver(_ route: Route, url: URL, host: String) async {
        if let location = route.redirectTo, let next = URL(string: location) {
            var headers = route.headers
            headers["Location"] = location
            guard !markDone(),
                let response = HTTPURLResponse(
                    url: url, statusCode: 302, httpVersion: "HTTP/1.1", headerFields: headers)
            else { return }
            // Like URLSession, propose the original request (and its headers) at the new URL.
            var proposed = request
            proposed.url = next
            client?.urlProtocol(self, wasRedirectedTo: proposed, redirectResponse: response)
            return
        }
        let length = route.contentLength ?? route.body.count
        var headers = route.headers.merging(["Content-Type": route.mimeType]) { $1 }
        headers["Content-Length"] = length.map(String.init)
        guard !isDone.withLock({ $0 }),
            let response = HTTPURLResponse(
                url: url, statusCode: route.status, httpVersion: "HTTP/1.1", headerFields: headers)
        else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        let chunkSize = route.chunkSize ?? max(route.body.count, 1)
        var offset = 0
        while offset < route.body.count {
            if offset > 0 { try? await Task.sleep(for: route.chunkDelay) }
            if offset + chunkSize >= route.body.count { await route.finalChunkGate?.wait() }
            guard !isDone.withLock({ $0 }) else { return }
            let end = min(offset + chunkSize, route.body.count)
            client?.urlProtocol(self, didLoad: route.body.subdata(in: offset..<end))
            Self.update(host) { $0.chunksSent += 1 }
            if route.repeatsResponse, offset == 0 {
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            }
            offset = end
        }
        guard !markDone() else { return }
        client?.urlProtocolDidFinishLoading(self)
    }
}

// URLProtocol isn't Sendable, but the loading system lets a protocol call its client from any
// thread; the delayed delivery is its only use after `startLoading` returns.
private struct UncheckedProtocol: @unchecked Sendable {
    let value: ImageStubProtocol
}

/// Builds server cover requests for a stub host, with optional custom headers.
struct TestRequestBuilder: ImageRequestBuilding {
    var host: String
    var headers: [String: String] = [:]

    func imageRequest(for source: ImageSource) -> URLRequest? {
        guard case .server(_, let entityID, let updatedAt, let width, let format) = source,
            let url = URL(
                string: "https://\(host)/api/items/\(entityID)/cover?width=\(width.rawValue)"
                    + "&format=\(format.rawValue)&ts=\(updatedAt ?? 0)")
        else { return nil }
        var request = URLRequest(url: url)
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        return request
    }
}

/// A downloaded-cover lookup with fixed answers per entity ID, and an optional answer for every
/// other entity.
struct FakeDownloadedCovers: DownloadedCoverLookup {
    var covers: [String: DownloadedCover]
    var other: DownloadedCover?

    func downloadedCover(for key: ImageKey) async -> DownloadedCover? {
        covers[key.entityID] ?? other
    }
}

enum TestImages {
    /// An opaque two-colour image encoded as `type`, with 8-bit, 16-bit or float samples.
    static func data(
        width: Int, height: Int, type: UTType = .png, bitsPerComponent: Int = 8, isFloat: Bool = false
    ) -> Data {
        let alpha = CGImageAlphaInfo.noneSkipLast.rawValue
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: bitsPerComponent, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: isFloat
                ? alpha | CGBitmapInfo.floatComponents.rawValue | CGBitmapInfo.byteOrder32Little.rawValue : alpha)!
        context.setFillColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(red: 0.9, green: 0.7, blue: 0.1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width / 2, height: height / 2))
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        CGImageDestinationFinalize(destination)
        return data as Data
    }

    static func file(
        width: Int, height: Int, type: UTType = .png, bitsPerComponent: Int = 8, isFloat: Bool = false,
        in directory: URL
    ) throws -> URL {
        let url = directory.appending(path: "\(UUID().uuidString).\(type.preferredFilenameExtension ?? "img")")
        try data(width: width, height: height, type: type, bitsPerComponent: bitsPerComponent, isFloat: isFloat)
            .write(to: url)
        return url
    }

    /// A 1 × 1 lossless WebP; ImageIO decodes WebP but can't encode it.
    static let webP = Data(base64Encoded: "UklGRhoAAABXRUJQVlA4TA0AAAAvAAAAEAcQERGIiP4HAA==")!
}

/// A temporary cache folder and one server, with helpers to build pipelines over them.
struct PipelineHarness {
    let directory: TemporaryDirectory
    let serverID = UUID()

    static let gridBox = PixelBox(width: 512, height: 832)

    init() throws {
        directory = try TemporaryDirectory()
    }

    /// - Parameter local: A downloaded cover file returned for every entity not in `downloaded`.
    func make(
        host: String? = nil, headers: [String: String] = [:], limits: ImageCacheLimits = .iPhone,
        downloaded: [String: DownloadedCover] = [:], local: URL? = nil,
        configuration: URLSessionConfiguration = ImageStubProtocol.configuration(),
        isOnline: @escaping @Sendable () -> Bool = { true }
    ) async -> (ImagePipeline, CoverFileStore) {
        let store = CoverFileStore(directory: directory.url.appending(path: "Images"), limit: limits.diskBytes)
        let covers = FakeDownloadedCovers(
            covers: downloaded, other: local.map { DownloadedCover(fileURL: $0, updatedAt: 1) })
        let pipeline = ImagePipeline(
            limits: limits, fileStore: store, downloadedCovers: covers, sessionConfiguration: configuration,
            isOnline: isOnline)
        if let host {
            await pipeline.setRequestBuilder(TestRequestBuilder(host: host, headers: headers), for: serverID)
        }
        return (pipeline, store)
    }

    func key(_ id: String = "item-1", updatedAt: Int? = 1, url: URL? = nil) -> ImageKey {
        ImageKey(serverID: serverID, kind: .itemCover, entityID: id, updatedAt: updatedAt, externalURL: url)
    }

    static func pngRoute(width: Int = 600, height: Int = 960, gate: Gate? = nil, delay: Duration? = nil) -> String {
        ImageStubProtocol.register(
            .init(body: TestImages.data(width: width, height: height), mimeType: "image/png", gate: gate, delay: delay))
    }
}

extension ImagePipeline {
    /// Waits up to ten seconds until `key`'s fetch and its decode into `box` have these many
    /// waiters; `false` if they never do.
    func waitForWaiters(_ key: ImageKey, box: PixelBox, fetch: Int, decode: Int) async -> Bool {
        for _ in 0..<10_000 {
            let counts = waiterCounts(for: key, box: box)
            if counts.fetch == fetch, counts.decode == decode { return true }
            try? await Task.sleep(for: .milliseconds(1))
        }
        return false
    }
}
