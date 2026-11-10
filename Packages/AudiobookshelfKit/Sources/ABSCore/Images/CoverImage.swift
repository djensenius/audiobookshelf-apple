import CoreGraphics
import Foundation
import Synchronization

/// A decoded, fully oriented 8-bit image from ``ImagePipeline``.
///
/// Its bitmap counts against the pipeline's memory cap while any wrapper holds it, even after
/// the memory LRU evicts it, and the LRU only evicts bitmaps no wrapper holds. Keep the wrapper
/// (not just the `CGImage`) for as long as the image is shown.
public final class CoverImage: Sendable {
    let bitmap: DecodedBitmap

    init(_ bitmap: DecodedBitmap) {
        self.bitmap = bitmap
        bitmap.holders.add(1, ordering: .relaxed)
    }

    deinit {
        bitmap.holders.subtract(1, ordering: .relaxed)
        bitmap.ledger?.signal()
    }

    public var cgImage: CGImage { bitmap.cgImage }
    /// The bytes the bitmap occupies: `bytesPerRow × height`.
    public var cost: Int { bitmap.cost }
    public var pixelWidth: Int { cgImage.width }
    public var pixelHeight: Int { cgImage.height }
}

/// A decoded bitmap, charged to the ledger for as long as it exists.
final class DecodedBitmap: Sendable {
    let cgImage: CGImage
    let cost: Int
    let ledger: ImageMemoryLedger?
    /// The live ``CoverImage`` wrappers.
    let holders = Atomic<Int>(0)

    init(_ cgImage: CGImage, ledger: ImageMemoryLedger?) {
        self.cgImage = cgImage
        self.cost = cgImage.bytesPerRow * cgImage.height
        self.ledger = ledger
        ledger?.add(cost)
    }

    deinit {
        ledger?.remove(cost)
    }

    var isHeld: Bool { holders.load(ordering: .relaxed) > 0 }
}

/// Counts the bytes of every live ``CoverImage`` (in the LRU or held by a consumer) plus
/// reservations for decodes in progress, so the cap covers both (ADR 0005, "Live-image
/// ledger").
final class ImageMemoryLedger: Sendable {
    private struct State {
        var live = 0
        var reserved = 0
        var generation: UInt64 = 0
        var waiters: [UInt64: CheckedContinuation<Void, Never>] = [:]
        var nextWaiter: UInt64 = 0
    }

    private let state = Mutex(State())

    var total: Int { state.withLock { $0.live + $0.reserved } }
    var live: Int { state.withLock { $0.live } }
    /// Changes every time an image is released or unheld.
    var generation: UInt64 { state.withLock { $0.generation } }

    func add(_ cost: Int) {
        state.withLock { $0.live += cost }
    }

    func remove(_ cost: Int) {
        state.withLock { $0.live -= cost }
        signal()
    }

    /// Wakes decodes waiting for room: an image was released or is no longer held.
    func signal() {
        let waiters = state.withLock { state in
            state.generation &+= 1
            defer { state.waiters = [:] }
            return Array(state.waiters.values)
        }
        for waiter in waiters { waiter.resume() }
    }

    func reserve(_ cost: Int) {
        state.withLock { $0.reserved += cost }
    }

    /// Returns a reservation, waking decodes waiting for room (the reserving decode may have
    /// failed or been cancelled).
    func unreserve(_ cost: Int) {
        guard cost > 0 else { return }
        state.withLock { $0.reserved -= cost }
        signal()
    }

    /// The decodes waiting for room, for tests.
    var waiterCount: Int { state.withLock { $0.waiters.count } }

    /// Returns once an image is released after `generation`, or when the task is cancelled.
    func waitForRelease(after generation: UInt64) async {
        let id = state.withLock { state in
            state.nextWaiter += 1
            return state.nextWaiter
        }
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let resumeNow = state.withLock { state in
                    if state.generation != generation || Task.isCancelled { return true }
                    state.waiters[id] = continuation
                    return false
                }
                if resumeNow { continuation.resume() }
            }
        } onCancel: {
            state.withLock { $0.waiters.removeValue(forKey: id) }?.resume()
        }
    }
}

/// The cost-bounded memory LRU of decoded images, shared by ``ImagePipeline`` and its
/// synchronous ``ImagePipeline/cachedImage(for:pixelBox:)`` lookup. One lock guards the
/// entries, so every reader sees the same LRU: an entry the actor evicts or trims is gone for
/// all of them.
///
/// Removed bitmaps are released after the lock is dropped, so a lookup never waits while
/// a trim deallocates them. Lock order: this cache's lock, then the ledger's (``makeRoom(for:)``
/// reads the ledger's total). The ledger never takes this lock.
final class ImageMemoryCache: Sendable {
    private struct Entry {
        let image: DecodedBitmap
        var lastUse: UInt64
    }

    private struct State {
        var entries: [MemoryKey: Entry] = [:]
        var clock: UInt64 = 0
        var totalCost = 0

        /// The image for `key`, marked most recently used.
        mutating func use(_ key: MemoryKey) -> DecodedBitmap? {
            guard let image = entries[key]?.image else { return nil }
            clock += 1
            entries[key]?.lastUse = clock
            return image
        }

        /// Removes `key`'s entry and returns its image, for the caller to release after the lock.
        mutating func remove(_ key: MemoryKey) -> DecodedBitmap? {
            guard let entry = entries.removeValue(forKey: key) else { return nil }
            totalCost -= entry.image.cost
            return entry.image
        }
    }

    let limit: Int
    let ledger: ImageMemoryLedger
    private let state = Mutex(State())

    init(limit: Int, ledger: ImageMemoryLedger) {
        self.limit = limit
        self.ledger = ledger
    }

    var count: Int { state.withLock { $0.entries.count } }
    /// Whether a thread holds the lock, for tests.
    var isLocked: Bool { state.withLockIfAvailable { _ in } == nil }
    /// The bytes of the images in the LRU.
    var totalCost: Int { state.withLock { $0.totalCost } }

    func image(for key: MemoryKey) -> DecodedBitmap? {
        state.withLock { $0.use(key) }
    }

    /// The image for `key` in a new ``CoverImage``. The wrapper is created under the lock, so a
    /// hit is held before ``makeRoom(for:)`` can pick it for eviction. That holds for hits read
    /// here only: a decode's waiters wrap its bitmap outside the lock, after it is inserted, so
    /// the LRU may evict that entry first (the flight's reference keeps the bitmap alive and
    /// charged meanwhile).
    func coverImage(for key: MemoryKey) -> CoverImage? {
        state.withLock { $0.use(key).map(CoverImage.init) }
    }

    func insert(_ image: DecodedBitmap, for key: MemoryKey) {
        // A replaced image is released here, after the lock.
        _ = state.withLock { state in
            state.clock += 1
            state.totalCost += image.cost
            let replaced = state.entries.updateValue(Entry(image: image, lastUse: state.clock), forKey: key)
            if let replaced { state.totalCost -= replaced.image.cost }
            return replaced
        }
    }

    /// Evicts least recently used entries that nothing else holds until `cost` more bytes fit
    /// under the combined cap. Returns `false` if live images alone leave no room.
    func makeRoom(for cost: Int) -> Bool {
        let result = state.withLock { state -> (fits: Bool, evicted: [DecodedBitmap]) in
            guard ledger.total + cost > limit else { return (true, []) }
            var unheld: [(key: MemoryKey, lastUse: UInt64)] = []
            for (key, entry) in state.entries where !entry.image.isHeld {
                unheld.append((key, entry.lastUse))
            }
            // The ledger counts the evicted images until they are released after the lock, so
            // count what eviction frees: the images nothing else, such as a decode's waiters,
            // still references.
            var evicted: [DecodedBitmap] = []
            var freed = 0
            for candidate in unheld.sorted(by: { $0.lastUse < $1.lastUse }) {
                guard var image = state.remove(candidate.key) else { continue }
                if isKnownUniquelyReferenced(&image) { freed += image.cost }
                evicted.append(image)
                if ledger.total - freed + cost <= limit { return (true, evicted) }
            }
            return (false, evicted)
        }
        // The evicted images are released when `result` is, after the lock.
        return result.fits
    }

    /// Removes every entry whose key matches, for example a removed server's.
    func removeAll(where shouldRemove: (MemoryKey) -> Bool) {
        // Released here, after the lock.
        _ = state.withLock { state in
            state.entries.keys.filter(shouldRemove).compactMap { state.remove($0) }
        }
    }

    /// Evicts least recently used entries until the LRU holds at most `fraction` of the cap.
    func trim(toFraction fraction: Double) {
        let target = Int(Double(limit) * max(0, fraction))
        // Released here, after the lock.
        _ = state.withLock { state in
            let ordered = state.entries.sorted { $0.value.lastUse < $1.value.lastUse }.map(\.key)
            var removed: [DecodedBitmap] = []
            for key in ordered where state.totalCost > target {
                if let image = state.remove(key) { removed.append(image) }
            }
            return removed
        }
    }
}
