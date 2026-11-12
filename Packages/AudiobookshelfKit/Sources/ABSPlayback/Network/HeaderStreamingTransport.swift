import ABSAPI
import ABSCore
import AVFoundation
import Foundation
import UniformTypeIdentifiers

/// Streams direct-play tracks for a connection with custom headers (ADR 0007 §6, Option 4).
///
/// ``makeAsset(url:options:mimeType:networkAccess:)`` rewrites the track's `http(s)` URL to the
/// custom `abs-http(s)` scheme, so AVFoundation hands every load to an
/// `AVAssetResourceLoaderDelegate`. The delegate re-issues it through `URLSession` as a `Range`
/// request carrying the connection's custom headers and nothing else: never `Authorization` or
/// `Cookie` (reserved names are dropped even if given), no cookie jar and no cache. Redirects
/// follow ``RedirectPolicy``: a hop that leaves the track's origin is stripped of the custom
/// headers (it keeps only `Range`), and `https` to `http` is refused.
///
/// Not for HLS: the resource loader can't carry segment requests, so the resolver refuses
/// transcode sessions on these connections.
///
/// The transport owns its loader and session; keep it alive for as long as its assets play (the
/// engine holds it through ``AudioEngineSource/headerTransport``). Releasing it cancels its loads.
public final class HeaderStreamingTransport: NSObject, Sendable {
    let loader: HeaderResourceLoader
    private let session: URLSession

    /// - Parameters:
    ///   - customHeaders: The connection's custom headers (``APIClientConfiguration/customHeaders``).
    ///   - configuration: The base session configuration; cookies and caching are turned off on
    ///     a copy. Tests pass one with a stub `URLProtocol`.
    public init(customHeaders: [String: String], configuration: URLSessionConfiguration = .ephemeral) {
        let headers = customHeaders.filter { !APIClientConfiguration.reservedHeaderNames.contains($0.key.lowercased()) }
        let loader = HeaderResourceLoader(headers: headers)
        let configuration = configuration.copy() as? URLSessionConfiguration ?? .ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let delegateQueue = OperationQueue()
        delegateQueue.maxConcurrentOperationCount = 1
        delegateQueue.underlyingQueue = loader.queue
        session = URLSession(configuration: configuration, delegate: loader, delegateQueue: delegateQueue)
        loader.session = session
        self.loader = loader
    }

    deinit {
        // Breaks the session's strong reference to its delegate and cancels running loads.
        session.invalidateAndCancel()
    }

    /// An asset for the track at `url` (`http` or `https`) whose loads go through this transport.
    /// `mimeType` is reported as the content type (the public track route has no extension), and
    /// `networkAccess` is applied to every request.
    public func makeAsset(
        url: URL, options: [String: Any] = [:], mimeType: String?, networkAccess: NetworkAccess?
    ) -> AVURLAsset {
        let loaderURL = Self.loaderURL(for: url)
        loader.register(loaderURL, track: .init(mimeType: mimeType, networkAccess: networkAccess))
        let asset = AVURLAsset(url: loaderURL, options: options)
        asset.resourceLoader.setDelegate(loader, queue: loader.queue)
        return asset
    }

    static let schemePrefix = "abs-"

    /// `https://…` → `abs-https://…`. Any other scheme gets the prefix too, so its loads fail in
    /// the loader rather than bypassing it.
    static func loaderURL(for url: URL) -> URL {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.scheme = schemePrefix + (url.scheme ?? "")
        return components?.url ?? url
    }

    /// `abs-https://…` → `https://…`; `nil` for anything else.
    static func httpURL(from loaderURL: URL) -> URL? {
        guard let scheme = loaderURL.scheme?.lowercased(), scheme.hasPrefix(schemePrefix) else { return nil }
        let original = String(scheme.dropFirst(schemePrefix.count))
        guard original == "http" || original == "https" else { return nil }
        var components = URLComponents(url: loaderURL, resolvingAgainstBaseURL: false)
        components?.scheme = original
        return components?.url
    }
}

/// A resource-loader request failed at the HTTP level.
public enum HeaderStreamingError: Error, Sendable, Hashable, CustomNSError {
    /// The server, or a proxy in front of it, answered with this non-2xx status (including a
    /// refused redirect's 3xx).
    case httpStatus(Int)
    /// A `206` whose `Content-Range` is missing, unparseable or starts after the requested offset.
    case invalidRange

    public static var errorDomain: String { "ABSPlayback.HeaderStreaming" }

    public var errorCode: Int {
        switch self {
        case .httpStatus(let status): status
        case .invalidRange: -1
        }
    }
}

/// The bytes a loading request wants: from `offset`, `length` bytes or to the end when `nil`.
struct RequestedRange: Sendable, Hashable {
    var offset: Int64
    var length: Int64?

    var header: String {
        guard let length else { return "bytes=\(offset)-" }
        return "bytes=\(offset)-\(offset + max(length, 1) - 1)"
    }
}

/// What a response says about the whole resource.
struct ContentInformation: Sendable, Hashable {
    /// A UTI, from the track's MIME type, else the response's.
    var contentType: String?
    var contentLength: Int64?
    var isByteRangeAccessSupported: Bool
}

/// The part of `AVAssetResourceLoadingRequest` the loader uses, so tests can drive it.
protocol ResourceLoadingRequest: AnyObject {
    /// The data request's range, or `nil` when only content information is requested.
    var requestedRange: RequestedRange? { get }
    var wantsContentInformation: Bool { get }
    func fill(_ information: ContentInformation)
    func respond(with data: Data)
    func finish(_ error: (any Error)?)
}

extension AVAssetResourceLoadingRequest: ResourceLoadingRequest {
    var requestedRange: RequestedRange? {
        guard let dataRequest else { return nil }
        return RequestedRange(
            offset: dataRequest.requestedOffset,
            length: dataRequest.requestsAllDataToEndOfResource ? nil : Int64(dataRequest.requestedLength))
    }

    var wantsContentInformation: Bool { contentInformationRequest != nil }

    func fill(_ information: ContentInformation) {
        guard let request = contentInformationRequest else { return }
        request.contentType = information.contentType
        if let length = information.contentLength { request.contentLength = length }
        request.isByteRangeAccessSupported = information.isByteRangeAccessSupported
    }

    func respond(with data: Data) {
        dataRequest?.respond(with: data)
    }

    func finish(_ error: (any Error)?) {
        guard !isFinished, !isCancelled else { return }
        if let error { finishLoading(with: error) } else { finishLoading() }
    }
}

/// The resource-loader and `URLSession` delegate behind ``HeaderStreamingTransport``. Every
/// callback, from AVFoundation and from the session, runs on ``queue``, which confines its state.
final class HeaderResourceLoader: NSObject, AVAssetResourceLoaderDelegate, URLSessionDataDelegate,
    @unchecked Sendable
{
    struct Track {
        var mimeType: String?
        var networkAccess: NetworkAccess?
    }

    /// One `URLSession` task feeding one loading request.
    private final class Load {
        let request: any ResourceLoadingRequest
        let original: URLRequest
        let offset: Int64
        let mimeType: String?
        /// Bytes still wanted; `nil` means to the end.
        var remaining: Int64?
        /// Leading bytes to drop, when the server answered from an earlier offset.
        var toSkip: Int64 = 0
        var isStripped = false

        init(request: any ResourceLoadingRequest, original: URLRequest, range: RequestedRange?, mimeType: String?) {
            self.request = request
            self.original = original
            self.mimeType = mimeType
            offset = range?.offset ?? 0
            remaining = range == nil ? 0 : range?.length
        }
    }

    let queue = DispatchQueue(label: "org.davidjensenius.Audiobookshelf.HeaderStreaming")
    private let headers: [String: String]
    /// Set once by the transport before any load; invalidated with it.
    var session: URLSession?
    private var tracks: [URL: Track] = [:]
    private var loads: [Int: Load] = [:]
    private var tasks: [ObjectIdentifier: URLSessionTask] = [:]

    init(headers: [String: String]) {
        self.headers = headers
    }

    func register(_ loaderURL: URL, track: Track) {
        queue.sync { tracks[loaderURL] = track }
    }

    /// The request for `range` of `url`: the custom headers, the network access flags and `Range`
    /// (two bytes when only content information is wanted), with no cookies or cache.
    static func urlRequest(
        url: URL, range: RequestedRange?, headers: [String: String], networkAccess: NetworkAccess?
    ) -> URLRequest {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.httpShouldHandleCookies = false
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        request.setValue((range ?? RequestedRange(offset: 0, length: 2)).header, forHTTPHeaderField: "Range")
        if let networkAccess { request.apply(networkAccess) }
        return request
    }

    /// Content information from a `200` or `206`, and where its body starts. `nil` for a `206`
    /// without a usable `Content-Range`.
    static func contentInformation(
        from response: HTTPURLResponse, mimeType: String?
    ) -> (information: ContentInformation, bodyOffset: Int64)? {
        let type = [mimeType, response.mimeType].lazy.compactMap { $0.flatMap { UTType(mimeType: $0)?.identifier } }
            .first
        guard response.statusCode == 206 else {
            let length = response.expectedContentLength >= 0 ? response.expectedContentLength : nil
            let ranges = response.value(forHTTPHeaderField: "Accept-Ranges")?.lowercased().contains("bytes") == true
            return (ContentInformation(contentType: type, contentLength: length, isByteRangeAccessSupported: ranges), 0)
        }
        // `bytes <start>-<end>/<total or *>`
        guard let header = response.value(forHTTPHeaderField: "Content-Range"),
            let match = header.firstMatch(of: /^\s*bytes\s+(\d+)-(\d+)\/(\d+|\*)\s*$/),
            let start = Int64(match.1)
        else { return nil }
        let information = ContentInformation(
            contentType: type, contentLength: Int64(match.3), isByteRangeAccessSupported: true)
        return (information, start)
    }

    // MARK: AVAssetResourceLoaderDelegate

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest
    ) -> Bool {
        guard let url = loadingRequest.request.url else { return false }
        start(loadingRequest, loaderURL: url)
        return true
    }

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader, didCancel loadingRequest: AVAssetResourceLoadingRequest
    ) {
        cancel(loadingRequest)
    }

    /// Starts `request` for `loaderURL`. Must run on ``queue``.
    func start(_ request: any ResourceLoadingRequest, loaderURL: URL) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard let url = HeaderStreamingTransport.httpURL(from: loaderURL), let session else {
            request.finish(URLError(.unsupportedURL))
            return
        }
        let range = request.requestedRange
        let track = tracks[loaderURL]
        let urlRequest = Self.urlRequest(url: url, range: range, headers: headers, networkAccess: track?.networkAccess)
        let task = session.dataTask(with: urlRequest)
        loads[task.taskIdentifier] = Load(
            request: request, original: urlRequest, range: range, mimeType: track?.mimeType)
        tasks[ObjectIdentifier(request)] = task
        task.resume()
    }

    /// Cancels the task feeding `request`. Must run on ``queue``.
    func cancel(_ request: any ResourceLoadingRequest) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard let task = tasks.removeValue(forKey: ObjectIdentifier(request)) else { return }
        loads[task.taskIdentifier] = nil
        task.cancel()
    }

    private func end(_ task: URLSessionTask, error: (any Error)?) {
        guard let load = loads.removeValue(forKey: task.taskIdentifier) else { return }
        tasks[ObjectIdentifier(load.request)] = nil
        load.request.finish(error)
        task.cancel()
    }

    // MARK: URLSessionDataDelegate

    func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
    ) {
        guard let load = loads[dataTask.taskIdentifier] else { return completionHandler(.cancel) }
        guard let http = response as? HTTPURLResponse else {
            end(dataTask, error: URLError(.badServerResponse))
            return completionHandler(.cancel)
        }
        guard http.statusCode == 200 || http.statusCode == 206 else {
            end(dataTask, error: HeaderStreamingError.httpStatus(http.statusCode))
            return completionHandler(.cancel)
        }
        guard let (information, bodyOffset) = Self.contentInformation(from: http, mimeType: load.mimeType),
            bodyOffset <= load.offset
        else {
            end(dataTask, error: HeaderStreamingError.invalidRange)
            return completionHandler(.cancel)
        }
        load.toSkip = load.offset - bodyOffset
        if load.request.wantsContentInformation { load.request.fill(information) }
        if load.remaining == 0 {
            end(dataTask, error: nil)
            return completionHandler(.cancel)
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let load = loads[dataTask.taskIdentifier] else { return }
        var chunk = data[...]
        if load.toSkip > 0 {
            let skipped = Int(min(load.toSkip, Int64(chunk.count)))
            chunk = chunk.dropFirst(skipped)
            load.toSkip -= Int64(skipped)
        }
        if let remaining = load.remaining, chunk.count > remaining { chunk = chunk.prefix(Int(remaining)) }
        if !chunk.isEmpty { load.request.respond(with: Data(chunk)) }
        if let remaining = load.remaining {
            load.remaining = remaining - Int64(chunk.count)
            if load.remaining == 0 { end(dataTask, error: nil) }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        end(task, error: error)
    }

    /// Applies ``RedirectPolicy``: a cross-origin hop loses the custom headers but keeps `Range`;
    /// a refused hop (such as `https` to `http`) fails the load with the redirect's status.
    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        guard let load = loads[task.taskIdentifier] else { return completionHandler(nil) }
        guard
            let hop = RedirectPolicy.hop(
                following: response, to: request, original: load.original, wasStripped: load.isStripped)
        else {
            completionHandler(nil)
            return end(task, error: HeaderStreamingError.httpStatus(response.statusCode))
        }
        var next = hop.request
        if hop.isStripped {
            load.isStripped = true
            next.setValue(load.original.value(forHTTPHeaderField: "Range"), forHTTPHeaderField: "Range")
        }
        next.httpShouldHandleCookies = false
        next.cachePolicy = .reloadIgnoringLocalCacheData
        completionHandler(next)
    }
}
