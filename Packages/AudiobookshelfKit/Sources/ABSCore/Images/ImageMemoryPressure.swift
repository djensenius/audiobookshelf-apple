import Foundation

#if canImport(UIKit)
    import UIKit
#endif

extension ImageCacheLimits {
    /// The limits for this device: iPhone, iPad, or Mac.
    @MainActor public static var current: ImageCacheLimits {
        #if os(macOS)
            .mac
        #else
            UIDevice.current.userInterfaceIdiom == .pad ? .iPad : .iPhone
        #endif
    }
}

/// Trims an ``ImagePipeline``'s memory LRU under memory pressure (ADR 0005): on iOS it empties
/// it on a memory warning and trims it to 25 % in the background; on macOS a pressure warning
/// trims it to 50 % and a critical event empties it. Keep it alive as long as the pipeline.
@MainActor public final class ImageMemoryPressureObserver {
    #if os(macOS)
        private let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
    #else
        private var observers: [any NSObjectProtocol] = []
    #endif

    public init(pipeline: ImagePipeline) {
        #if os(macOS)
            source.setEventHandler { [weak source] in
                guard let event = source?.data else { return }
                let fraction = event.contains(.critical) ? 0 : 0.5
                Task { await pipeline.trimMemory(toFraction: fraction) }
            }
            source.activate()
        #else
            let center = NotificationCenter.default
            let events: [(Notification.Name, Double)] = [
                (UIApplication.didReceiveMemoryWarningNotification, 0),
                (UIApplication.didEnterBackgroundNotification, 0.25),
            ]
            observers = events.map { name, fraction in
                center.addObserver(forName: name, object: nil, queue: .main) { _ in
                    Task { await pipeline.trimMemory(toFraction: fraction) }
                }
            }
        #endif
    }

    isolated deinit {
        #if os(macOS)
            source.cancel()
        #else
            observers.forEach(NotificationCenter.default.removeObserver)
        #endif
    }
}
