import ABSAppModel
import Foundation
import SwiftUI

/// The environment values library screens read (Home, item detail and the other library screens),
/// so a feature never edits the shell or another feature to get them. The shell only sets them:
/// the signed-in account's values come from #180 (`serverID`), ``AccountShell`` (`libraryStore`,
/// `itemProgressReader` and `itemActions`, once per session) and #183 (`playItem`).
///
/// Every default is the signed-out value, so previews and app tests need no setup.
///
/// Also available, declared in ABSUI and not redeclared here:
/// - `imagePipeline`: the cover image pipeline (`ImagePipeline?`, `nil` while signed out);
/// - `itemProgressReader`: the progress shown on item cards and rows (`ItemProgressReader`,
///   `.none` while signed out).
///
/// The scene's `Router` (its `libraryID` and `libraryKind`) is in the environment as an
/// observable object: `@Environment(Router.self)`, set by ``MainTabView``.
extension EnvironmentValues {
    /// The library data shared by every scene; `nil` while signed out.
    @Entry var libraryStore: LibraryStore?
    /// The active server connection's ID, for `CoverRef.key(serverID:)`; `nil` while signed out.
    @Entry var serverID: UUID?
    /// The progress actions on an item or episode; ``NoOpItemActions`` while signed out.
    @Entry var itemActions: any ItemActionPerforming = NoOpItemActions()
    /// Plays an item or episode; `nil` while signed out.
    @Entry var playItem: PlayItemAction?
    /// Queues downloads (Download Series); `nil` where the app has no download stack.
    @Entry var downloadAccess: DownloadAccess?
}
