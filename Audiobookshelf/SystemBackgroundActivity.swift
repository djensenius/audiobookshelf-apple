import ABSCore
import ABSPlayback
import Foundation

#if os(iOS)
    import UIKit
#endif

/// The system's background-task calls ``SystemBackgroundActivity`` makes; tests pass a fake.
@MainActor
struct BackgroundTasks {
    /// Asks for background time named `name`. Returns the grant's identifier, or `nil` when the
    /// system grants none. The system calls the handler on the main thread when the time runs
    /// out; the grant must then be ended at once.
    var begin: @MainActor (_ name: String, _ expiration: @escaping @MainActor @Sendable () -> Void) -> Int?
    /// Ends a grant ``begin`` returned.
    var end: @MainActor (Int) -> Void

    #if os(iOS)
        /// `UIApplication`'s background tasks.
        static var application: BackgroundTasks {
            BackgroundTasks(
                begin: { name, expiration in
                    let identifier = UIApplication.shared.beginBackgroundTask(withName: name) {
                        MainActor.assumeIsolated { expiration() }
                    }
                    return identifier == .invalid ? nil : identifier.rawValue
                },
                end: { UIApplication.shared.endBackgroundTask(UIBackgroundTaskIdentifier(rawValue: $0)) })
        }
    #endif
}

/// Keeps the app running while an auto-advance starts the next item with no audio playing
/// (#160), backed by `UIApplication.beginBackgroundTask` on iOS (``BackgroundTasks``).
///
/// Each ``begin(name:)`` holds one grant until its ``end(_:)``, or until the system's time runs
/// out: the expiration handler ends the grant itself, as iOS requires, and the caller's later
/// `end` does nothing. A `begin` the system refuses holds nothing.
@MainActor
final class SystemBackgroundActivity: BackgroundActivity {
    private let tasks: BackgroundTasks
    private var grants: [BackgroundActivityToken: Int] = [:]

    init(tasks: BackgroundTasks) {
        self.tasks = tasks
    }

    /// Grants held and not yet ended (tests).
    var heldCount: Int { grants.count }

    func begin(name: String) -> BackgroundActivityToken {
        let token = BackgroundActivityToken()
        let grant = tasks.begin(name) { [weak self] in
            Log.playback.notice("Background time ran out: \(name, privacy: .public)")
            self?.end(token)
        }
        if let grant { grants[token] = grant }
        return token
    }

    func end(_ token: BackgroundActivityToken) {
        guard let grant = grants.removeValue(forKey: token) else { return }
        tasks.end(grant)
    }
}

extension AppPlayback {
    /// The background activity each scope's coordinator holds around an auto-advance: the
    /// system's background tasks on iOS. The Mac doesn't suspend the app, so it holds nothing.
    static func makeBackgroundActivity() -> any BackgroundActivity {
        #if os(iOS)
            SystemBackgroundActivity(tasks: .application)
        #else
            NoBackgroundActivity()
        #endif
    }
}
