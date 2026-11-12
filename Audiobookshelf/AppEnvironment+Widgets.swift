import ABSAppModel
import ABSCore
import Foundation
import WidgetKit

/// Reloads widget timelines through `WidgetCenter`.
@MainActor
final class WidgetCenterReloader: WidgetTimelineReloading {
    func reloadTimelines(ofKind kind: String) {
        WidgetCenter.shared.reloadTimelines(ofKind: kind)
    }
}

extension AppEnvironment {
    /// The Continue Listening widget's snapshot writer (#89): a ``SessionStage/connect``
    /// participant that clears the snapshot on sign-out, once its connection is removed, and when
    /// the launch's restore ends signed out. Without an App Group container (an unsigned macOS
    /// build) it writes nothing.
    static func makeWidgetSnapshotWriter(
        accounts: AccountManager?, lifecycle: SessionLifecycle
    ) -> WidgetSnapshotWriter {
        let writer = WidgetSnapshotWriter(fileURL: WidgetSnapshot.defaultFileURL(), reloader: WidgetCenterReloader())
        writer.followLaunch { lifecycle.gate }
        if let accounts {
            writer.followRemovals { Set(accounts.connections.map(\.id)) }
        }
        // TODO(#56): call `writer.follow(_:)` with the app's `PlayerViewModel` once the player UI
        // composes it; `player` is still a placeholder, so nothing writes a snapshot yet.
        return writer
    }
}
