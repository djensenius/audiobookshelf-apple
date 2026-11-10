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

    func unreserve(_ cost: Int) {
        state.withLock { $0.reserved -= cost }
    }

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

/// The cost-bounded memory LRU of decoded images. Owned and used only by ``ImagePipeline``.
final class ImageMemoryCache {
    private final class Entry {
        let image: DecodedBitmap
        var lastUse: UInt64

        init(image: DecodedBitmap, lastUse: UInt64) {
            self.image = image
            self.lastUse = lastUse
        }
    }

    let limit: Int
    let ledger: ImageMemoryLedger
    private var entries: [MemoryKey: Entry] = [:]
    private var clock: UInt64 = 0
    /// The bytes of the images in the LRU.
    private(set) var totalCost = 0

    init(limit: Int, ledger: ImageMemoryLedger) {
        self.limit = limit
        self.ledger = ledger
    }

    var count: Int { entries.count }

    func image(for key: MemoryKey) -> DecodedBitmap? {
        guard let entry = entries[key] else { return nil }
        clock += 1
        entry.lastUse = clock
        return entry.image
    }

    func insert(_ image: DecodedBitmap, for key: MemoryKey) {
        clock += 1
        if let old = entries.updateValue(Entry(image: image, lastUse: clock), forKey: key) {
            totalCost -= old.image.cost
        }
        totalCost += image.cost
    }

    /// Evicts least recently used entries that nothing else holds until `cost` more bytes fit
    /// under the combined cap. Returns `false` if live images alone leave no room.
    func makeRoom(for cost: Int) -> Bool {
        guard ledger.total + cost > limit else { return true }
        var unheld: [(key: MemoryKey, lastUse: UInt64)] = []
        for (key, entry) in entries where !entry.image.isHeld {
            unheld.append((key, entry.lastUse))
        }
        for candidate in unheld.sorted(by: { $0.lastUse < $1.lastUse }) {
            remove(candidate.key)
            if ledger.total + cost <= limit { return true }
        }
        return false
    }

    /// Evicts least recently used entries until the LRU holds at most `fraction` of the cap.
    func trim(toFraction fraction: Double) {
        let target = Int(Double(limit) * max(0, fraction))
        let ordered = entries.sorted { $0.value.lastUse < $1.value.lastUse }
        for (key, _) in ordered where totalCost > target {
            remove(key)
        }
    }

    private func remove(_ key: MemoryKey) {
        if let entry = entries.removeValue(forKey: key) {
            totalCost -= entry.image.cost
        }
    }
}
