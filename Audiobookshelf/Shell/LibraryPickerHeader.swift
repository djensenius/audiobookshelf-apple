import ABSAppModel
import ABSCore
import ABSUI
import SwiftUI

/// The library picker at the top of the sidebar (`tabViewSidebarHeader`): the scene's library,
/// as a menu of the account's libraries. Until they load, or without any, it shows the
/// Libraries header.
struct LibraryPickerHeader: View {
    var body: some View {
        LibraryPicker {
            Label {
                Text(verbatim: L10n.string("HeaderLibraries"))
            } icon: {
                Image(systemName: "books.vertical")
            }
            .font(.headline)
        }
    }
}

/// The library picker in a compact tab's toolbar, where there's no sidebar header.
struct LibraryPickerToolbar: ToolbarContent {
    var body: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            LibraryPicker { EmptyView() }
        }
    }
}

/// A menu that switches the scene's library through ``SceneLibrarySelection``, saving it as the
/// account's last library. Shows `placeholder` until the store has libraries for the router's
/// account (during a switch the store can already serve the next one).
private struct LibraryPicker<Placeholder: View>: View {
    @ViewBuilder let placeholder: Placeholder
    @Environment(\.libraryStore) private var store
    @Environment(Router.self) private var router: Router?
    @Environment(AccountManager.self) private var accounts: AccountManager?

    var body: some View {
        if let store, let router, SceneLibrarySelection.isServing(router: router, store: store),
            !store.libraries.isEmpty
        {
            let current = router.libraryID.flatMap { id in store.libraries.first { $0.id == id } }
            Menu {
                Picker(
                    selection: Binding(
                        get: { router.libraryID },
                        set: { id in
                            guard let id else { return }
                            SceneLibrarySelection.select(
                                id, router: router, store: store, canAddPodcast: accounts?.canAddPodcast)
                        })
                ) {
                    ForEach(store.libraries) { library in
                        Label {
                            Text(verbatim: library.name)
                        } icon: {
                            Image(systemName: Self.systemImage(for: library.mediaType))
                        }
                        .tag(Optional(library.id))
                    }
                } label: {
                    Text(verbatim: L10n.string("HeaderLibraries"))
                }
                .pickerStyle(.inline)
            } label: {
                Label {
                    Text(verbatim: current?.name ?? L10n.string("HeaderLibraries"))
                } icon: {
                    Image(systemName: Self.systemImage(for: current?.mediaType))
                }
                .font(.headline)
            }
            .accessibilityLabel(Text(verbatim: L10n.string("HeaderLibraries")))
            .accessibilityValue(Text(verbatim: current?.name ?? ""))
            .accessibilityHint(Text(verbatim: L10n.string("MessageLibraryPickerHint")))
        } else {
            placeholder
        }
    }

    private static func systemImage(for mediaType: MediaType?) -> String {
        mediaType == .podcast ? "mic" : "books.vertical"
    }
}

/// Keeps the scene's library in step with the shared store (``SceneLibrarySelection``): the
/// initial library, its check once the libraries load, and deep-link library requests, with
/// Add podcast shown only to users who can add podcasts.
struct SceneLibrarySync: ViewModifier {
    let router: Router
    @Environment(\.libraryStore) private var store
    @Environment(AccountManager.self) private var accounts: AccountManager?

    func body(content: Content) -> some View {
        let canAddPodcast = accounts?.canAddPodcast
        content.onChange(
            of: store.map { SceneLibrarySelection.trigger(router, store: $0, canAddPodcast: canAddPodcast) },
            initial: true
        ) {
            if let store { SceneLibrarySelection.reconcile(router, store: store, canAddPodcast: canAddPodcast) }
        }
    }
}

extension AccountManager {
    /// Whether the signed-in user may add podcasts, or `nil` while unknown (offline or authorizing).
    fileprivate var canAddPodcast: Bool? { authorization?.user.canAddPodcasts }
}

#Preview {
    LibraryPickerHeader()
}
