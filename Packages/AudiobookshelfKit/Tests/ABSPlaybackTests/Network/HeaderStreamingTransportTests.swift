import ABSCore
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

    private func transport(_ headers: [String: String] = proxyHeaders) -> HeaderStreamingTransport {
        HeaderStreamingTransport(customHeaders: headers, configuration: StreamStubProtocol.configuration())
    }

    /// Runs one loading request for `url` through `transport`'s loader and waits for it to finish.
    private func load(
        _ url: String, range: RequestedRange?, wantsContentInformation: Bool = true,
        through transport: HeaderStreamingTransport, mimeType: String? = "audio/mpeg"
    ) async throws -> RecordingLoadingRequest {
        let url = try #require(URL(string: url))
        let request = RecordingLoadingRequest(range: range, wantsContentInformation: wantsContentInformation)
        let loaderURL = HeaderStreamingTransport.loaderURL(for: url)
        let loader = transport.loader
        loader.register(loaderURL, track: .init(mimeType: mimeType, networkAccess: nil))
        loader.queue.async { loader.start(request, loaderURL: loaderURL) }
        await request.finished()
        return request
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
        let (info, offset) = try #require(
            HeaderResourceLoader.contentInformation(from: partial, mimeType: "audio/mpeg"))
        #expect(
            info == ContentInformation(contentType: "public.mp3", contentLength: 5000, isByteRangeAccessSupported: true)
        )
        #expect(offset == 100)

        let full = try #require(
            HTTPURLResponse(
                url: url, statusCode: 200, httpVersion: nil,
                headerFields: ["Content-Length": "5000", "Content-Type": "audio/mp4", "Accept-Ranges": "bytes"]))
        let (fullInfo, fullOffset) = try #require(HeaderResourceLoader.contentInformation(from: full, mimeType: nil))
        #expect(fullInfo.contentType == UTType(mimeType: "audio/mp4")?.identifier)
        #expect(fullInfo.contentLength == 5000)
        #expect(fullInfo.isByteRangeAccessSupported)
        #expect(fullOffset == 0)

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

    @Test func fullResponseToARangeIsSkippedAndTrimmed() async throws {
        let host = StreamStubProtocol.register(.init(body: Self.body, honorsRange: false))
        let request = try await load(
            "https://\(host)/t", range: RequestedRange(offset: 300, length: 100), through: transport())

        #expect(request.error == nil)
        #expect(request.data == Self.body.subdata(in: 300..<400))
        #expect(request.information?.isByteRangeAccessSupported == false)
        #expect(request.finishCount == 1)
    }

    @Test(arguments: [(50, true), (200, false)])
    func partialResponseFromAnotherOffset(startsAt: Int, isUsable: Bool) async throws {
        let host = StreamStubProtocol.register(.init(body: Self.body, rangeStartsAt: startsAt))
        let request = try await load(
            "https://\(host)/t", range: RequestedRange(offset: 100, length: 50), through: transport())

        if isUsable {
            // An earlier start is skipped up to the requested offset.
            #expect(request.error == nil)
            #expect(request.data == Self.body.subdata(in: 100..<150))
        } else {
            #expect(request.error as? HeaderStreamingError == .invalidRange)
            #expect(request.data.isEmpty)
        }
    }

    @Test func cookiesAreNotSent() async throws {
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
        let transport = HeaderStreamingTransport(customHeaders: Self.proxyHeaders, configuration: configuration)
        let request = try await load(
            "https://\(host)/t", range: RequestedRange(offset: 0, length: 2), through: transport)

        #expect(request.error == nil)
        let sent = try #require(StreamStubProtocol.requests(host).first)
        #expect(sent.value(forHTTPHeaderField: "Cookie") == nil)
        #expect(!sent.httpShouldHandleCookies)
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
            through: transport())

        #expect(request.error == nil)
        #expect(request.data == Self.body.subdata(in: 10..<30))
        let first = try #require(StreamStubProtocol.requests(origin).first)
        #expect(first.value(forHTTPHeaderField: "CF-Access-Client-Secret") == "secret")
        let hop = try #require(StreamStubProtocol.requests(target).first)
        for name in ["CF-Access-Client-Id", "CF-Access-Client-Secret", "Authorization", "Cookie"] {
            #expect(hop.value(forHTTPHeaderField: name) == nil, "\(name)")
        }
        #expect(hop.value(forHTTPHeaderField: "Range") == "bytes=10-29")
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
