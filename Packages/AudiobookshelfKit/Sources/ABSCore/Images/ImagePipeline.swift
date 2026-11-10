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
    private let ledger = ImageMemoryLedger()
    private let memory: ImageMemoryCache
    private let decodeSlots: AsyncSemaphore
    private let largeDecodeSlot = AsyncSemaphore(permits: 1)
    private var builders: [UUID: any ImageRequestBuilding] = [:]
    private var fetches: [ImageKey: Flight<FetchedFile>] = [:]
    private var decodes: [MemoryKey: Flight<DecodedBitmap>] = [:]
    /// Network requests started, for tests.
    private(set) var networkFetchCount = 0

    /// - Parameters:
    ///   - sessionConfiguration: The base configuration. The pipeline turns off `URLCache` and
    ///     cookies; tests add a `URLProtocol` here.
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
        let configuration = sessionConfiguration
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        session = URLSession(configuration: configuration)
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
    public func cgImage(for key: ImageKey, size: CGSize) async throws -> CGImage {
        try await image(for: key, pixelBox: PixelBox(width: size.width, height: size.height)).cgImage
    }

    /// Evicts memory LRU entries until it holds at most `fraction` of the cap: 0 on a memory
    /// warning, 0.25 when entering the background on iOS, 0.5 on a macOS pressure warning.
    public func trimMemory(toFraction fraction: Double) {
        memory.trim(toFraction: fraction)
    }

    /// Deletes a removed server's cached files and forgets its request builder.
    public func removeServer(_ serverID: UUID) async {
        builders[serverID] = nil
        await fileStore.removeServer(serverID)
    }

    /// The bytes in the memory LRU, and of every live image plus reservations.
    var memoryCost: (lru: Int, combined: Int) { (memory.totalCost, ledger.total) }

    // MARK: Decode

    private func removeDecode(_ key: MemoryKey, _ flight: Flight<DecodedBitmap>) {
        if decodes[key] === flight { decodes[key] = nil }
    }

    private func decode(_ memoryKey: MemoryKey) async throws -> DecodedBitmap {
        do {
            return try await decodeOnce(memoryKey)
        } catch ImagePipelineError.fileMissing {
            // The file vanished (an OS purge or a deleted download): fetch it once more.
            return try await decodeOnce(memoryKey)
        }
    }

    private func decodeOnce(_ memoryKey: MemoryKey) async throws -> DecodedBitmap {
        let file = try await fetchedFile(for: memoryKey.key)
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
        let info = try await ImageDecoder.inspect(file.url)
        let cost = ImageDecoder.estimatedCost(of: info, box: memoryKey.box, bucket: memoryKey.key.bucket)
        try await reserveMemory(cost)
        reserved = cost
        if memoryKey.box.isLarge || info.needsNormalizing {
            try await largeDecodeSlot.acquire()
            holdsLarge = true
        }
        var cgImage = try await ImageDecoder.decode(info, box: memoryKey.box, bucket: memoryKey.key.bucket)
        if ImageDecoder.needsNormalizing(cgImage) {
            if !holdsLarge {
                try await largeDecodeSlot.acquire()
                holdsLarge = true
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

    /// The encoded input for `key`, as a file. Joined by every decode of the key.
    struct FetchedFile: Sendable {
        var url: URL
        /// The version the file holds, which differs from the key's for a stale downloaded cover.
        var updatedAt: Int?
        var lease: FileLease?
    }

    private func fetchedFile(for key: ImageKey) async throws -> FetchedFile {
        while true {
            let flight: Flight<FetchedFile>
            if let existing = fetches[key], !existing.isAbandoned {
                flight = existing
            } else {
                flight = Flight()
                fetches[key] = flight
                flight.start {
                    do {
                        let file = try await self.fetch(key)
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

    private func removeFetch(_ key: ImageKey, _ flight: Flight<FetchedFile>) {
        if fetches[key] === flight { fetches[key] = nil }
    }

    private func fetch(_ key: ImageKey) async throws -> FetchedFile {
        if let url = key.externalURL, url.isFileURL {
            return FetchedFile(url: url, updatedAt: key.updatedAt)
        }
        let downloaded = await downloadedCovers?.downloadedCover(for: key)
        if let downloaded, Self.isFresh(downloaded, for: key) {
            return FetchedFile(url: downloaded.fileURL, updatedAt: key.updatedAt)
        }
        if let cached = await fileStore.lookup(key) {
            return FetchedFile(url: cached.url, updatedAt: key.updatedAt, lease: cached.lease)
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
        request.httpShouldHandleCookies = false
        request.cachePolicy = .reloadIgnoringLocalCacheData
        if request.value(forHTTPHeaderField: "Accept") == nil {
            request.setValue("image/*", forHTTPHeaderField: "Accept")
        }
        networkFetchCount += 1
        let delegate = ImageTaskDelegate(original: request)
        let (temporary, response): (URL, URLResponse)
        do {
            (temporary, response) = try await session.download(for: request, delegate: delegate)
        } catch {
            if delegate.exceededLimit { throw ImagePipelineError.tooLarge }
            throw error
        }
        defer { try? FileManager.default.removeItem(at: temporary) }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 200
        guard (200..<300).contains(status) else { throw ImagePipelineError.httpStatus(status) }
        let size = (try? temporary.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        guard size <= ImageCacheLimits.maxInputBytes else { throw ImagePipelineError.tooLarge }
        try Task.checkCancellation()
        let stored = try await fileStore.insert(
            moving: temporary, for: key, pathExtension: Self.pathExtension(for: response, key: key))
        return FetchedFile(url: stored.url, updatedAt: key.updatedAt, lease: stored.lease)
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
