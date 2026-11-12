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
/// `Cookie` (reserved names are dropped even if given), no cookie jar, credential store or cache,
/// and `Accept-Encoding: identity`. Redirects follow ``RedirectPolicy``: a hop that leaves the
/// track's origin is stripped of the custom headers (it keeps only `Range`), and `https` to `http`
/// is refused.
///
/// A `200` answer to a `Range` request (a proxy that drops `Range`) reports no byte-range access,
/// whatever `Accept-Ranges` says, and fails a load that starts past byte 0 with
/// ``HeaderStreamingError/rangeNotHonored`` rather than downloading and discarding the bytes
/// before it. `text/*` answers (a login page) fail with ``HeaderStreamingError/unexpectedContentType(_:)``.
///
/// Not for HLS: the resource loader can't carry segment requests, so the resolver refuses
/// transcode sessions on these connections.
///
/// One transport serves one source. Its session is created by the first ``makeAsset(url:options:mimeType:networkAccess:)``
/// with that call's network access, so the session itself refuses cellular, expensive or
/// constrained paths the source may not use; every request and redirect hop carries the flags too.
/// Keep the transport alive for as long as its assets play (the engine holds it through
/// ``AudioEngineSource/headerTransport``). Releasing it cancels its loads; later loads fail with
/// `URLError(.cancelled)`.
public final class HeaderStreamingTransport: NSObject, Sendable {
    let loader: HeaderResourceLoader

    /// - Parameters:
    ///   - customHeaders: The connection's custom headers (``APIClientConfiguration/customHeaders``).
    ///   - configuration: The base session configuration; cookies, credentials, extra headers and
    ///     caching are turned off on a copy. Tests pass one with a stub `URLProtocol`.
    public init(customHeaders: [String: String], configuration: URLSessionConfiguration = .ephemeral) {
        let headers = customHeaders.filter { !APIClientConfiguration.reservedHeaderNames.contains($0.key.lowercased()) }
        let configuration = configuration.copy() as? URLSessionConfiguration ?? .ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpAdditionalHeaders = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        loader = HeaderResourceLoader(headers: headers, configuration: configuration)
    }

    deinit {
        // On the loader's queue, so no load can start between invalidation and the session going.
        let loader = loader
        loader.queue.async { loader.invalidate() }
    }

    /// An asset for the track at `url` (`http` or `https`) whose loads go through this transport.
    /// `mimeType` is reported as the content type (the public track route has no extension), and
    /// `networkAccess` is applied to every request (and to the session, on the first call).
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

    /// Where a URL that can't be rewritten goes: still the loader's scheme, so it fails there.
    static let unloadableURL = URL(string: "abs-invalid://unloadable")!

    /// `https://…` → `abs-https://…`. Any other scheme gets the prefix too, and a URL that can't
    /// be rewritten becomes ``unloadableURL``, so its loads fail in the loader rather than
    /// bypassing it.
    static func loaderURL(for url: URL) -> URL {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.scheme = schemePrefix + (url.scheme ?? "")
        return components?.url ?? unloadableURL
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
    /// A `206` whose `Content-Range` is missing or unparseable, starts after the requested offset
    /// or ends before the requested end.
    case invalidRange
    /// A `200` (the whole resource) answered a request that starts past byte 0: something on the
    /// way drops `Range`, and skipping to the offset would download everything before it.
    case rangeNotHonored
    /// A `text/*` answer with this MIME type, such as a proxy's login page, instead of audio.
    case unexpectedContentType(String)

    public static var errorDomain: String { "ABSPlayback.HeaderStreaming" }

    /// The HTTP status for ``httpStatus(_:)``; negative for the others.
    public var errorCode: Int {
        switch self {
        case .httpStatus(let status): status
        case .invalidRange: -1
        case .rangeNotHonored: -2
        case .unexpectedContentType: -3
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
        let track: Track
        /// Bytes still wanted; `nil` means to the end.
        var remaining: Int64?
        /// Leading bytes to drop, when a `206` starts before the requested offset.
        var toSkip: Int64 = 0
        var isStripped = false

        init(request: any ResourceLoadingRequest, original: URLRequest, range: RequestedRange?, track: Track) {
            self.request = request
            self.original = original
            self.track = track
            offset = range?.offset ?? 0
            remaining = range == nil ? 0 : range?.length
        }
    }

    let queue = DispatchQueue(label: "org.davidjensenius.Audiobookshelf.HeaderStreaming")
    private let headers: [String: String]
    private let configuration: URLSessionConfiguration
    /// Created by the first ``register(_:track:)``; `nil` again once ``invalidate()`` ran.
    private var session: URLSession?
    private var isInvalidated = false
    private var tracks: [URL: Track] = [:]
    private var loads: [Int: Load] = [:]
    private var tasks: [ObjectIdentifier: URLSessionTask] = [:]

    init(headers: [String: String], configuration: URLSessionConfiguration) {
        self.headers = headers
        self.configuration = configuration
    }

    /// The live session's configuration, for tests.
    var sessionConfiguration: URLSessionConfiguration? { queue.sync { session?.configuration } }

    /// Registers a track's loader URL. The first one creates the session with its network access.
    func register(_ loaderURL: URL, track: Track) {
        queue.sync {
            tracks[loaderURL] = track
            guard session == nil, !isInvalidated else { return }
            if let access = track.networkAccess { configuration.apply(access) }
            let delegateQueue = OperationQueue()
            delegateQueue.maxConcurrentOperationCount = 1
            delegateQueue.underlyingQueue = queue
            session = URLSession(configuration: configuration, delegate: self, delegateQueue: delegateQueue)
        }
    }

    /// Cancels every load and drops the session, which releases its strong reference to this
    /// delegate once the cancelled tasks complete. Later loads fail with `URLError(.cancelled)`.
    /// Must run on ``queue``.
    func invalidate() {
        dispatchPrecondition(condition: .onQueue(queue))
        isInvalidated = true
        session?.invalidateAndCancel()
        session = nil
    }

    /// The request for `range` of `url`: the custom headers, the network access flags, `Range`
    /// (two bytes when only content information is wanted) and `Accept-Encoding: identity`, so
    /// byte offsets are the file's; no cookies or cache.
    static func urlRequest(
        url: URL, range: RequestedRange?, headers: [String: String], networkAccess: NetworkAccess?
    ) -> URLRequest {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.httpShouldHandleCookies = false
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        request.setValue((range ?? RequestedRange(offset: 0, length: 2)).header, forHTTPHeaderField: "Range")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        if let networkAccess { request.apply(networkAccess) }
        return request
    }

    /// Content information from a `200` or `206`, and the body's first and last byte offsets
    /// (the last when known). `nil` for a `206` without a usable `Content-Range`.
    ///
    /// Every request carries `Range`, so a `200` means it was not honoured: no byte-range access,
    /// whatever `Accept-Ranges` says (Express sends it even when a proxy drops `Range`).
    static func contentInformation(
        from response: HTTPURLResponse, mimeType: String?
    ) -> (information: ContentInformation, first: Int64, last: Int64?)? {
        let type = [mimeType, response.mimeType].lazy.compactMap { $0.flatMap { UTType(mimeType: $0)?.identifier } }
            .first
        guard response.statusCode == 206 else {
            let length = response.expectedContentLength >= 0 ? response.expectedContentLength : nil
            let information = ContentInformation(
                contentType: type, contentLength: length, isByteRangeAccessSupported: false)
            return (information, 0, length.map { $0 - 1 })
        }
        // `bytes <first>-<last>/<total or *>`
        guard let header = response.value(forHTTPHeaderField: "Content-Range"),
            let match = header.firstMatch(of: /^\s*bytes\s+(\d+)-(\d+)\/(\d+|\*)\s*$/),
            let first = Int64(match.1), let last = Int64(match.2)
        else { return nil }
        let information = ContentInformation(
            contentType: type, contentLength: Int64(match.3), isByteRangeAccessSupported: true)
        return (information, first, last)
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
        // An unregistered URL fails closed: there are no network access flags to apply.
        guard let url = HeaderStreamingTransport.httpURL(from: loaderURL), let track = tracks[loaderURL] else {
            return request.finish(URLError(.unsupportedURL))
        }
        guard let session else { return request.finish(URLError(.cancelled)) }
        let range = request.requestedRange
        let urlRequest = Self.urlRequest(url: url, range: range, headers: headers, networkAccess: track.networkAccess)
        let task = session.dataTask(with: urlRequest)
        loads[task.taskIdentifier] = Load(request: request, original: urlRequest, range: range, track: track)
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
        func fail(_ error: any Error) {
            end(dataTask, error: error)
            completionHandler(.cancel)
        }
        guard let http = response as? HTTPURLResponse else { return fail(URLError(.badServerResponse)) }
        guard http.statusCode == 200 || http.statusCode == 206 else {
            return fail(HeaderStreamingError.httpStatus(http.statusCode))
        }
        if let type = http.mimeType?.lowercased(), type.hasPrefix("text/") {
            return fail(HeaderStreamingError.unexpectedContentType(type))
        }
        guard let (information, first, last) = Self.contentInformation(from: http, mimeType: load.track.mimeType),
            first <= load.offset
        else { return fail(HeaderStreamingError.invalidRange) }
        // A `200` starts at byte 0; reading on to the offset would download everything before it.
        if http.statusCode == 200, load.offset > 0 { return fail(HeaderStreamingError.rangeNotHonored) }
        // A short answer would leave the request unfulfilled.
        if let wanted = load.remaining, wanted > 0, let last, last < load.offset + wanted - 1 {
            return fail(HeaderStreamingError.invalidRange)
        }
        load.toSkip = load.offset - first
        if load.request.wantsContentInformation { load.request.fill(information) }
        if load.remaining == 0 {
            end(dataTask, error: nil)
            return completionHandler(.cancel)
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let load = loads[dataTask.taskIdentifier] else { return }
        var chunk = data
        if load.toSkip > 0 {
            let skipped = min(load.toSkip, Int64(chunk.count))
            chunk = chunk.dropFirst(Int(skipped))
            load.toSkip -= skipped
        }
        if let remaining = load.remaining, chunk.count > remaining { chunk = chunk.prefix(Int(remaining)) }
        // A chunk that needs no skip or trim is passed on as it came, without a copy.
        if !chunk.isEmpty { load.request.respond(with: chunk) }
        if let remaining = load.remaining {
            load.remaining = remaining - Int64(chunk.count)
            if load.remaining == 0 { end(dataTask, error: nil) }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        // A body that ends before the requested bytes arrived must not count as success.
        if error == nil, let remaining = loads[task.taskIdentifier]?.remaining, remaining > 0 {
            return end(task, error: URLError(.networkConnectionLost))
        }
        end(task, error: error)
    }

    /// Applies ``RedirectPolicy``: a cross-origin hop loses the custom headers but keeps `Range`
    /// and `Accept-Encoding`; a refused hop (such as `https` to `http`) fails the load with the
    /// redirect's status. Every hop carries the track's network access flags.
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
            for name in ["Range", "Accept-Encoding"] {
                next.setValue(load.original.value(forHTTPHeaderField: name), forHTTPHeaderField: name)
            }
        }
        if let access = load.track.networkAccess { next.apply(access) }
        next.httpShouldHandleCookies = false
        next.cachePolicy = .reloadIgnoringLocalCacheData
        completionHandler(next)
    }
}
