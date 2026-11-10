import Foundation
import Testing

@testable import ABSCore

@Suite struct NetworkPolicyTableTests {
    struct Case: Sendable, CustomTestStringConvertible {
        let name: String
        let path: NetworkPath?
        let treatsExpensiveAsCellular: Bool
        /// Why the path is metered, or `nil` if it is always allowed.
        let reason: MeteredReason?

        var testDescription: String { name }
    }

    static let hotspot = NetworkPath(isOnline: true, isExpensive: true, interface: .wifi)
    static let lowDataWifi = NetworkPath(isOnline: true, isConstrained: true, interface: .wifi)
    static let other = NetworkPath(isOnline: true, interface: .other)
    static let expensiveOther = NetworkPath(isOnline: true, isExpensive: true, interface: .other)
    static let expensiveWired = NetworkPath(isOnline: true, isExpensive: true, interface: .wired)
    static let offlineFlagged = NetworkPath(isOnline: false, isExpensive: true, isConstrained: true, interface: nil)

    static let paths: [Case] = [
        Case(name: "unknown", path: nil, treatsExpensiveAsCellular: false, reason: nil),
        Case(name: "offline", path: .offline, treatsExpensiveAsCellular: false, reason: nil),
        Case(name: "mac offline", path: .offline, treatsExpensiveAsCellular: true, reason: nil),
        Case(name: "offline with stale flags", path: offlineFlagged, treatsExpensiveAsCellular: true, reason: nil),
        Case(name: "wifi", path: .wifi, treatsExpensiveAsCellular: false, reason: nil),
        Case(name: "mac wifi", path: .wifi, treatsExpensiveAsCellular: true, reason: nil),
        Case(name: "wired", path: .wired, treatsExpensiveAsCellular: false, reason: nil),
        Case(name: "mac wired", path: .wired, treatsExpensiveAsCellular: true, reason: nil),
        Case(name: "other", path: other, treatsExpensiveAsCellular: false, reason: nil),
        Case(name: "mac other", path: other, treatsExpensiveAsCellular: true, reason: nil),
        Case(name: "cellular", path: .cellular, treatsExpensiveAsCellular: false, reason: .cellular),
        Case(
            name: "inexpensive cellular", path: NetworkPath(isOnline: true, interface: .cellular),
            treatsExpensiveAsCellular: false, reason: .cellular),
        Case(name: "ios hotspot", path: hotspot, treatsExpensiveAsCellular: false, reason: nil),
        Case(name: "mac hotspot", path: hotspot, treatsExpensiveAsCellular: true, reason: .expensive),
        Case(name: "ios expensive other", path: expensiveOther, treatsExpensiveAsCellular: false, reason: .expensive),
        Case(name: "mac expensive other", path: expensiveOther, treatsExpensiveAsCellular: true, reason: .expensive),
        Case(name: "ios expensive wired", path: expensiveWired, treatsExpensiveAsCellular: false, reason: .expensive),
        Case(name: "mac expensive wired", path: expensiveWired, treatsExpensiveAsCellular: true, reason: .expensive),
        Case(name: "low data wifi", path: lowDataWifi, treatsExpensiveAsCellular: false, reason: .lowDataMode),
        Case(
            name: "low data cellular",
            path: NetworkPath(isOnline: true, isExpensive: true, isConstrained: true, interface: .cellular),
            treatsExpensiveAsCellular: false, reason: .cellular),
        Case(
            name: "low data hotspot",
            path: NetworkPath(isOnline: true, isExpensive: true, isConstrained: true, interface: .wifi),
            treatsExpensiveAsCellular: true, reason: .lowDataMode),
    ]

    @Test(arguments: paths, CellularPolicy.allCases)
    func decision(_ testCase: Case, policy: CellularPolicy) {
        let expected: NetworkDecision =
            switch (testCase.reason, policy) {
            case (nil, _), (_, .always): .allowed
            case (let reason?, .ask): .askUser(reason)
            case (let reason?, .never): .denied(reason)
            }
        let decision = NetworkPolicy.decision(
            for: testCase.path, cellularPolicy: policy, treatsExpensiveAsCellular: testCase.treatsExpensiveAsCellular)
        #expect(decision == expected)
    }

    @Test func expensiveWifiIsCellularOnlyOnMacOS() {
        #if os(macOS)
            #expect(NetworkPolicy.treatsExpensiveAsCellularByDefault)
            #expect(NetworkPolicy.decision(for: Self.hotspot, cellularPolicy: .never) == .denied(.expensive))
        #else
            #expect(!NetworkPolicy.treatsExpensiveAsCellularByDefault)
            #expect(NetworkPolicy.decision(for: Self.hotspot, cellularPolicy: .never) == .allowed)
        #endif
    }
}

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct NetworkPolicyTests {
    private func makeSettings(stream: CellularPolicy, download: CellularPolicy) throws -> (AppSettings, () -> Void) {
        let suiteName = "ABSCoreTests.NetworkPolicy.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        let settings = AppSettings(defaults: defaults)
        settings.streamingUsingCellular = stream
        settings.downloadUsingCellular = download
        return (settings, { defaults.removePersistentDomain(forName: suiteName) })
    }

    @Test func streamAndDownloadUseTheirOwnSettings() async throws {
        let (settings, cleanUp) = try makeSettings(stream: .ask, download: .never)
        defer { cleanUp() }
        let source = FakeNetworkPathSource()
        let monitor = NetworkMonitor(source: source)
        let policy = NetworkPolicy(monitor: monitor, settings: settings, treatsExpensiveAsCellular: false)

        monitor.start()
        var updates = monitor.paths().makeAsyncIterator()
        source.send(.cellular)
        _ = await updates.next()
        #expect(policy.canStream() == .askUser(.cellular))
        #expect(policy.canDownload() == .denied(.cellular))

        settings.downloadUsingCellular = .always
        #expect(policy.canDownload() == .allowed)

        source.send(.wifi)
        _ = await updates.next()
        #expect(policy.canStream() == .allowed)

        source.send(.offline)
        _ = await updates.next()
        #expect(policy.canStream() == .allowed)
        #expect(policy.canDownload() == .allowed)
        #expect(!monitor.isOnline)
    }

    /// Pins the unknown-path behaviour under `ask`: the synchronous check allows, the
    /// waiting check decides on the first path, and allows if none arrives in time.
    @Test func unknownPathUnderAsk() async throws {
        let (settings, cleanUp) = try makeSettings(stream: .ask, download: .ask)
        defer { cleanUp() }
        let source = FakeNetworkPathSource()
        let monitor = NetworkMonitor(source: source)
        let policy = NetworkPolicy(monitor: monitor, settings: settings, treatsExpensiveAsCellular: false)
        monitor.start()

        #expect(policy.canStream() == .allowed)
        #expect(policy.canDownload() == .allowed)
        #expect(await policy.canStream(waitingUpTo: .zero) == .allowed)
        #expect(await policy.canDownload(waitingUpTo: .zero) == .allowed)

        let waiting = Task { await policy.canStream(waitingUpTo: .seconds(3600)) }
        source.send(.cellular)
        #expect(await waiting.value == .askUser(.cellular))
        #expect(await policy.canDownload(waitingUpTo: .zero) == .askUser(.cellular))
    }

    /// Wi-Fi, stop, move to cellular, restart: the waiting check must not decide on the
    /// stale Wi-Fi path.
    @Test func restartWaitsForTheNewPathUnderAsk() async throws {
        let (settings, cleanUp) = try makeSettings(stream: .ask, download: .ask)
        defer { cleanUp() }
        let source = FakeNetworkPathSource()
        let monitor = NetworkMonitor(source: source)
        let policy = NetworkPolicy(monitor: monitor, settings: settings, treatsExpensiveAsCellular: false)
        monitor.start()
        var updates = monitor.paths().makeAsyncIterator()
        source.send(.wifi)
        _ = await updates.next()
        #expect(policy.canStream() == .allowed)

        monitor.stop()
        monitor.start()
        let waiting = Task { await policy.canStream(waitingUpTo: .seconds(3600)) }
        source.send(.cellular)
        #expect(await waiting.value == .askUser(.cellular))
        #expect(policy.canDownload() == .askUser(.cellular))
    }
}

@Suite struct NetworkAccessTests {
    @Test(arguments: [
        (CellularPolicy.always, false, NetworkAccess.allowAll),
        (.ask, false, .allowAll),
        (.always, true, .allowAll),
        (.ask, true, .allowAll),
        (.never, false, NetworkAccess(cellular: false, expensive: true, constrained: false)),
        (.never, true, NetworkAccess(cellular: false, expensive: false, constrained: false)),
    ])
    func flagsFollowThePolicy(policy: CellularPolicy, treatsExpensiveAsCellular: Bool, expected: NetworkAccess) {
        #expect(NetworkAccess(policy: policy, treatsExpensiveAsCellular: treatsExpensiveAsCellular) == expected)
    }

    @Test func appliesToConfigurationsAndRequests() throws {
        let access = NetworkAccess(cellular: false, expensive: true, constrained: false)

        let configuration = URLSessionConfiguration.ephemeral
        configuration.apply(access)
        #expect(!configuration.allowsCellularAccess)
        #expect(configuration.allowsExpensiveNetworkAccess)
        #expect(!configuration.allowsConstrainedNetworkAccess)

        var request = URLRequest(url: try #require(URL(string: "https://abs.example.com/api/items")))
        request.apply(access)
        #expect(!request.allowsCellularAccess)
        #expect(request.allowsExpensiveNetworkAccess)
        #expect(!request.allowsConstrainedNetworkAccess)

        request.apply(.allowAll)
        #expect(request.allowsCellularAccess)
        #expect(request.allowsExpensiveNetworkAccess)
        #expect(request.allowsConstrainedNetworkAccess)
    }
}

extension NetworkAccess {
    fileprivate static let allowAll = NetworkAccess(cellular: true, expensive: true, constrained: true)

    fileprivate init(cellular: Bool, expensive: Bool, constrained: Bool) {
        self.init(policy: .always)
        allowsCellularAccess = cellular
        allowsExpensiveNetworkAccess = expensive
        allowsConstrainedNetworkAccess = constrained
    }
}
