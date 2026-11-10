import CoreGraphics
import Foundation

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
    private var fetches: [FetchKey: Flight<FetchedFile>] = [:]
    private var decodes: [MemoryKey: Flight<DecodedBitmap>] = [:]
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
    }

    /// Sets the request builder (`MediaURLBuilder`) for one server connection, or removes it.
    /// Replace it whenever the connection's address or custom headers change.
    public func setRequestBuilder(_ builder: (any ImageRequestBuilding)?, for serverID: UUID) {
        builders[serverID] = builder
    }

    /// The image for `key`, downsampled to fit `pixelBox`. Keep the returned wrapper for as long
    /// as the image is shown.
    public func image(for key: ImageKey, pixelBox: PixelBox) async throws -> CoverImage {
        let memoryKey = MemoryKey(key: key, box: pixelBox)
        if let hit = memory.image(for: memoryKey) { return CoverImage(hit) }
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
                return CoverImage(try await flight.join())
            } catch is Flight<DecodedBitmap>.Abandoned {
                continue
            }
        }
    }

    /// The image for `key` fitted into `size` pixels, for Now Playing and CarPlay.
    ///
    /// The bitmap stops counting against the memory cap once this returns, so callers that keep
    /// an image on screen for long (or many of them) should hold the ``CoverImage`` from
    /// ``image(for:pixelBox:)`` instead.
    public func cgImage(for key: ImageKey, size: CGSize) async throws -> CGImage {
        try await image(for: key, pixelBox: PixelBox(width: size.width, height: size.height)).cgImage
    }

    /// Evicts memory LRU entries until it holds at most `fraction` of the cap: 0 on a memory
    /// warning, 0.25 when entering the background on iOS, 0.5 on a macOS pressure warning.
    public func trimMemory(toFraction fraction: Double) {
        memory.trim(toFraction: fraction)
    }

    /// Forgets a removed server: its request builder, in-flight fetches and decodes (which are
    /// cancelled), memory entries and cached files. Fetches already running can't write to the
    /// store afterwards.
    // TODO(#143): wait for the server's file leases before deleting its folder.
    public func removeServer(_ serverID: UUID) async {
        builders[serverID] = nil
        for (key, flight) in fetches where key.key.serverID == serverID {
            flight.cancel()
            fetches[key] = nil
        }
        for (key, flight) in decodes where key.key.serverID == serverID {
            flight.cancel()
            decodes[key] = nil
        }
        memory.removeAll { $0.key.serverID == serverID }
        await fileStore.removeServer(serverID)
    }

    /// The bytes in the memory LRU, and of every live image plus reservations.
    var memoryCost: (lru: Int, combined: Int) { (memory.totalCost, ledger.total) }
    /// Decodes waiting for memory, for tests.
    var memoryWaiterCount: Int { ledger.waiterCount }

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
        let info: ImageDecoder.SourceInfo
        do {
            info = try await ImageDecoder.inspect(file.url)
        } catch ImagePipelineError.unsupportedImage where file.isStored {
            await fileStore.discard(file.url)
            throw ImagePipelineError.unsupportedImage
        }
        let cost = ImageDecoder.estimatedCost(of: info, box: memoryKey.box, bucket: memoryKey.key.bucket)
        try await reserveMemory(cost)
        reserved = cost
        if memoryKey.box.isLarge || info.needsNormalizing {
            try await largeDecodeSlot.acquire()
            holdsLarge = true
            largeDecodeCount += 1
        }
        var cgImage = try await ImageDecoder.decode(info, box: memoryKey.box, bucket: memoryKey.key.bucket)
        if ImageDecoder.needsNormalizing(cgImage) {
            if !holdsLarge {
                try await largeDecodeSlot.acquire()
                holdsLarge = true
                largeDecodeCount += 1
            }
            cgImage = try await ImageDecoder.normalize(cgImage)
        }
        try Task.checkCancellation()
        let image = DecodedBitmap(cgImage, ledger: ledger)
        ledger.unreserve(reserved)
        reserved = 0
        memory.insert(image, for: storeKey)
        // The file's lease must outlive the decode.
        withExtendedLifetime(file) {}
        return image
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
        /// Whether the file is in ``CoverFileStore``.
        var isStored = false
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
        let downloaded = skipsDownloaded ? nil : await downloadedCovers?.downloadedCover(for: key)
        if let downloaded, Self.isFresh(downloaded, for: key) {
            return FetchedFile(url: downloaded.fileURL, updatedAt: key.updatedAt)
        }
        if let cached = await fileStore.lookup(key) {
            return FetchedFile(url: cached.url, updatedAt: key.updatedAt, lease: cached.lease, isStored: true)
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
        let built: URLRequest?
        if let builder = builders[key.serverID] {
            built = builder.imageRequest(for: key.source)
        } else if let url = key.externalURL {
            // External covers never carry the server's headers, so no builder is needed.
            built = URLRequest(url: url)
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
            return FetchedFile(url: stored.url, updatedAt: key.updatedAt, lease: stored.lease, isStored: true)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // The store isn't writable (a full disk or a missing container): decode the download.
            keepsTemporary = true
            let lease = FileLease { try? FileManager.default.removeItem(at: temporary) }
            return FetchedFile(url: temporary, updatedAt: key.updatedAt, lease: lease)
        }
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
