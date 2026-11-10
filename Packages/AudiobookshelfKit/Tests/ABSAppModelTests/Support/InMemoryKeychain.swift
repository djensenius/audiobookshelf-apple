import ABSCore
import Foundation
import Security
import Synchronization

/// A `KeychainStoring` fake that can be made to fail reads or writes, or to hold a read.
final class InMemoryKeychain: KeychainStoring {
    private struct WriteFailure {
        let status: OSStatus
        var allowed: Int
        let matches: @Sendable (Data?) -> Bool
    }

    private struct State {
        var items: [KeychainItem: (data: Data, accessibility: KeychainAccessibility)] = [:]
        var readFailure: OSStatus?
        var writeFailure: WriteFailure?
        var readGate: KeychainGate?
    }

    private let state = Mutex(State())

    /// Makes adds, sets and deletes fail with `status` (reads still work); `nil` restores them.
    /// - Parameters:
    ///   - allowed: How many of the matching writes still succeed first.
    ///   - matches: Which writes fail, by the data written (`nil` for a delete).
    func failWrites(
        with status: OSStatus?, allowing allowed: Int = 0,
        where matches: @escaping @Sendable (Data?) -> Bool = { _ in true }
    ) {
        state.withLock { $0.writeFailure = status.map { WriteFailure(status: $0, allowed: allowed, matches: matches) } }
    }

    /// Makes every read fail with `status`; `nil` restores them.
    func failReads(with status: OSStatus?) {
        state.withLock { $0.readFailure = status }
    }

    /// Holds the next read until the returned gate opens.
    func holdNextRead() -> KeychainGate {
        let gate = KeychainGate()
        state.withLock { $0.readGate = gate }
        return gate
    }

    func accessibility(of item: KeychainItem) -> KeychainAccessibility? {
        state.withLock { $0.items[item]?.accessibility }
    }

    var isEmpty: Bool { state.withLock { $0.items.isEmpty } }

    func data(for item: KeychainItem) throws(KeychainError) -> Data? {
        let gate = state.withLock { state in
            defer { state.readGate = nil }
            return state.readGate
        }
        gate?.hold()
        return try state.withLock { state throws(KeychainError) in
            if let status = state.readFailure { throw KeychainError(status: status) }
            return state.items[item]?.data
        }
    }

    func add(_ data: Data, for item: KeychainItem, accessibility: KeychainAccessibility) throws(KeychainError) -> Bool {
        try write(data) { items in
            guard items[item] == nil else { return false }
            items[item] = (data, accessibility)
            return true
        }
    }

    func set(_ data: Data, for item: KeychainItem, accessibility: KeychainAccessibility) throws(KeychainError) {
        try write(data) { $0[item] = (data, accessibility) }
    }

    func delete(_ item: KeychainItem) throws(KeychainError) {
        try write(nil) { $0[item] = nil }
    }

    private func write<Result>(
        _ data: Data?, _ body: (inout [KeychainItem: (data: Data, accessibility: KeychainAccessibility)]) -> Result
    ) throws(KeychainError) -> Result {
        try state.withLock { state throws(KeychainError) in
            if let failure = state.writeFailure, failure.matches(data) {
                guard failure.allowed > 0 else { throw KeychainError(status: failure.status) }
                state.writeFailure?.allowed -= 1
            }
            return body(&state.items)
        }
    }
}

/// Holds one Keychain read until ``open()``. The read blocks its thread, as a slow Keychain call
/// does, so the actor that called it can't run anything else meanwhile.
final class KeychainGate: Sendable {
    private let arrivals = Mutex<(hasArrived: Bool, waiters: [CheckedContinuation<Void, Never>])>((false, []))
    private let opened = DispatchSemaphore(value: 0)

    /// Returns once the read has arrived and is being held.
    func arrived() async {
        await withCheckedContinuation { continuation in
            let hasArrived = arrivals.withLock { arrivals in
                if !arrivals.hasArrived { arrivals.waiters.append(continuation) }
                return arrivals.hasArrived
            }
            if hasArrived { continuation.resume() }
        }
    }

    /// Lets the read through, now or when it arrives.
    func open() {
        opened.signal()
    }

    fileprivate func hold() {
        let waiters = arrivals.withLock { arrivals in
            arrivals.hasArrived = true
            defer { arrivals.waiters = [] }
            return arrivals.waiters
        }
        waiters.forEach { $0.resume() }
        opened.wait()
    }
}
