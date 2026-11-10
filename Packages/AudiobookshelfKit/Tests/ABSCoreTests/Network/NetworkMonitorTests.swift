import Network
import Observation
import Synchronization
import Testing

@testable import ABSCore

/// A path source driven by the test. Each `paths()` call opens a new stream.
final class FakeNetworkPathSource: NetworkPathSource {
    private let continuations = Mutex<[AsyncStream<NetworkPath>.Continuation]>([])
    private let terminationContinuation: AsyncStream<Void>.Continuation
    /// Yields once each time a stream returned by `paths()` terminates.
    let terminations: AsyncStream<Void>

    init() {
        (terminations, terminationContinuation) = AsyncStream.makeStream()
    }

    var openedStreams: Int { continuations.withLock { $0.count } }

    func paths() -> AsyncStream<NetworkPath> {
        let (stream, continuation) = AsyncStream.makeStream(of: NetworkPath.self)
        continuation.onTermination = { [terminationContinuation] _ in terminationContinuation.yield() }
        continuations.withLock { $0.append(continuation) }
        return stream
    }

    /// Sends `path` on every open stream.
    func send(_ path: NetworkPath) {
        for continuation in continuations.withLock({ $0 }) {
            continuation.yield(path)
        }
    }

    /// Ends the most recent stream, as if the system stopped monitoring.
    func finishLatest() {
        continuations.withLock { $0.last }?.finish()
    }
}

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct NetworkMonitorTests {
    @Test func pathIsUnknownUntilTheSourceReports() {
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

    @Test func slowSubscriberGetsTheLatestPath() async {
        let source = FakeNetworkPathSource()
        let monitor = NetworkMonitor(source: source)
        monitor.start()
        var fast = monitor.paths().makeAsyncIterator()
        var slow = monitor.paths().makeAsyncIterator()

        source.send(.wifi)
        #expect(await fast.next() == .wifi)
        source.send(.cellular)
        #expect(await fast.next() == .cellular)
        source.send(.wired)
        #expect(await fast.next() == .wired)

        #expect(await slow.next() == .wired)
    }

    @Test func subscriberBeforeStartReceivesTheFirstPath() async {
        let source = FakeNetworkPathSource()
        let monitor = NetworkMonitor(source: source)
        var updates = monitor.paths().makeAsyncIterator()

        monitor.start()
        source.send(.wifi)
        #expect(await updates.next() == .wifi)
    }

    @Test func subscribeStopStartStillReceives() async {
        let source = FakeNetworkPathSource()
        let monitor = NetworkMonitor(source: source)
        var updates = monitor.paths().makeAsyncIterator()
        monitor.start()
        source.send(.wifi)
        #expect(await updates.next() == .wifi)

        monitor.stop()
        monitor.start()
        source.send(.cellular)
        #expect(await updates.next() == .cellular)
    }

    @Test func subscriberAfterStopGetsTheLastPathAndLaterUpdates() async {
        let source = FakeNetworkPathSource()
        let monitor = NetworkMonitor(source: source)
        monitor.start()
        var first = monitor.paths().makeAsyncIterator()
        source.send(.wifi)
        #expect(await first.next() == .wifi)
        monitor.stop()

        var updates = monitor.paths().makeAsyncIterator()
        #expect(await updates.next() == .wifi)
        monitor.start()
        source.send(.cellular)
        #expect(await updates.next() == .cellular)
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
        #expect(monitor.subscriberCount == 1)
        #expect(monitor.isRunning)

        source.send(.wired)
        #expect(await kept.next() == .wired)
    }

    @Test func stopCancelsTheSourceAndKeepsSubscribers() async {
        let source = FakeNetworkPathSource()
        let monitor = NetworkMonitor(source: source)
        var terminations = source.terminations.makeAsyncIterator()
        monitor.start()
        var updates = monitor.paths().makeAsyncIterator()
        source.send(.wifi)
        #expect(await updates.next() == .wifi)

        monitor.stop()
        #expect(await terminations.next() != nil)
        #expect(!monitor.isRunning)
        #expect(monitor.path == .wifi)
        #expect(monitor.subscriberCount == 1)
    }

    @Test func anEarlierRunEndingDoesNotStopARestartedMonitor() async {
        let source = FakeNetworkPathSource()
        let monitor = NetworkMonitor(source: source)
        monitor.start()
        let firstRun = monitor.task
        monitor.stop()
        monitor.start()
        #expect(source.openedStreams == 2)

        await firstRun?.value
        #expect(monitor.isRunning)
        #expect(monitor.task != nil)

        var updates = monitor.paths().makeAsyncIterator()
        source.send(.cellular)
        #expect(await updates.next() == .cellular)
    }

    @Test func sourceEndingClearsThePathAndKeepsSubscribers() async {
        let source = FakeNetworkPathSource()
        let monitor = NetworkMonitor(source: source)
        monitor.start()
        var updates = monitor.paths().makeAsyncIterator()
        source.send(.wifi)
        #expect(await updates.next() == .wifi)

        let run = monitor.task
        source.finishLatest()
        await run?.value
        #expect(!monitor.isRunning)
        #expect(monitor.path == nil)
        #expect(monitor.subscriberCount == 1)

        monitor.start()
        source.send(.cellular)
        #expect(await updates.next() == .cellular)
    }

    @Test func deallocationFinishesSubscribersAndCancelsTheSource() async {
        let source = FakeNetworkPathSource()
        var terminations = source.terminations.makeAsyncIterator()
        var updates = { () -> AsyncStream<NetworkPath>.Iterator in
            let monitor = NetworkMonitor(source: source)
            monitor.start()
            return monitor.paths().makeAsyncIterator()
        }()

        #expect(await updates.next(isolation: #isolation) == nil)
        #expect(await terminations.next() != nil)
    }

    @Test func currentPathReturnsAKnownPathAtOnce() async {
        let source = FakeNetworkPathSource()
        let monitor = NetworkMonitor(source: source)
        monitor.start()
        var updates = monitor.paths().makeAsyncIterator()
        source.send(.wired)
        #expect(await updates.next() == .wired)

        #expect(await monitor.currentPath(timeout: .zero) == .wired)
    }

    @Test func currentPathWaitsForTheFirstPath() async {
        let source = FakeNetworkPathSource()
        let monitor = NetworkMonitor(source: source)
        monitor.start()
        let waiter = Task { await monitor.currentPath(timeout: .seconds(3600)) }
        source.send(.cellular)
        #expect(await waiter.value == .cellular)
    }

    @Test func currentPathTimesOutWithoutAPath() async {
        let source = FakeNetworkPathSource()
        let monitor = NetworkMonitor(source: source)
        monitor.start()
        #expect(await monitor.currentPath(timeout: .zero) == nil)
        #expect(monitor.subscriberCount == 0)
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
