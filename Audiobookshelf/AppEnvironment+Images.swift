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
/// builder, rebuilds it when the active connection changes, removes it when the session ends, and
/// deletes a server's covers once the server is removed. The pipeline trims its memory cache on
/// memory warnings (iOS) or memory pressure (macOS), and ``didEnterBackground()`` trims it on iOS.
@MainActor
final class ImageServices {
    let pipeline: ImagePipeline
    let participant: ImageParticipant
    private let network = NetworkMonitor()
    private let online = OnlineFlag()
    private var networkTask: Task<Void, Never>?
    private var memoryWarnings: (any NSObjectProtocol)?
    #if os(macOS)
        private var memoryPressure: (any DispatchSourceMemoryPressure)?
    #endif

    init(accounts: AccountManager?) {
        let limits = Self.limits
        let online = self.online
        pipeline = ImagePipeline(
            limits: limits,
            fileStore: CoverFileStore(directory: CoverFileStore.defaultDirectory(), limit: limits.diskBytes),
            // TODO(#143): pass the downloads' `DownloadedCoverLookup`, so downloaded items' covers
            // load from their files.
            downloadedCovers: nil,
            isOnline: { online.isOnline })
        participant = ImageParticipant(sink: pipeline, activeConnection: { accounts?.activeConnection })
        if let accounts {
            participant.followRemovals { Set(accounts.connections.map(\.id)) }
        }
        followNetwork()
        trimOnMemoryWarnings()
    }

    isolated deinit {
        networkTask?.cancel()
        if let memoryWarnings { NotificationCenter.default.removeObserver(memoryWarnings) }
        #if os(macOS)
            memoryPressure?.cancel()
        #endif
    }

    /// Keeps a quarter of the memory cache once every scene is in the background. Not on macOS,
    /// where apps keep running in the background and memory pressure trims instead.
    func didEnterBackground() {
        #if os(iOS)
            Task { [pipeline] in await pipeline.trimMemory(toFraction: 0.25) }
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

    private func trimOnMemoryWarnings() {
        let pipeline = self.pipeline
        #if os(iOS)
            memoryWarnings = NotificationCenter.default.addObserver(
                forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: nil
            ) { _ in
                Task { await pipeline.trimMemory(toFraction: 0) }
            }
        #elseif os(macOS)
            let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical])
            source.setEventHandler { [weak source] in
                let fraction = source?.data.contains(.critical) == true ? 0 : 0.5
                Task { await pipeline.trimMemory(toFraction: fraction) }
            }
            source.activate()
            memoryPressure = source
        #endif
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
