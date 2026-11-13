import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Loads, downsamples, and caches cover and author images for every consumer: SwiftUI views,
/// CarPlay, Now Playing, and widgets (ADR 0005).
///
/// Load order: memory LRU, a fresh downloaded cover, ``CoverFileStore``, the network, then (when
/// offline or the fetch fails) an older downloaded cover. Fetches are deduplicated per
/// ``ImageKey`` and decodes per key and ``PixelBox``; a cancelled caller leaves without
/// affecting the others, and work is cancelled once nobody waits for it.
public actor ImagePipeline {
    private let limits: ImageCacheLimits
    private let fileStore: CoverFileStore
    private let downloadedCovers: (any DownloadedCoverLookup)?
    private let isOnline: @Sendable () -> Bool
    private let session: URLSession
    private let sessionDelegate = ImageSessionDelegate()
    private let ledger = ImageMemoryLedger()
    private let memory: ImageMemoryCache
    private let decodeSlots: AsyncSemaphore
    private let largeDecodeSlot = AsyncSemaphore(permits: 1)
    private var builders: [UUID: any ImageRequestBuilding] = [:]
    /// Servers removed since their builder was last set, which nothing may fetch for.
    private var removedServers: Set<UUID> = []
    /// Servers given a builder (or told they have none) in this process and not removed since:
    /// their connection is saved, even if a sweep read the saved connections before it was.
    private var sessionServers: Set<UUID> = []
    private var fetches: [FetchKey: Flight<FetchedFile>] = [:]
    private var decodes: [MemoryKey: Flight<DecodedBitmap>] = [:]
    /// ``ensureCoverFile(for:)`` calls in progress per server, which a sweep removes like
    /// tracked loads: one may be about to store its server's first cover.
    private var ensuring: [UUID: Int] = [:]
    /// Network requests started, for tests.
    private(set) var networkFetchCount = 0
    /// Decodes that took the large-decode slot, for tests.
    private(set) var largeDecodeCount = 0

    /// - Parameters:
    ///   - sessionConfiguration: The base configuration, copied. The pipeline turns off
    ///     `URLCache`, cookies and additional headers, and caps each request at 60 s; tests add a
    ///     `URLProtocol` here.
    ///   - isOnline: Whether the network is reachable, for example from `NetworkMonitor`.
    public init(
        limits: ImageCacheLimits,
        fileStore: CoverFileStore,
        downloadedCovers: (any DownloadedCoverLookup)? = nil,
        sessionConfiguration: URLSessionConfiguration = .ephemeral,
        isOnline: @escaping @Sendable () -> Bool = { true }
    ) {
        self.limits = limits
        self.fileStore = fileStore
        self.downloadedCovers = downloadedCovers
        self.isOnline = isOnline
        memory = ImageMemoryCache(limit: limits.memoryBytes, ledger: ledger)
        decodeSlots = AsyncSemaphore(permits: limits.maxConcurrentDecodes)
        let configuration = (sessionConfiguration.copy() as? URLSessionConfiguration) ?? .ephemeral
        configuration.httpAdditionalHeaders = nil
        configuration.timeoutIntervalForResource = 60
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        session = URLSession(configuration: configuration, delegate: sessionDelegate, delegateQueue: nil)
    }

    deinit {
        // The session retains its delegate until invalidated.
        session.invalidateAndCancel()
        try? FileManager.default.removeItem(at: sessionDelegate.temporaryFolder)
    }

    /// Sets the request builder (`MediaURLBuilder`) for one server connection, or removes it.
    /// Replace it whenever the connection's address or custom headers change. Setting a builder
    /// re-enables fetching for a server passed to ``removeServer(_:)``.
    public func setRequestBuilder(_ builder: (any ImageRequestBuilding)?, for serverID: UUID) {
        builders[serverID] = builder
        sessionServers.insert(serverID)
        if builder != nil { removedServers.remove(serverID) }
    }

    /// The image for `key`, downsampled to fit `pixelBox`. Keep the returned wrapper for as long
    /// as the image is shown.
    public func image(for key: ImageKey, pixelBox: PixelBox) async throws -> CoverImage {
        // Before any lookup, so a removed server's covers can't come back from a downloaded file.
        guard !removedServers.contains(key.serverID) else { throw ImagePipelineError.noRequest }
        if let hit = cachedImage(for: key, pixelBox: pixelBox) { return hit }
        let memoryKey = MemoryKey(key: key, box: pixelBox)
        while true {
            try Task.checkCancellation()
            let flight: Flight<DecodedBitmap>
            if let existing = decodes[memoryKey], !existing.isAbandoned {
                flight = existing
            } else {
                flight = Flight()
                decodes[memoryKey] = flight
                flight.start {
                    do {
                        let image = try await self.decode(memoryKey)
                        await self.removeDecode(memoryKey, flight)
                        return image
                    } catch {
                        await self.removeDecode(memoryKey, flight)
                        throw error
                    }
                }
            }
            do {
                // Wrapped outside the cache's lock, so the LRU may have evicted the entry since the
                // decode inserted it; the flight's reference kept the bitmap alive and charged.
                return CoverImage(try await flight.join())
            } catch is Flight<DecodedBitmap>.Abandoned {
                continue
            }
        }
    }

    /// The image for `key` at `pixelBox` if the memory LRU holds it, else `nil`, without
    /// waiting for the actor or loading anything, so a view can show a memory hit on its first
    /// frame. It reads the same LRU as ``image(for:pixelBox:)``: a hit counts as recently used
    /// and is wrapped under the LRU's lock, so it is held before anything can evict it; keep the
    /// wrapper while the image is shown. A removed server's images are purged from the LRU
    /// before its loads are cancelled, and none are inserted afterwards, so they miss here too.
    public nonisolated func cachedImage(for key: ImageKey, pixelBox: PixelBox) -> CoverImage? {
        memory.coverImage(for: MemoryKey(key: key, box: pixelBox))
    }

    /// The image for `key` fitted into `size` pixels, for Now Playing and CarPlay.
    ///
    /// The bitmap stops counting against the memory cap once this returns, so callers that keep
    /// an image on screen for long (or many of them) should hold the ``CoverImage`` from
    /// ``image(for:pixelBox:)`` instead.
    public func cgImage(for key: ImageKey, size: CGSize) async throws -> CGImage {
        try await image(for: key, pixelBox: PixelBox(width: size.width, height: size.height)).cgImage
    }

    /// The ``CoverFileStore`` file holding exactly `key`'s cover, written now if it's missing, for
    /// a reader that only has the store: the widget (ADR 0005, "Widgets"). It skips the memory
    /// LRU, which a stored file may have outlived or never come from. In order:
    /// 1. the stored file;
    /// 2. a downloaded cover at least as new as `key`, downsampled to `key`'s bucket and stored
    ///    as JPEG; an older one is never stored under `key`;
    /// 3. the network.
    ///
    /// Offline, or when the fetch or the write fails, it throws and stores nothing.
    public func ensureCoverFile(for key: ImageKey) async throws -> URL {
        guard !removedServers.contains(key.serverID) else { throw ImagePipelineError.noRequest }
        ensuring[key.serverID, default: 0] += 1
        defer {
            ensuring[key.serverID, default: 1] -= 1
            if ensuring[key.serverID] == 0 { ensuring[key.serverID] = nil }
        }
        if let stored = await fileStore.lookup(key) { return stored.url }
        if let cover = await downloadedCovers?.downloadedCover(for: key), Self.isFresh(cover, for: key) {
            let generation = await fileStore.generation(for: key.serverID)
            // The server may have been removed while the lookup was suspended, and `generation`
            // is then the post-removal one, which `insert` would accept.
            guard !removedServers.contains(key.serverID) else { throw ImagePipelineError.noRequest }
            // A damaged or oversized download falls through to the network, as on display.
            if let jpeg = try? await Self.downsampledJPEG(of: cover.fileURL, bucket: key.bucket, in: temporaryFolder) {
                defer { try? FileManager.default.removeItem(at: jpeg) }
                return try await fileStore.insert(moving: jpeg, for: key, pathExtension: "jpg", generation: generation)
                    .url
            }
        }
        let fetched = try await fetchedFile(for: FetchKey(key: key, skipsDownloaded: true))
        // A store that isn't writable hands back the bare download, which isn't the file asked for.
        guard fetched.storedVersion != nil else { throw CocoaError(.fileWriteUnknown) }
        return fetched.url
    }

    /// Keeps the cover files of `keys` out of the disk cache's LRU eviction, replacing the keys
    /// passed before: pass the current widget snapshot's (``CoverFileStore/exemptFromEviction(_:)``).
    public func exemptFromEviction(_ keys: Set<ImageKey>) async {
        await fileStore.exemptFromEviction(keys)
    }

    /// Evicts memory LRU entries until it holds at most `fraction` of the cap: 0 on a memory
    /// warning, 0.25 when entering the background on iOS, 0.5 on a macOS pressure warning.
    public func trimMemory(toFraction fraction: Double) {
        memory.trim(toFraction: fraction)
    }

    /// Forgets a removed server: its request builder, in-flight fetches and decodes (which are
    /// cancelled), memory entries and cached files. Fetches already running can't write to the
    /// store afterwards, and new ones fail until a builder is set again. The files are deleted
    /// once the decodes reading them have finished, or after a few seconds
    /// (``CoverFileStore/removeServer(_:)``).
    public func removeServer(_ serverID: UUID) async {
        forget(serverID)
        await fileStore.removeServer(serverID)
    }

    /// Removes, as ``removeServer(_:)`` does, every server with cached covers or loads that isn't
    /// in `saved`: connections removed in an earlier launch whose covers weren't deleted then
    /// (#421). Pass the saved connections read from the store, never a list that may not have
    /// loaded yet. Servers given a builder in this process are kept too, so a connection saved
    /// after `saved` was read keeps its covers.
    ///
    /// Not ordered with ``setRequestBuilder(_:for:)``: the app sweeps through `ImageParticipant`,
    /// which calls ``serversToSweep(keepingOnly:)`` and then ``removeServerUnlessInSession(_:)``
    /// in each connection's queue, behind and before its builder installs.
    public func removeServers(keepingOnly saved: Set<UUID>) async {
        for serverID in await serversToSweep(keepingOnly: saved) {
            await removeServerUnlessInSession(serverID)
        }
    }

    /// A sweep's first step: forgets the memory entries and loads of every server not in `saved`
    /// and not given a builder in this process, and returns those servers and the ones with
    /// cached files not in `saved`, for ``removeServerUnlessInSession(_:)``. A forgotten load (or
    /// an ``ensureCoverFile(for:)`` in progress) may be past its checks and about to store its
    /// server's first cover, so its server is removed even without a folder: the removal refuses
    /// that write.
    public func serversToSweep(keepingOnly saved: Set<UUID>) async -> Set<UUID> {
        let kept = saved.union(sessionServers)
        var unkept = Set(fetches.keys.map(\.key.serverID)).union(decodes.keys.map(\.key.serverID))
            .union(ensuring.keys)
        memory.removeAll { entry in
            guard !kept.contains(entry.key.serverID) else { return false }
            unkept.insert(entry.key.serverID)
            return true
        }
        for serverID in unkept.subtracting(kept) { forget(serverID) }
        return await fileStore.servers(notIn: saved).union(unkept.subtracting(kept))
    }

    /// A sweep's removal of one server, as ``removeServer(_:)``, unless it has been given a
    /// builder in this process (a session started since the saved connections were read).
    /// Returns whether it was removed.
    @discardableResult
    public func removeServerUnlessInSession(_ serverID: UUID) async -> Bool {
        guard !sessionServers.contains(serverID) else { return false }
        await removeServer(serverID)
        return true
    }

    /// Everything but the files of ``removeServer(_:)``, before its first `await`.
    private func forget(_ serverID: UUID) {
        builders[serverID] = nil
        removedServers.insert(serverID)
        sessionServers.remove(serverID)
        // First, so the synchronous lookup stops returning the server's covers at once.
        memory.removeAll { $0.key.serverID == serverID }
        for (key, flight) in fetches where key.key.serverID == serverID {
            flight.cancel()
            fetches[key] = nil
        }
        for (key, flight) in decodes where key.key.serverID == serverID {
            flight.cancel()
            decodes[key] = nil
        }
    }

    /// The bytes in the memory LRU, and of every live image plus reservations.
    var memoryCost: (lru: Int, combined: Int) { (memory.totalCost, ledger.total) }
    /// Decodes waiting for memory, for tests.
    var memoryWaiterCount: Int { ledger.waiterCount }
    /// Decodes queued behind the decode cap, for tests.
    var queuedDecodeCount: Int {
        get async { await decodeSlots.waiterCount }
    }
    /// The callers joined to `key`'s fetch (one per decode flight) and to its decode into `box`,
    /// for tests that must know every caller has joined before the result arrives.
    func waiterCounts(for key: ImageKey, box: PixelBox) -> (fetch: Int, decode: Int) {
        (
            fetches[FetchKey(key: key, skipsDownloaded: false)]?.waiterCount ?? 0,
            decodes[MemoryKey(key: key, box: box)]?.waiterCount ?? 0
        )
    }
    /// The folder of this pipeline's temporary downloads, for tests.
    nonisolated var temporaryFolder: URL { sessionDelegate.temporaryFolder }

    // MARK: Decode

    private func removeDecode(_ key: MemoryKey, _ flight: Flight<DecodedBitmap>) {
        if decodes[key] === flight { decodes[key] = nil }
    }

    private func decode(_ memoryKey: MemoryKey) async throws -> DecodedBitmap {
        do {
            return try await decodeOnce(memoryKey, skipsDownloaded: false)
        } catch ImagePipelineError.fileMissing {
            // The file vanished (an OS purge or a deleted download): fetch it once more, without
            // the downloaded cover, which may be the file that vanished.
            return try await decodeOnce(memoryKey, skipsDownloaded: true)
        }
    }

    private func decodeOnce(_ memoryKey: MemoryKey, skipsDownloaded: Bool) async throws -> DecodedBitmap {
        let file = try await fetchedFile(for: FetchKey(key: memoryKey.key, skipsDownloaded: skipsDownloaded))
        // A stale downloaded cover is cached under its own version, never the requested one.
        let storeKey = MemoryKey(key: memoryKey.key.with(updatedAt: file.updatedAt), box: memoryKey.box)
        // Returned bare, like a decode: the waiters wrap it outside the lock.
        if let hit = memory.image(for: storeKey) { return hit }

        try await decodeSlots.acquire()
        var holdsLarge = false
        var reserved = 0
        defer {
            ledger.unreserve(reserved)
            Task { [decodeSlots, largeDecodeSlot, holdsLarge] in
                await decodeSlots.release()
                if holdsLarge { await largeDecodeSlot.release() }
            }
        }
        try Task.checkCancellation()
        var cgImage: CGImage
        do {
            let info = try await ImageDecoder.inspect(file.url)
            let cost = ImageDecoder.estimatedCost(of: info, box: memoryKey.box, bucket: memoryKey.key.bucket)
            try await reserveMemory(cost)
            reserved = cost
            if memoryKey.box.isLarge || info.needsNormalizing {
                try await largeDecodeSlot.acquire()
                holdsLarge = true
                largeDecodeCount += 1
            }
            cgImage = try await ImageDecoder.decode(info, box: memoryKey.box, bucket: memoryKey.key.bucket)
            if ImageDecoder.needsNormalizing(cgImage) {
                if !holdsLarge {
                    try await largeDecodeSlot.acquire()
                    holdsLarge = true
                    largeDecodeCount += 1
                }
                cgImage = try await ImageDecoder.normalize(cgImage)
            }
        } catch ImagePipelineError.unsupportedImage where file.storedVersion != nil {
            // A damaged cached file: delete it unless rewritten since, and refetch once (as for a
            // vanished file).
            await fileStore.discard(file.url, version: file.storedVersion ?? 0)
            throw skipsDownloaded ? ImagePipelineError.unsupportedImage : .fileMissing
        }
        try Task.checkCancellation()
        let image = DecodedBitmap(cgImage, ledger: ledger, updatedAt: storeKey.key.updatedAt)
        ledger.unreserve(reserved)
        reserved = 0
        try cache(image, for: storeKey)
        // The file's lease must outlive the decode.
        withExtendedLifetime(file) {}
        return image
    }

    /// Puts a decoded image in the memory LRU, unless its server was removed while it decoded:
    /// views read the LRU directly through ``cachedImage(for:pixelBox:)``, so nothing may put a
    /// removed server's covers back.
    func cache(_ image: DecodedBitmap, for key: MemoryKey) throws {
        guard !removedServers.contains(key.key.serverID) else { throw ImagePipelineError.noRequest }
        memory.insert(image, for: key)
    }

    /// Makes room for `cost` bytes under the combined cap, waiting for live images to be
    /// released if they alone fill it, then reserves it.
    private func reserveMemory(_ cost: Int) async throws {
        guard cost <= limits.memoryBytes else { throw ImagePipelineError.tooLarge }
        while true {
            let generation = ledger.generation
            if memory.makeRoom(for: cost) {
                ledger.reserve(cost)
                return
            }
            await ledger.waitForRelease(after: generation)
            try Task.checkCancellation()
        }
    }

    // MARK: Fetch

    /// One fetch: a vanished-file retry skips the downloaded cover, so it's a separate fetch.
    struct FetchKey: Hashable {
        var key: ImageKey
        var skipsDownloaded: Bool
    }

    /// The encoded input for a key, as a file. Joined by every decode of the key.
    struct FetchedFile: Sendable {
        var url: URL
        /// The version the file holds, which differs from the key's for a stale downloaded cover.
        var updatedAt: Int?
        /// Keeps a stored file from eviction, or deletes an unstored download when released.
        var lease: FileLease?
        /// The ``CoverFileStore`` write the file came from, or `nil` if it isn't stored.
        var storedVersion: Int?
    }

    private func fetchedFile(for key: FetchKey) async throws -> FetchedFile {
        while true {
            try Task.checkCancellation()
            let flight: Flight<FetchedFile>
            if let existing = fetches[key], !existing.isAbandoned {
                flight = existing
            } else {
                flight = Flight()
                fetches[key] = flight
                flight.start {
                    do {
                        let file = try await self.fetch(key.key, skipsDownloaded: key.skipsDownloaded)
                        await self.removeFetch(key, flight)
                        return file
                    } catch {
                        await self.removeFetch(key, flight)
                        throw error
                    }
                }
            }
            do {
                return try await flight.join()
            } catch is Flight<FetchedFile>.Abandoned {
                continue
            }
        }
    }

    private func removeFetch(_ key: FetchKey, _ flight: Flight<FetchedFile>) {
        if fetches[key] === flight { fetches[key] = nil }
    }

    private func fetch(_ key: ImageKey, skipsDownloaded: Bool) async throws -> FetchedFile {
        var downloaded = skipsDownloaded ? nil : await downloadedCovers?.downloadedCover(for: key)
        // A downloaded cover over the input cap is unusable, as if missing (ADR 0005, "Input cap").
        if let cover = downloaded, ImageDecoder.isOverInputCap(cover.fileURL) { downloaded = nil }
        if let downloaded, Self.isFresh(downloaded, for: key) {
            return FetchedFile(url: downloaded.fileURL, updatedAt: key.updatedAt)
        }
        if let cached = await fileStore.lookup(key) {
            return FetchedFile(
                url: cached.url, updatedAt: key.updatedAt, lease: cached.lease, storedVersion: cached.version)
        }
        do {
            guard isOnline() else { throw ImagePipelineError.offline }
            return try await download(key)
        } catch  where !Task.isCancelled {
            guard let downloaded else { throw error }
            return FetchedFile(url: downloaded.fileURL, updatedAt: downloaded.updatedAt)
        }
    }

    private static func isFresh(_ cover: DownloadedCover, for key: ImageKey) -> Bool {
        guard let wanted = key.updatedAt else { return true }
        return (cover.updatedAt ?? Int.min) >= wanted
    }

    private func download(_ key: ImageKey) async throws -> FetchedFile {
        // A removed server's external covers would recreate its folder.
        guard !removedServers.contains(key.serverID) else { throw ImagePipelineError.noRequest }
        let built: URLRequest?
        if let builder = builders[key.serverID] {
            built = builder.imageRequest(for: key.source)
        } else if let url = key.externalURL {
            // External covers never carry the server's headers, so no builder is needed. Without
            // the server's address, only a public `https` host is allowed.
            built = ImageDestination.isAllowed(url, server: nil) ? URLRequest(url: url) : nil
        } else {
            built = nil
        }
        guard var request = built, let scheme = request.url?.scheme?.lowercased(), scheme == "http" || scheme == "https"
        else { throw ImagePipelineError.noRequest }
        // Images never carry the Audiobookshelf token or cookies, whatever the builder adds.
        request.setValue(nil, forHTTPHeaderField: "Authorization")
        request.setValue(nil, forHTTPHeaderField: "Cookie")
        request.httpShouldHandleCookies = false
        request.cachePolicy = .reloadIgnoringLocalCacheData
        if request.value(forHTTPHeaderField: "Accept") == nil {
            request.setValue("image/*", forHTTPHeaderField: "Accept")
        }
        let generation = await fileStore.generation(for: key.serverID)
        networkFetchCount += 1
        let (temporary, response) = try await sessionDelegate.download(request, session: session)
        var keepsTemporary = false
        defer {
            if !keepsTemporary { try? FileManager.default.removeItem(at: temporary) }
        }
        // A 2xx that isn't an image (a proxy's login page) is never cached.
        guard await ImageDecoder.isImage(temporary) else { throw ImagePipelineError.unsupportedImage }
        try Task.checkCancellation()
        do {
            let stored = try await fileStore.insert(
                moving: temporary, for: key, pathExtension: Self.pathExtension(for: response, key: key),
                generation: generation)
            return FetchedFile(
                url: stored.url, updatedAt: key.updatedAt, lease: stored.lease, storedVersion: stored.version)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // The store isn't writable (a full disk or a missing container): decode the download,
            // which a failed insert leaves in place.
            keepsTemporary = true
            let lease = FileLease { try? FileManager.default.removeItem(at: temporary) }
            return FetchedFile(url: temporary, updatedAt: key.updatedAt, lease: lease)
        }
    }

    /// `url` downsampled to `bucket`'s width (never upscaled), with its aspect ratio and EXIF
    /// orientation kept, as a new JPEG file in `folder`. Only the width is bounded, like the
    /// server's `width=` rendition, so a tall cover isn't cut to a display box.
    @concurrent private static func downsampledJPEG(
        of url: URL, bucket: ImageWidthBucket, in folder: URL
    ) async throws -> URL {
        let info = try await ImageDecoder.inspect(url)
        let scale = min(Double(bucket.rawValue) / Double(info.width), 1)
        let longSide = max(1, Int((Double(max(info.width, info.height)) * scale).rounded()))
        guard
            let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
            let image = CGImageSourceCreateThumbnailAtIndex(
                source, 0,
                [
                    kCGImageSourceThumbnailMaxPixelSize: longSide,
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                ] as CFDictionary)
        else { throw ImagePipelineError.unsupportedImage }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let output = folder.appending(path: "\(UUID().uuidString).jpg")
        guard
            let destination = CGImageDestinationCreateWithURL(
                output as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
        else { throw CocoaError(.fileWriteUnknown) }
        CGImageDestinationAddImage(
            destination, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            try? FileManager.default.removeItem(at: output)
            throw CocoaError(.fileWriteUnknown)
        }
        return output
    }

    private static func pathExtension(for response: URLResponse, key: ImageKey) -> String {
        switch response.mimeType?.lowercased() {
        case "image/webp": "webp"
        case "image/jpeg", "image/jpg": "jpg"
        case "image/png": "png"
        case "image/heic": "heic"
        case "image/gif": "gif"
        default: key.externalURL == nil ? "webp" : "img"
        }
    }
}
