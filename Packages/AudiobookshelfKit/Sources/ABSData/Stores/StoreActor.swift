import Foundation
import SwiftData

/// A store's long-lived, actor-owned context (ADR 0003). Every write goes through ``commit(_:)``
/// so a failed save is rolled back instead of lingering in the context, where the next unrelated
/// save would commit it.
protocol StoreActor: ModelActor {
    /// A test seam: when set, the next ``commit(_:)`` fails with this error after applying its
    /// changes, as if `save()` had thrown.
    var pendingCommitFailure: (any Error)? { get set }
}

extension StoreActor {
    /// Applies `changes` and saves them as one transaction (what `ModelContext.transaction` does,
    /// without its closure, which can't return a non-`Sendable` result). On any error, from
    /// `changes` or from the save, every unsaved change in the context is rolled back and the
    /// error rethrown.
    @discardableResult
    func commit<T>(_ changes: () throws -> T) throws -> T {
        do {
            let result = try changes()
            if let failure = pendingCommitFailure {
                pendingCommitFailure = nil
                throw failure
            }
            try modelContext.save()
            return result
        } catch {
            modelContext.rollback()
            throw error
        }
    }

    /// Makes the next ``commit(_:)`` fail with `error` (tests only).
    func failNextCommit(with error: any Error) {
        pendingCommitFailure = error
    }

    /// Whether the context holds unsaved changes (tests only; always `false` between calls).
    var hasUncommittedChanges: Bool { modelContext.hasChanges }
}
