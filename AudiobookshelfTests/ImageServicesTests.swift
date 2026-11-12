import Foundation
import Synchronization
import Testing

@testable import Audiobookshelf

#if canImport(UIKit)
    import UIKit
#endif

/// The fractions trimmed, in order.
private final class TrimLog: Sendable {
    private let fractions = Mutex<[Double]>([])

    var all: [Double] { fractions.withLock { $0 } }

    func record(_ fraction: Double) { fractions.withLock { $0.append(fraction) } }
}

@MainActor
@Suite struct ImageServicesTests {
    /// Services that record their trims in `log`. Each gets its own notification center, so a
    /// memory warning one test posts doesn't reach another's services while they run in parallel.
    private func makeServices(
        logging log: TrimLog, notifications: NotificationCenter = NotificationCenter()
    ) -> ImageServices {
        ImageServices(accounts: nil, trim: { log.record($0) }, notifications: notifications)
    }

    /// Runs `body` on a background queue, as the system delivers memory events.
    private func onBackgroundQueue(_ body: @escaping @Sendable () -> Void) async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                body()
                continuation.resume()
            }
        }
    }

    private func waitFor(_ log: TrimLog, count: Int) async -> Bool {
        for _ in 0..<2_000 where log.all.count < count {
            try? await Task.sleep(for: .milliseconds(1))
        }
        return log.all.count == count
    }

    @Test func memoryEventsTrimFromABackgroundQueue() async {
        let log = TrimLog()
        let services = makeServices(logging: log)
        let trimmer = services.trimmer

        await onBackgroundQueue {
            trimmer.memoryWarning()
            trimmer.memoryPressure(.warning)
            trimmer.memoryPressure([.warning, .critical])
        }

        #expect(await waitFor(log, count: 3))
        #expect(log.all.sorted() == [0, 0, 0.5])
    }

    #if os(macOS)
        @Test func thePressureSourcesHandlerTrimsOffTheMainThread() async {
            let log = TrimLog()
            let services = makeServices(logging: log)
            let warning = ImageServices.memoryPressureHandler(event: { .warning }, calling: services.trimmer)
            let critical = ImageServices.memoryPressureHandler(event: { .critical }, calling: services.trimmer)
            let released = ImageServices.memoryPressureHandler(event: { nil }, calling: services.trimmer)

            await onBackgroundQueue {
                warning()
                critical()
                released()
            }

            #expect(await waitFor(log, count: 2))
            #expect(log.all.sorted() == [0, 0.5])
        }
    #endif

    #if os(iOS)
        @Test func aMemoryWarningPostedOffTheMainThreadEmptiesTheCache() async {
            let log = TrimLog()
            let notifications = NotificationCenter()
            let services = makeServices(logging: log, notifications: notifications)

            await onBackgroundQueue {
                notifications.post(name: UIApplication.didReceiveMemoryWarningNotification, object: nil)
            }

            #expect(await waitFor(log, count: 1))
            #expect(log.all == [0])
            withExtendedLifetime(services) {}
        }

        @Test func enteringTheBackgroundKeepsAQuarter() async {
            let log = TrimLog()
            let services = makeServices(logging: log)

            services.didEnterBackground()

            #expect(await waitFor(log, count: 1))
            #expect(log.all == [0.25])
        }
    #endif
}
