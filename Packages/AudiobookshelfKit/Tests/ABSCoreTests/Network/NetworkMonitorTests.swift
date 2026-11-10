import Network
import Observation
import Synchronization
import Testing

@testable import ABSCore

/// A path source driven by the test. Each `paths()` call opens a new stream.
final class FakeNetworkPathSource: NetworkPathSource {
    private let continuations = Mutex<[AsyncStream<NetworkPath>.Continuation]>([])
    private let terminations = Mutex(0)

    var openedStreams: Int { continuations.withLock { $0.count } }
    var terminatedStreams: Int { terminations.withLock { $0 } }

    func paths() -> AsyncStream<NetworkPath> {
        let (stream, continuation) = AsyncStream.makeStream(of: NetworkPath.self)
        continuation.onTermination = { [weak self] _ in self?.terminations.withLock { $0 += 1 } }
        continuations.withLock { $0.append(continuation) }
        return stream
    }

    func send(_ path: NetworkPath) {
        for continuation in continuations.withLock({ $0 }) {
            continuation.yield(path)
        }
    }

    func finish() {
        for continuation in continuations.withLock({ $0 }) {
            continuation.finish()
        }
    }
}

/// Polls `condition` on the main actor until it holds or about two seconds pass.
@MainActor
private func eventually(_ condition: () -> Bool) async -> Bool {
    for _ in 0..<200 {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}

@MainActor
@Suite struct NetworkMonitorTests {
    @Test func pathIsUnknownUntilTheSourceReports() async {
        let source = FakeNetworkPathSource()
        let monitor = NetworkMonitor(source: source)
        #expect(monitor.path == nil)
        #expect(monitor.isOnline)
        #expect(!monitor.isRunning)
        #expect(source.openedStreams == 0)

        monitor.start()
        #expect(monitor.isRunning)
        #expect(source.openedStreams == 1)
        monitor.start()
        #expect(source.openedStreams == 1)
    }

    @Test func streamEmitsAndObservablePathUpdates() async {
        let source = FakeNetworkPathSource()
        let monitor = NetworkMonitor(source: source)
        monitor.start()
        var updates = monitor.paths().makeAsyncIterator()

        let changed = Flag()
        withObservationTracking({ _ = monitor.path }, onChange: { changed.set() })
        source.send(.wifi)
        #expect(await updates.next() == .wifi)
        #expect(monitor.path == .wifi)
        #expect(changed.isSet)

        source.send(.offline)
        #expect(await updates.next() == .offline)
        #expect(monitor.path == .offline)
        #expect(!monitor.isOnline)
    }

    @Test func dropsRepeatedPaths() async {
        let source = FakeNetworkPathSource()
        let monitor = NetworkMonitor(source: source)
        monitor.start()
        var updates = monitor.paths().makeAsyncIterator()

        source.send(.wifi)
        #expect(await updates.next() == .wifi)
        source.send(.wifi)
        source.send(.cellular)
        #expect(await updates.next() == .cellular)
    }

    @Test func everySubscriberReceivesUpdatesAndLateSubscribersGetTheCurrentPath() async {
        let source = FakeNetworkPathSource()
        let monitor = NetworkMonitor(source: source)
        monitor.start()
        var first = monitor.paths().makeAsyncIterator()
        var second = monitor.paths().makeAsyncIterator()

        source.send(.wifi)
        #expect(await first.next() == .wifi)
        #expect(await second.next() == .wifi)

        var late = monitor.paths().makeAsyncIterator()
        #expect(await late.next() == .wifi)

        source.send(.cellular)
        #expect(await first.next() == .cellular)
        #expect(await second.next() == .cellular)
        #expect(await late.next() == .cellular)
        #expect(source.openedStreams == 1)
    }

    @Test func cancellingASubscriberRemovesItOnly() async {
        let source = FakeNetworkPathSource()
        let monitor = NetworkMonitor(source: source)
        monitor.start()
        var kept = monitor.paths().makeAsyncIterator()
        let cancelled = monitor.paths()
        let task = Task {
            for await _ in cancelled {}
        }
        #expect(monitor.subscriberCount == 2)

        task.cancel()
        await task.value
        #expect(await eventually { monitor.subscriberCount == 1 })
        #expect(monitor.isRunning)

        source.send(.wired)
        #expect(await kept.next() == .wired)
    }

    @Test func stopFinishesSubscribersAndCancelsTheSource() async {
        let source = FakeNetworkPathSource()
        let monitor = NetworkMonitor(source: source)
        monitor.start()
        var updates = monitor.paths().makeAsyncIterator()
        source.send(.wifi)
        #expect(await updates.next() == .wifi)

        monitor.stop()
        #expect(await updates.next() == nil)
        #expect(!monitor.isRunning)
        #expect(monitor.path == .wifi)
        #expect(monitor.subscriberCount == 0)
        #expect(await eventually { source.terminatedStreams == 1 })
    }

    @Test func restartsAfterStop() async {
        let source = FakeNetworkPathSource()
        let monitor = NetworkMonitor(source: source)
        monitor.start()
        monitor.stop()
        monitor.start()
        #expect(monitor.isRunning)
        #expect(source.openedStreams == 2)

        var updates = monitor.paths().makeAsyncIterator()
        source.send(.cellular)
        #expect(await updates.next() == .cellular)
        // The first run's task must not stop the second run when it winds down.
        try? await Task.sleep(for: .milliseconds(20))
        #expect(monitor.isRunning)
    }

    @Test func sourceEndingFinishesSubscribers() async {
        let source = FakeNetworkPathSource()
        let monitor = NetworkMonitor(source: source)
        monitor.start()
        var updates = monitor.paths().makeAsyncIterator()

        source.finish()
        #expect(await updates.next() == nil)
        #expect(await eventually { !monitor.isRunning })
    }

    @Test func deallocationFinishesSubscribers() async {
        let source = FakeNetworkPathSource()
        var updates = { () -> AsyncStream<NetworkPath>.Iterator in
            let monitor = NetworkMonitor(source: source)
            monitor.start()
            return monitor.paths().makeAsyncIterator()
        }()

        #expect(await updates.next(isolation: #isolation) == nil)
        #expect(await eventually { source.terminatedStreams == 1 })
    }
}

@Suite struct NetworkPathTests {
    @Test(arguments: [
        (NWInterface.InterfaceType.wifi, NetworkInterface.wifi),
        (.wiredEthernet, .wired),
        (.cellular, .cellular),
        (.loopback, .other),
        (.other, .other),
    ])
    func mapsInterfaceTypes(type: NWInterface.InterfaceType, expected: NetworkInterface) {
        let path = NetworkPath(
            status: .satisfied, isExpensive: false, isConstrained: false, usesInterfaceType: { $0 == type })
        #expect(path.interface == expected)
        #expect(path.isOnline)
    }

    @Test func requiresConnectionIsOnlineAndUnsatisfiedIsOffline() {
        let pending = NetworkPath(
            status: .requiresConnection, isExpensive: true, isConstrained: true, usesInterfaceType: { $0 == .cellular }
        )
        #expect(pending == NetworkPath(isOnline: true, isExpensive: true, isConstrained: true, interface: .cellular))

        let offline = NetworkPath(
            status: .unsatisfied, isExpensive: false, isConstrained: false, usesInterfaceType: { _ in false })
        #expect(offline == .offline)
    }
}

/// A Sendable flag set from an observation `onChange` handler.
private final class Flag: Sendable {
    private let storage = Mutex(false)
    var isSet: Bool { storage.withLock { $0 } }
    func set() { storage.withLock { $0 = true } }
}
