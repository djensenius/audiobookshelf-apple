import ABSCore
import ABSTestSupport
import AVFoundation
import Foundation
import Testing

@testable import ABSAPI
@testable import ABSPlayback

/// The custom-header resource loader (ADR 0007 §6) against a stub `URLProtocol` server.
@Suite(.timeLimit(.minutes(1)))
struct HeaderStreamingTransportTests {
    static let proxyHeaders = ["CF-Access-Client-Id": "client", "CF-Access-Client-Secret": "secret"]
    static let body = Data((0..<1000).map { UInt8($0 % 251) })
    /// `.never` with expensive paths counted as cellular, so every flag is off on every platform
    /// (iOS keeps expensive access for a personal hotspot by default).
    static let deniesMetered = NetworkAccess(policy: .never, treatsExpensiveAsCellular: true)

    private func transport(_ headers: [String: String] = proxyHeaders) -> HeaderStreamingTransport {
        HeaderStreamingTransport(customHeaders: headers, configuration: StreamStubProtocol.configuration())
    }

    /// Runs one loading request for `url` through `transport`'s loader and waits for it to finish,
    /// checking that it was finished exactly once.
    private func load(
        _ url: String, range: RequestedRange?, wantsContentInformation: Bool = true,
        through transport: HeaderStreamingTransport, mimeType: String? = "audio/mpeg",
        networkAccess: NetworkAccess? = nil, registers: Bool = true
    ) async throws -> RecordingLoadingRequest {
        let url = try #require(URL(string: url))
        let request = RecordingLoadingRequest(range: range, wantsContentInformation: wantsContentInformation)
        let loaderURL = HeaderStreamingTransport.loaderURL(for: url)
        let loader = transport.loader
        if registers { loader.register(loaderURL, track: .init(mimeType: mimeType, networkAccess: networkAccess)) }
        loader.queue.async { loader.start(request, loaderURL: loaderURL) }
        await request.finished()
        loader.queue.sync {}
        #expect(request.finishCount == 1)
        return request
    }

    /// Waits up to two seconds for `condition` (a ``WaitBudget``, so a stall of the process doesn't
    /// spend it).
    private func eventually(_ condition: () -> Bool) async throws {
        var budget = WaitBudget(.seconds(2))
        while !condition(), budget.hasTimeLeft() { try await Task.sleep(for: .milliseconds(10)) }
    }

    // MARK: - URLs, ranges and content information

    @Test func loaderURLsRoundTripOnlyForHTTP() throws {
        let url = try #require(URL(string: "https://abs.example:8443/abs/public/session/s/track/1?x=1"))
        let loaderURL = HeaderStreamingTransport.loaderURL(for: url)
        #expect(loaderURL.absoluteString == "abs-https://abs.example:8443/abs/public/session/s/track/1?x=1")
        #expect(HeaderStreamingTransport.httpURL(from: loaderURL) == url)
        let plain = try #require(URL(string: "http://abs.example/a"))
        #expect(HeaderStreamingTransport.httpURL(from: HeaderStreamingTransport.loaderURL(for: plain)) == plain)
        for other in ["https://abs.example/a", "abs-ftp://abs.example/a", "file:///tmp/a"] {
            #expect(HeaderStreamingTransport.httpURL(from: try #require(URL(string: other))) == nil, "\(other)")
        }
    }

    @Test func rangeHeaders() {
        #expect(RequestedRange(offset: 0, length: 2).header == "bytes=0-1")
        #expect(RequestedRange(offset: 100, length: 50).header == "bytes=100-149")
        #expect(RequestedRange(offset: 100, length: nil).header == "bytes=100-")
    }

    @Test func contentInformationFromPartialAndFullResponses() throws {
        let url = try #require(URL(string: "https://abs.example/t"))
        let partial = try #require(
            HTTPURLResponse(
                url: url, statusCode: 206, httpVersion: nil,
                headerFields: ["Content-Range": "bytes 100-199/5000", "Content-Type": "application/octet-stream"]))
        let (info, first, last) = try #require(
            HeaderResourceLoader.contentInformation(from: partial, mimeType: "audio/mpeg"))
        #expect(
            info == ContentInformation(contentType: "public.mp3", contentLength: 5000, isByteRangeAccessSupported: true)
        )
        #expect(first == 100)
        #expect(last == 199)

        // A `200` to a `Range` request: no range access, even though `Accept-Ranges` claims it.
        let full = try #require(
            HTTPURLResponse(
                url: url, statusCode: 200, httpVersion: nil,
                headerFields: ["Content-Length": "5000", "Content-Type": "audio/mp4", "Accept-Ranges": "bytes"]))
        let (fullInfo, fullFirst, fullLast) = try #require(
            HeaderResourceLoader.contentInformation(from: full, mimeType: nil))
        #expect(fullInfo.contentType == UTType(mimeType: "audio/mp4")?.identifier)
        #expect(fullInfo.contentLength == 5000)
        #expect(!fullInfo.isByteRangeAccessSupported)
        #expect(fullFirst == 0)
        #expect(fullLast == 4999)

        let broken = try #require(
            HTTPURLResponse(
                url: url, statusCode: 206, httpVersion: nil, headerFields: ["Content-Range": "bytes */5000"]))
        #expect(HeaderResourceLoader.contentInformation(from: broken, mimeType: nil) == nil)
    }

    // MARK: - Loads through the stub server

    @Test func dataRequestSendsTheCustomHeadersAndRangeButNoCredentials() async throws {
        let host = StreamStubProtocol.register(.init(body: Self.body))
        // Reserved names are dropped even if a caller passes them.
        let headers = Self.proxyHeaders.merging(["Authorization": "Bearer t", "cookie": "connect.sid=1"]) { $1 }
        let request = try await load(
            "https://\(host)/public/session/s/track/1", range: RequestedRange(offset: 100, length: 200),
            through: transport(headers))

        #expect(request.error == nil)
        #expect(request.data == Self.body.subdata(in: 100..<300))
        #expect(
            request.information
                == ContentInformation(contentType: "public.mp3", contentLength: 1000, isByteRangeAccessSupported: true))
        let sent = try #require(StreamStubProtocol.requests(host).first)
        #expect(sent.value(forHTTPHeaderField: "CF-Access-Client-Id") == "client")
        #expect(sent.value(forHTTPHeaderField: "CF-Access-Client-Secret") == "secret")
        #expect(sent.value(forHTTPHeaderField: "Range") == "bytes=100-299")
        #expect(sent.value(forHTTPHeaderField: "Accept-Encoding") == "identity")
        #expect(sent.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(sent.value(forHTTPHeaderField: "Cookie") == nil)
    }

    @Test func contentInformationOnlyAsksForTwoBytes() async throws {
        let host = StreamStubProtocol.register(.init(body: Self.body))
        let request = try await load("https://\(host)/t", range: nil, through: transport())

        #expect(request.error == nil)
        #expect(request.data.isEmpty)
        #expect(request.information?.contentLength == 1000)
        #expect(StreamStubProtocol.requests(host).map { $0.value(forHTTPHeaderField: "Range") } == ["bytes=0-1"])
    }

    @Test func openEndedRangeReadsToTheEnd() async throws {
        let host = StreamStubProtocol.register(.init(body: Self.body))
        let request = try await load(
            "https://\(host)/t", range: RequestedRange(offset: 900, length: nil), wantsContentInformation: false,
            through: transport())

        #expect(request.error == nil)
        #expect(request.data == Self.body.subdata(in: 900..<1000))
        #expect(request.information == nil)
        #expect(StreamStubProtocol.requests(host).first?.value(forHTTPHeaderField: "Range") == "bytes=900-")
    }

    @Test func fullResponseFromTheStartIsTrimmedAcrossChunks() async throws {
        let host = StreamStubProtocol.register(.init(body: Self.body, honorsRange: false, chunkSize: 64))
        let request = try await load(
            "https://\(host)/t", range: RequestedRange(offset: 0, length: 150), through: transport())

        #expect(request.error == nil)
        #expect(request.data == Self.body.subdata(in: 0..<150))
        #expect(request.information?.isByteRangeAccessSupported == false)
    }

    /// A proxy that drops `Range` while the server still sends `Accept-Ranges: bytes`: reading on
    /// to the offset would download everything before it, so the load fails instead.
    @Test func fullResponseToALaterRangeIsNotSkippedThrough() async throws {
        let host = StreamStubProtocol.register(.init(body: Self.body, honorsRange: false))
        let request = try await load(
            "https://\(host)/t", range: RequestedRange(offset: 300, length: 100), through: transport())

        #expect(request.error as? HeaderStreamingError == .rangeNotHonored)
        #expect(request.data.isEmpty)
    }

    @Test(arguments: [(0, true), (50, true), (200, false)])
    func partialResponseFromAnotherOffset(startsAt: Int, isUsable: Bool) async throws {
        let host = StreamStubProtocol.register(.init(body: Self.body, rangeStartsAt: startsAt, chunkSize: 32))
        let request = try await load(
            "https://\(host)/t", range: RequestedRange(offset: 100, length: 50), through: transport())

        if isUsable {
            // An earlier start is skipped up to the requested offset, across chunks.
            #expect(request.error == nil)
            #expect(request.data == Self.body.subdata(in: 100..<150))
        } else {
            #expect(request.error as? HeaderStreamingError == .invalidRange)
            #expect(request.data.isEmpty)
        }
    }

    /// Reversed, overflowing or out-of-bounds ranges, and ranges that miss the requested offset
    /// (even with an unknown total), are refused rather than trusted.
    @Test(
        arguments: [
            (0, "bytes 0-9223372036854775807/*"),
            (0, "bytes 0-9/99999999999999999999"),
            (100, "bytes 100-149/50"),
            (100, "bytes 100-99/1000"),
            (100, "bytes 0-99/*"),
            (100, "bytes 0-99/1000"),
        ] as [(Int64, String)])
    func invalidContentRangeFails(offset: Int64, contentRange: String) async throws {
        let host = StreamStubProtocol.register(.init(body: Self.body, contentRange: contentRange))
        let request = try await load(
            "https://\(host)/t", range: RequestedRange(offset: offset, length: nil), through: transport())

        #expect(request.error as? HeaderStreamingError == .invalidRange)
        #expect(request.data.isEmpty)
    }

    @Test func rangeClippedAtTheEndOfTheResourceSucceeds() async throws {
        let host = StreamStubProtocol.register(.init(body: Self.body))
        // The stub answers `bytes 900-999/1000` for a request that wants up to byte 1099.
        let request = try await load(
            "https://\(host)/t", range: RequestedRange(offset: 900, length: 200), through: transport())

        #expect(request.error == nil)
        #expect(request.data == Self.body.subdata(in: 900..<1000))
    }

    /// A `206` that ends before the requested end, or before the end of the resource for an
    /// open-ended read, would leave the request unfulfilled.
    @Test(arguments: [100, nil] as [Int64?])
    func shortPartialResponseFails(length: Int64?) async throws {
        let host = StreamStubProtocol.register(.init(body: Self.body, rangeEndsAt: 149))
        let request = try await load(
            "https://\(host)/t", range: RequestedRange(offset: 100, length: length), through: transport())

        #expect(request.error as? HeaderStreamingError == .invalidRange)
        #expect(request.data.isEmpty)
    }

    @Test func openEndedBodyEndingEarlyFails() async throws {
        let host = StreamStubProtocol.register(.init(body: Self.body, truncatesTo: 20))
        let request = try await load(
            "https://\(host)/t", range: RequestedRange(offset: 900, length: nil), wantsContentInformation: false,
            through: transport())

        #expect((request.error as? URLError)?.code == .networkConnectionLost)
        #expect(request.data == Self.body.subdata(in: 900..<920))
    }

    @Test func bodyEndingEarlyFails() async throws {
        let host = StreamStubProtocol.register(.init(body: Self.body, truncatesTo: 50))
        let request = try await load(
            "https://\(host)/t", range: RequestedRange(offset: 0, length: 200), through: transport())

        #expect((request.error as? URLError)?.code == .networkConnectionLost)
        #expect(request.data == Self.body.subdata(in: 0..<50))
    }

    @Test func textResponseIsRefused() async throws {
        let host = StreamStubProtocol.register(.init(body: Data("<html>Sign in</html>".utf8), mimeType: "text/html"))
        let request = try await load(
            "https://\(host)/t", range: RequestedRange(offset: 0, length: 2), through: transport())

        #expect(request.error as? HeaderStreamingError == .unexpectedContentType("text/html"))
        #expect(request.information == nil)
    }

    @Test func unregisteredOrUnloadableURLsFailClosed() async throws {
        let host = StreamStubProtocol.register(.init(body: Self.body))
        let transport = transport()
        let unregistered = try await load(
            "https://\(host)/t", range: RequestedRange(offset: 0, length: 2), through: transport, registers: false)
        #expect((unregistered.error as? URLError)?.code == .unsupportedURL)

        let unloadable = RecordingLoadingRequest(range: RequestedRange(offset: 0, length: 2))
        let loader = transport.loader
        loader.register(HeaderStreamingTransport.unloadableURL, track: .init())
        loader.queue.async { loader.start(unloadable, loaderURL: HeaderStreamingTransport.unloadableURL) }
        await unloadable.finished()
        #expect((unloadable.error as? URLError)?.code == .unsupportedURL)
        #expect(StreamStubProtocol.requests(host).isEmpty)
    }

    @Test func cancelledLoadIsNeverFinishedNorFed() async throws {
        let host = StreamStubProtocol.register(.init(body: Self.body, chunkSize: 100, holdsAfterFirstChunk: true))
        let transport = transport()
        let loader = transport.loader
        let url = HeaderStreamingTransport.loaderURL(for: try #require(URL(string: "https://\(host)/t")))
        loader.register(url, track: .init())
        let request = RecordingLoadingRequest(range: RequestedRange(offset: 0, length: 500))
        loader.queue.async { loader.start(request, loaderURL: url) }
        try await eventually { !request.data.isEmpty }

        loader.queue.async { loader.cancel(request) }
        try await eventually { StreamStubProtocol.stops(host) == 1 }
        try await Task.sleep(for: .milliseconds(100))
        loader.queue.sync {}

        #expect(StreamStubProtocol.stops(host) == 1)
        #expect(request.finishCount == 0)
        #expect(request.data == Self.body.subdata(in: 0..<100))
    }

    /// The transport released while a load runs: the load finishes cancelled, a later one fails
    /// cleanly instead of creating a task in the invalidated session, and the loader is freed.
    @Test func releasingTheTransportEndsItsLoadsAndFreesTheLoader() async throws {
        let host = StreamStubProtocol.register(.init(body: Self.body, chunkSize: 100, holdsAfterFirstChunk: true))
        var transport: HeaderStreamingTransport? = transport()
        let url = HeaderStreamingTransport.loaderURL(for: try #require(URL(string: "https://\(host)/t")))
        let running = RecordingLoadingRequest(range: RequestedRange(offset: 0, length: 500))
        let later = RecordingLoadingRequest(range: RequestedRange(offset: 0, length: 2))
        weak var weakLoader: HeaderResourceLoader?
        do {
            let loader = try #require(transport?.loader)
            weakLoader = loader
            loader.register(url, track: .init())
            loader.queue.async { loader.start(running, loaderURL: url) }
            try await eventually { !running.data.isEmpty }

            transport = nil
            await running.finished()
            // Fails at once, in `start`, rather than through a task in the invalidated session.
            let failedAtOnce = loader.queue.sync {
                loader.start(later, loaderURL: url)
                return later.finishCount == 1
            }
            #expect(failedAtOnce)
            await later.finished()
        }

        #expect((running.error as? URLError)?.code == .cancelled)
        #expect(running.finishCount == 1)
        #expect((later.error as? URLError)?.code == .cancelled)
        #expect(StreamStubProtocol.requests(host).count == 1)
        try await eventually { weakLoader == nil }
        #expect(weakLoader == nil)
    }

    /// A final chunk and a clean completion already queued when the session is invalidated:
    /// the load has finished cancelled, and neither is delivered.
    @Test func callbacksQueuedDuringInvalidationAreIgnored() async throws {
        let host = StreamStubProtocol.register(.init(body: Self.body, chunkSize: 100, holdsAfterFirstChunk: true))
        let transport = transport()
        let loader = transport.loader
        let url = HeaderStreamingTransport.loaderURL(for: try #require(URL(string: "https://\(host)/t")))
        loader.register(url, track: .init())
        let request = RecordingLoadingRequest(range: RequestedRange(offset: 0, length: 200))
        loader.queue.async { loader.start(request, loaderURL: url) }
        try await eventually { !request.data.isEmpty }

        let task = try #require(loader.queue.sync { loader.task(for: request) } as? URLSessionDataTask)
        loader.queue.sync {
            loader.invalidate()
            loader.urlSession(.shared, dataTask: task, didReceive: Self.body.subdata(in: 100..<200))
            loader.urlSession(.shared, task: task, didCompleteWithError: nil)
        }

        #expect(request.finishCount == 1)
        #expect((request.error as? URLError)?.code == .cancelled)
        #expect(request.data == Self.body.subdata(in: 0..<100))
    }

    @Test func cookiesAreNotSentAndTheSessionKeepsNoState() async throws {
        let host = StreamStubProtocol.register(.init(body: Self.body))
        let jar = HTTPCookieStorage()
        let cookie = try #require(
            HTTPCookie(properties: [.domain: host, .path: "/", .name: "connect.sid", .value: "session"]))
        jar.setCookie(cookie)
        // The caller's configuration would send cookies; the transport turns that off.
        let configuration = StreamStubProtocol.configuration()
        configuration.httpCookieStorage = jar
        configuration.httpShouldSetCookies = true
        configuration.httpCookieAcceptPolicy = .always
        configuration.httpAdditionalHeaders = ["Authorization": "Bearer t"]
        configuration.urlCredentialStorage = .shared
        configuration.urlCache = URLCache(memoryCapacity: 1 << 20, diskCapacity: 0)
        let transport = HeaderStreamingTransport(customHeaders: Self.proxyHeaders, configuration: configuration)
        let request = try await load(
            "https://\(host)/t", range: RequestedRange(offset: 0, length: 2), through: transport,
            networkAccess: Self.deniesMetered)

        #expect(request.error == nil)
        let sent = try #require(StreamStubProtocol.requests(host).first)
        #expect(sent.value(forHTTPHeaderField: "Cookie") == nil)
        #expect(sent.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(!sent.httpShouldHandleCookies)
        // The session itself: no state, and the first track's network access.
        let effective = try #require(transport.loader.sessionConfiguration)
        #expect(effective.httpCookieStorage == nil)
        #expect(!effective.httpShouldSetCookies)
        #expect(effective.urlCache == nil)
        #expect(effective.urlCredentialStorage == nil)
        #expect(effective.httpAdditionalHeaders == nil)
        #expect(!effective.allowsCellularAccess)
        #expect(!effective.allowsExpensiveNetworkAccess)
        #expect(!effective.allowsConstrainedNetworkAccess)
    }

    @Test func httpErrorFailsTheLoadWithItsStatus() async throws {
        let host = StreamStubProtocol.register(.init(status: 403))
        let request = try await load(
            "https://\(host)/t", range: RequestedRange(offset: 0, length: 2), through: transport())

        #expect(request.error as? HeaderStreamingError == .httpStatus(403))
        #expect(request.data.isEmpty)
        #expect((request.error as? NSError)?.code == 403)
    }

    // MARK: - Redirects

    @Test func crossOriginRedirectDropsTheCustomHeadersButKeepsTheRange() async throws {
        let target = StreamStubProtocol.register(.init(body: Self.body))
        let origin = StreamStubProtocol.register(
            .init(redirects: ["/public/session/s/track/1": "https://\(target)/cdn/track"]))
        let request = try await load(
            "https://\(origin)/public/session/s/track/1", range: RequestedRange(offset: 10, length: 20),
            through: transport(), networkAccess: Self.deniesMetered)

        #expect(request.error == nil)
        #expect(request.data == Self.body.subdata(in: 10..<30))
        let first = try #require(StreamStubProtocol.requests(origin).first)
        #expect(first.value(forHTTPHeaderField: "CF-Access-Client-Secret") == "secret")
        let hop = try #require(StreamStubProtocol.requests(target).first)
        for name in ["CF-Access-Client-Id", "CF-Access-Client-Secret", "Authorization", "Cookie"] {
            #expect(hop.value(forHTTPHeaderField: name) == nil, "\(name)")
        }
        #expect(hop.value(forHTTPHeaderField: "Range") == "bytes=10-29")
        #expect(hop.value(forHTTPHeaderField: "Accept-Encoding") == "identity")
        // `RedirectPolicy` builds the stripped hop afresh; the flags must come back with it.
        #expect(!hop.allowsCellularAccess)
        #expect(!hop.allowsExpensiveNetworkAccess)
        #expect(!hop.allowsConstrainedNetworkAccess)
    }

    @Test func sameOriginRedirectKeepsTheCustomHeaders() async throws {
        let host = StreamStubProtocol.register(.init(body: Self.body))
        StreamStubProtocol.register(redirects: ["/t": "https://\(host)/moved"], on: host)
        let request = try await load(
            "https://\(host)/t", range: RequestedRange(offset: 0, length: 10), through: transport())

        #expect(request.error == nil)
        #expect(request.data == Self.body.subdata(in: 0..<10))
        let requests = StreamStubProtocol.requests(host)
        #expect(requests.map { $0.url?.path() } == ["/t", "/moved"])
        for request in requests {
            #expect(request.value(forHTTPHeaderField: "CF-Access-Client-Secret") == "secret")
            #expect(request.value(forHTTPHeaderField: "Range") == "bytes=0-9")
        }
    }

    /// A redirect to an unrelated service on this device or the local network is refused even
    /// where ``RedirectPolicy`` alone would follow it (`http` to `http`, or to `https`).
    @Test(arguments: [("http", "http://127.0.0.1/track"), ("https", "https://192.168.1.20/track")])
    func redirectToALocalServiceIsRefused(scheme: String, location: String) async throws {
        let target = StreamStubProtocol.register(
            .init(body: Self.body), host: try #require(URL(string: location)?.host()))
        let origin = StreamStubProtocol.register(.init(redirects: ["/t": location]))
        let request = try await load(
            "\(scheme)://\(origin)/t", range: RequestedRange(offset: 0, length: 10), through: transport())

        #expect(request.error as? HeaderStreamingError == .httpStatus(302))
        #expect(StreamStubProtocol.requests(target).isEmpty)
    }

    @Test func downgradeToHTTPIsRefused() async throws {
        let target = StreamStubProtocol.register(.init(body: Self.body))
        let origin = StreamStubProtocol.register(.init(redirects: ["/t": "http://\(target)/track"]))
        let request = try await load(
            "https://\(origin)/t", range: RequestedRange(offset: 0, length: 10), through: transport())

        #expect(request.error as? HeaderStreamingError == .httpStatus(302))
        #expect(request.data.isEmpty)
        #expect(StreamStubProtocol.requests(target).isEmpty)
    }

    // MARK: - AVFoundation

    @Test func assetLoadsThroughTheTransport() async throws {
        let fixture = try AudioFixture(trackCount: 1)
        let wav = try Data(contentsOf: fixture.urls[0])
        let host = StreamStubProtocol.register(.init(body: wav, mimeType: "application/octet-stream"))
        let transport = transport()
        let url = try #require(URL(string: "https://\(host)/public/session/s/track/1"))
        let asset = transport.makeAsset(url: url, mimeType: "audio/wav", networkAccess: NetworkAccess(policy: .never))

        #expect(asset.url.scheme == "abs-https")
        let duration = try await asset.load(.duration)
        #expect(abs(duration.seconds - AudioFixture.trackLength) < 0.01)
        let requests = StreamStubProtocol.requests(host)
        #expect(!requests.isEmpty)
        for request in requests {
            #expect(request.value(forHTTPHeaderField: "CF-Access-Client-Secret") == "secret")
            #expect(request.value(forHTTPHeaderField: "Range") != nil)
            #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
            #expect(request.allowsCellularAccess == false)
        }
    }

    @MainActor @Test func engineLoadsASourceThroughTheTransport() async throws {
        let fixture = try AudioFixture(trackCount: 2)
        let hosts = try fixture.urls.map {
            StreamStubProtocol.register(.init(body: try Data(contentsOf: $0), mimeType: "application/octet-stream"))
        }
        let urls = try hosts.map { try #require(URL(string: "https://\($0)/public/session/s/track/1")) }
        let source = AudioEngineSource(
            timeline: PlaybackTimeline(
                tracks: [
                    AudioTrack(index: 1, startOffset: 0, duration: AudioFixture.trackLength),
                    AudioTrack(index: 2, startOffset: AudioFixture.trackLength, duration: AudioFixture.trackLength),
                ], chapters: []),
            trackURLs: urls, trackMIMETypes: ["audio/wav", "audio/wav"], headerTransport: transport())
        let engine = AudioEngine(audioSession: nil, timeObserverInterval: 0.05)
        engine.player.isMuted = true
        defer { engine.stop() }

        try await engine.load(source, at: 4)

        #expect(engine.state == .paused)
        #expect(engine.currentTime == 4)
        #expect(engine.currentTrackIndex == 1)
        for host in hosts {
            for request in StreamStubProtocol.requests(host) {
                #expect(request.value(forHTTPHeaderField: "CF-Access-Client-Id") == "client")
            }
        }
        #expect(!StreamStubProtocol.requests(hosts[1]).isEmpty)
    }

    /// A local track (a fixture or a download) on a custom-header connection loads directly:
    /// through the transport it would become `abs-file`, which the loader rejects. A remote track
    /// in the same source still goes through the transport.
    @MainActor @Test func engineLoadsLocalTracksDirectlyBesideTheTransport() async throws {
        let fixture = try AudioFixture(trackCount: 2)
        let body = try Data(contentsOf: fixture.urls[1])
        let host = StreamStubProtocol.register(.init(body: body, mimeType: "application/octet-stream"))
        let remote = try #require(URL(string: "https://\(host)/public/session/s/track/2"))
        let source = AudioEngineSource(
            timeline: fixture.timeline, trackURLs: [fixture.urls[0], remote],
            trackMIMETypes: ["audio/wav", "audio/wav"], headerTransport: transport())
        let engine = AudioEngine(audioSession: nil, timeObserverInterval: 0.05)
        engine.player.isMuted = true
        defer { engine.stop() }

        try await engine.load(source, at: 1)

        #expect(engine.state == .paused)
        #expect(engine.currentTrackIndex == 0)
        let assetURLs = engine.player.items().compactMap { ($0.asset as? AVURLAsset)?.url }
        #expect(assetURLs.count == 2)
        #expect(assetURLs.first == fixture.urls[0])
        #expect(assetURLs.last?.scheme == "abs-https")
    }

    @MainActor @Test func coordinatorHandsTheStreamTransportToTheEngine() async throws {
        let h = try CoordinatorHarness()
        let tracks = try (1...2).map {
            PlayableTrack(
                url: try #require(URL(string: "https://abs.example/public/session/A-1/track/\($0)")),
                mimeType: "audio/mpeg", startOffset: Double($0 - 1) * 1800, duration: 1800, authentication: .session)
        }
        let transport = transport()
        h.service.state.withLock {
            $0.streamOverride = ResolvedStream(
                plan: StreamPlan(kind: .directPlay, transport: .customHeaderResourceLoader, tracks: tracks),
                urls: tracks.map(\.url), transport: transport)
        }

        await h.coordinator.play(itemID: "A")

        let source = try #require(h.engine.loads.first?.source)
        #expect(source.headerTransport === transport)
        #expect(source.trackURLs == tracks.map(\.url))
    }
}
