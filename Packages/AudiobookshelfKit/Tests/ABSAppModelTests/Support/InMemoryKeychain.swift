import ABSCore
import Foundation
import Security
import Synchronization
import Testing

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
    func holdNextRead(sourceLocation: SourceLocation = #_sourceLocation) -> KeychainGate {
        let gate = KeychainGate(sourceLocation: sourceLocation)
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
/// does, so the actor that called it can't run anything else meanwhile. `ConnectionCredentials`
/// runs on its own queue, so the blocked thread isn't one that other tests' tasks need.
///
/// Bounded as ``StubGate`` is, and the blocked thread also gives up after a while, in case
/// whatever would open the gate can't run.
final class KeychainGate: Sendable {
    private let gate: StubGate
    private let sourceLocation: SourceLocation

    init(sourceLocation: SourceLocation = #_sourceLocation) {
        gate = StubGate(sourceLocation: sourceLocation)
        self.sourceLocation = sourceLocation
    }

    /// Returns once the read has arrived and is being held.
    func arrived() async {
        await gate.arrived()
    }

    /// Lets the read through, now or when it arrives.
    func open() {
        gate.open()
    }

    fileprivate func hold() {
        let opened = DispatchSemaphore(value: 0)
        gate.hold { opened.signal() }
        // Twice the gate's timeout, so this only fires if the gate's watchdog couldn't run.
        let seconds = Int(StubGate.timeout.components.seconds) * 2
        if opened.wait(timeout: .now() + .seconds(seconds)) == .timedOut {
            Issue.record("A held Keychain read wasn't let through", sourceLocation: sourceLocation)
        }
    }
}
