import ABSAppModel
import ABSCore
import Foundation
import Synchronization

#if canImport(UIKit)
    import UIKit
#endif

/// The cover image pipeline shared by every scene, and what keeps it in step with the session
/// and the system (#182, ADR 0005).
///
/// ``participant`` is a ``SessionStage/connect`` participant: it installs the session's request
/// builder, removes it when the session ends, and deletes a server's covers once the server is
/// removed. ``trimmer`` trims the memory cache on memory warnings (iOS) or memory pressure
/// (macOS), and when the app enters the background on iOS.
///
/// Disk maintenance (#143, #421) runs at `.background` priority, so it doesn't hold up the
/// first frame: at launch it deletes the covers of connections removed in an earlier launch,
/// then runs a full pass of the cover file store, and every time the app enters the
/// background it runs another pass. The app registers no `BGTaskScheduler` tasks, so this
/// doesn't add one: on iOS the background pass asks for a little background time instead. At
/// most one maintenance run is in flight, and the store joins concurrent passes into one.
@MainActor
final class ImageServices {
    let pipeline: ImagePipeline
    let participant: ImageParticipant
    /// Called by the system's memory events, on whatever thread they arrive.
    nonisolated let trimmer: MemoryTrimmer
    private let fileStore: CoverFileStore
    /// The running disk maintenance, so another isn't started meanwhile.
    private var maintenance: Task<Void, Never>?
    #if os(iOS)
        private var maintenanceTime = UIBackgroundTaskIdentifier.invalid
    #endif
    private let network = NetworkMonitor()
    private let online = OnlineFlag()
    private var networkTask: Task<Void, Never>?
    #if os(iOS)
        private let notifications: NotificationCenter
        private var memoryWarnings: (any NSObjectProtocol)?
    #elseif os(macOS)
        private var memoryPressure: (any DispatchSourceMemoryPressure)?
    #endif

    /// - Parameter trim: Trims the memory cache to a fraction of its cap; tests record it. By
    ///   default, ``pipeline``'s ``ImagePipeline/trimMemory(toFraction:)``.
    /// - Parameter notifications: Where memory warnings arrive on iOS; tests pass their own, so
    ///   one test's warning doesn't reach another's services.
    init(
        accounts: AccountManager?,
        trim: (@Sendable (_ fraction: Double) async -> Void)? = nil,
        notifications: NotificationCenter = .default
    ) {
        let limits = Self.limits
        let online = self.online
        let fileStore = CoverFileStore(directory: CoverFileStore.defaultDirectory(), limit: limits.diskBytes)
        self.fileStore = fileStore
        let pipeline = ImagePipeline(
            limits: limits,
            fileStore: fileStore,
            // TODO(#143): pass the downloads' `DownloadedCoverLookup`, so downloaded items' covers
            // load from their files.
            downloadedCovers: nil,
            isOnline: { online.isOnline })
        self.pipeline = pipeline
        participant = ImageParticipant(sink: pipeline)
        trimmer = MemoryTrimmer(trim: trim ?? { await pipeline.trimMemory(toFraction: $0) })
        #if os(iOS)
            self.notifications = notifications
        #endif
        if let accounts {
            participant.followRemovals { Set(accounts.connections.map(\.id)) }
        }
        followNetwork()
        #if os(iOS)
            memoryWarnings = Self.observeMemoryWarnings(in: notifications, calling: trimmer)
        #elseif os(macOS)
            memoryPressure = Self.observeMemoryPressure(calling: trimmer)
        #endif
        maintainDisk(sweepingRemovalsOf: accounts, inBackground: false)
    }

    isolated deinit {
        networkTask?.cancel()
        #if os(iOS)
            if let memoryWarnings { notifications.removeObserver(memoryWarnings) }
        #elseif os(macOS)
            memoryPressure?.cancel()
        #endif
    }

    /// Keeps a quarter of the memory cache once every scene is in the background. Not on macOS,
    /// where apps keep running in the background and memory pressure trims instead.
    func didEnterBackground() {
        #if os(iOS)
            trimmer.didEnterBackground()
        #endif
        maintainDisk(sweepingRemovalsOf: nil, inBackground: true)
    }

    /// Runs a full pass of the cover file store at `.background` priority, after deleting the
    /// covers of connections `accounts` no longer saves, unless a run is already in flight.
    private func maintainDisk(sweepingRemovalsOf accounts: AccountManager?, inBackground: Bool) {
        #if os(iOS)
            // Background time, so the run (this one, or the launch run still in flight) can
            // finish once the app is in the background; it is redone by the next launch or
            // background entry if the system suspends it anyway. Ended when the run finishes.
            if inBackground, maintenanceTime == .invalid {
                maintenanceTime = UIApplication.shared.beginBackgroundTask(withName: "Cover cache maintenance") {
                    [weak self] in self?.endMaintenanceTime()
                }
            }
        #endif
        guard maintenance == nil else { return }
        let (participant, fileStore) = (self.participant, self.fileStore)
        maintenance = Task(priority: .background) { [weak self] in
            if let accounts {
                await participant.sweepRemovedConnections { await accounts.savedConnectionIDs() }
            }
            await fileStore.fullPass()
            self?.maintenance = nil
            self?.endMaintenanceTime()
        }
    }

    private func endMaintenanceTime() {
        #if os(iOS)
            guard maintenanceTime != .invalid else { return }
            UIApplication.shared.endBackgroundTask(maintenanceTime)
            maintenanceTime = .invalid
        #endif
    }

    private static var limits: ImageCacheLimits {
        #if os(macOS)
            .mac
        #else
            UIDevice.current.userInterfaceIdiom == .pad ? .iPad : .iPhone
        #endif
    }

    /// Mirrors the monitor into ``online``, which the pipeline reads from any thread.
    private func followNetwork() {
        let paths = network.paths()
        let online = self.online
        networkTask = Task {
            for await path in paths { online.isOnline = path.isOnline }
        }
        network.start()
    }

    // Not isolated, so the handlers they make don't inherit the main actor: the system calls them
    // on other threads, where Swift 6's isolation check would trap.

    #if os(iOS)
        private nonisolated static func observeMemoryWarnings(
            in notifications: NotificationCenter, calling trimmer: MemoryTrimmer
        ) -> any NSObjectProtocol {
            notifications.addObserver(
                forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: nil
            ) { _ in trimmer.memoryWarning() }
        }
    #elseif os(macOS)
        private nonisolated static func observeMemoryPressure(
            calling trimmer: MemoryTrimmer
        ) -> any DispatchSourceMemoryPressure {
            let source = DispatchSource.makeMemoryPressureSource(
                eventMask: [.warning, .critical], queue: .global(qos: .utility))
            source.setEventHandler(
                handler: memoryPressureHandler(event: { [weak source] in source?.data }, calling: trimmer))
            source.activate()
            return source
        }

        /// The pressure source's event handler, which runs on the source's queue.
        nonisolated static func memoryPressureHandler(
            event: @escaping @Sendable () -> DispatchSource.MemoryPressureEvent?, calling trimmer: MemoryTrimmer
        ) -> @Sendable () -> Void {
            {
                guard let event = event() else { return }
                trimmer.memoryPressure(event)
            }
        }
    #endif
}

/// Trims the cover memory cache for the system's memory events, from any thread: 0 on a memory
/// warning or critical pressure, 0.5 on a pressure warning, 0.25 in the background (the fractions
/// `ImagePipeline.trimMemory(toFraction:)` documents).
struct MemoryTrimmer: Sendable {
    let trim: @Sendable (_ fraction: Double) async -> Void

    func memoryWarning() {
        Task { await trim(0) }
    }

    func memoryPressure(_ event: DispatchSource.MemoryPressureEvent) {
        let fraction = event.contains(.critical) ? 0 : 0.5
        Task { await trim(fraction) }
    }

    func didEnterBackground() {
        Task { await trim(0.25) }
    }
}

/// Whether the network is reachable, readable from any thread; `true` until the monitor knows.
private final class OnlineFlag: Sendable {
    private let state = Mutex(true)

    var isOnline: Bool {
        get { state.withLock { $0 } }
        set { state.withLock { $0 = newValue } }
    }
}
