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
        let services = ImageServices(accounts: nil, trim: { log.record($0) })
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
            let services = ImageServices(accounts: nil, trim: { log.record($0) })
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
            let services = ImageServices(accounts: nil, trim: { log.record($0) })

            await onBackgroundQueue {
                NotificationCenter.default.post(name: UIApplication.didReceiveMemoryWarningNotification, object: nil)
            }

            #expect(await waitFor(log, count: 1))
            #expect(log.all == [0])
            withExtendedLifetime(services) {}
        }

        @Test func enteringTheBackgroundKeepsAQuarter() async {
            let log = TrimLog()
            let services = ImageServices(accounts: nil, trim: { log.record($0) })

            services.didEnterBackground()

            #expect(await waitFor(log, count: 1))
            #expect(log.all == [0.25])
        }
    #endif
}
