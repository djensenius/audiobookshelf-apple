import ABSCore
import Foundation
import Security
import Synchronization

/// A `KeychainStoring` fake that can be made to fail writes.
final class InMemoryKeychain: KeychainStoring {
    private struct State {
        var items: [KeychainItem: (data: Data, accessibility: KeychainAccessibility)] = [:]
        var writeFailure: OSStatus?
    }

    private let state = Mutex(State())

    /// Makes every add, set and delete fail with `status` (reads still work); `nil` restores them.
    func failWrites(with status: OSStatus?) {
        state.withLock { $0.writeFailure = status }
    }

    func accessibility(of item: KeychainItem) -> KeychainAccessibility? {
        state.withLock { $0.items[item]?.accessibility }
    }

    var isEmpty: Bool { state.withLock { $0.items.isEmpty } }

    func data(for item: KeychainItem) throws(KeychainError) -> Data? {
        state.withLock { $0.items[item]?.data }
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
