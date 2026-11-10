import CoreGraphics
import Foundation
import ImageIO
import Synchronization
import UniformTypeIdentifiers

@testable import ABSCore

/// Answers image requests for registered hosts and records them. Kept separate from
/// ABSAPITests' stub so ABSCore tests don't depend on ABSAPI.
final class ImageStubProtocol: URLProtocol {
    struct Route {
        var status = 200
        var body = Data()
        var mimeType = "image/png"
        var delay: Duration?
        var requests: [URLRequest] = []
        var stopped = 0
    }

    private static let routes = Mutex<[String: Route]>([:])
    /// Whether the response was delivered or the load stopped.
    private let isDone = Mutex(false)

    static func register(_ route: Route) -> String {
        let host = "\(UUID().uuidString.lowercased()).images.test"
        routes.withLock { $0[host] = route }
        return host
    }

    static func route(_ host: String) -> Route? {
        routes.withLock { $0[host] }
    }

    static func configuration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ImageStubProtocol.self]
        return configuration
    }

    override class func canInit(with request: URLRequest) -> Bool {
        guard let host = request.url?.host() else { return false }
        return routes.withLock { $0[host] != nil }
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let host = url.host() else { return }
        let request = request
        let route = Self.routes.withLock { routes in
            routes[host]?.requests.append(request)
            return routes[host]
        }
        guard let route else { return }
        let box = UncheckedProtocol(value: self)
        DispatchQueue.global().asyncAfter(deadline: .now() + (route.delay.map(Self.seconds) ?? 0)) {
            box.value.deliver(route, url: url)
        }
    }

    /// Counts loads stopped before their response, i.e. cancelled.
    override func stopLoading() {
        let wasDone = isDone.withLock { done in
            defer { done = true }
            return done
        }
        if !wasDone, let host = request.url?.host() {
            Self.routes.withLock { $0[host]?.stopped += 1 }
        }
    }

    private func deliver(_ route: Route, url: URL) {
        let wasDone = isDone.withLock { done in
            defer { done = true }
            return done
        }
        guard !wasDone,
            let response = HTTPURLResponse(
                url: url, statusCode: route.status, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": route.mimeType, "Content-Length": String(route.body.count)])
        else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: route.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    private static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
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

/// A downloaded-cover lookup with fixed answers.
struct FakeDownloadedCovers: DownloadedCoverLookup {
    var covers: [String: DownloadedCover]

    func downloadedCover(for key: ImageKey) async -> DownloadedCover? {
        covers[key.entityID]
    }
}

enum TestImages {
    /// An opaque two-colour image encoded as `type`.
    static func data(width: Int, height: Int, type: UTType = .png) -> Data {
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
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

    static func file(width: Int, height: Int, type: UTType = .png, in directory: URL) throws -> URL {
        let url = directory.appending(path: "\(UUID().uuidString).\(type.preferredFilenameExtension ?? "img")")
        try data(width: width, height: height, type: type).write(to: url)
        return url
    }
}

/// A fresh temporary directory, deleted when the value is released.
final class TemporaryDirectory: Sendable {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory.appending(path: "ImagePipelineTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }
}
