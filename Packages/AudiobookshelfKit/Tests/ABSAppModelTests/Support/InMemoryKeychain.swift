import ABSCore
import Foundation
import Security
import Synchronization

/// A `KeychainStoring` fake that can be made to fail reads or writes, or to hold a read.
final class InMemoryKeychain: KeychainStoring {
    private struct State {
        var items: [KeychainItem: (data: Data, accessibility: KeychainAccessibility)] = [:]
        var readFailure: OSStatus?
        var writeFailure: OSStatus?
        var readGate: KeychainGate?
    }

    private let state = Mutex(State())

    /// Makes every add, set and delete fail with `status` (reads still work); `nil` restores them.
    func failWrites(with status: OSStatus?) {
        state.withLock { $0.writeFailure = status }
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
        try write { items in
            guard items[item] == nil else { return false }
            items[item] = (data, accessibility)
            return true
        }
    }

    func set(_ data: Data, for item: KeychainItem, accessibility: KeychainAccessibility) throws(KeychainError) {
        try write { $0[item] = (data, accessibility) }
    }

    func delete(_ item: KeychainItem) throws(KeychainError) {
        try write { $0[item] = nil }
    }

    private func write<Result>(
        _ body: (inout [KeychainItem: (data: Data, accessibility: KeychainAccessibility)]) -> Result
    ) throws(KeychainError) -> Result {
        try state.withLock { state throws(KeychainError) in
            if let status = state.writeFailure { throw KeychainError(status: status) }
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
