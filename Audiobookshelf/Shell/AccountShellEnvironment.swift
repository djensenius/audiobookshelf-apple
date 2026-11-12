import ABSAppModel
import ABSUI
import SwiftUI

/// What the signed-in shell injects for one account session: the shared library store, the
/// progress reader for item cards and rows, and item actions that run on the store's one
/// ``ProgressItemActions`` for the session (``LibraryStore/itemActions(for:)``), so every screen
/// and every window shares its per-item queue, and a restarted session gets fresh actions.
@MainActor
final class AccountShellValues {
    let store: LibraryStore
    let progressReader: ItemProgressReader
    let itemActions: any ItemActionPerforming

    init(store: LibraryStore) {
        self.store = store
        progressReader = BrowsePresentation.progressReader(store.progress)
        itemActions = store.sessionItemActions() ?? NoOpItemActions()
    }
}

/// Builds a shell's ``AccountShellValues`` once, on the first read for the store that serves the
/// shell's account, and returns the same values afterwards, so a body evaluation builds nothing.
///
/// Keep it in the `@State` of a view that has the shell's `.id(identity)`: a sign-out, or a
/// switch to another account, then drops it with the shell, and the next session builds its own.
@MainActor
final class AccountShellValuesCache {
    private var values: AccountShellValues?

    /// The values for `store`, or `nil` without one (signed out, or a switch's outgoing shell,
    /// once the store serves the next account).
    func values(for store: LibraryStore?) -> AccountShellValues? {
        guard let store else { return nil }
        if let values, values.store === store { return values }
        let values = AccountShellValues(store: store)
        self.values = values
        return values
    }
}

/// The signed-in shell around `content`: injects its account's store, progress reader and item
/// actions, or the signed-out defaults while the store doesn't serve the account.
struct AccountShell<Content: View>: View {
    /// The store while it serves the shell's account, `nil` otherwise.
    let store: LibraryStore?
    @ViewBuilder let content: Content
    @State private var cache = AccountShellValuesCache()

    var body: some View {
        content.modifier(AccountShellEnvironment(values: cache.values(for: store)))
    }
}

/// Sets the environment values ``AccountShellValues`` holds, or their signed-out defaults.
struct AccountShellEnvironment: ViewModifier {
    let values: AccountShellValues?

    func body(content: Content) -> some View {
        content
            .environment(\.libraryStore, values?.store)
            .environment(\.itemProgressReader, values?.progressReader ?? .none)
            .environment(\.itemActions, values?.itemActions ?? NoOpItemActions())
    }
}
