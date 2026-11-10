import Foundation
import Testing

@testable import ABSCore

@Suite struct NetworkPolicyTableTests {
    struct Case: Sendable, CustomTestStringConvertible {
        let path: NetworkPath?
        let policy: CellularPolicy
        let treatsExpensiveAsCellular: Bool
        let expected: NetworkDecision
        let name: String

        var testDescription: String { "\(name), \(policy) -> \(expected)" }
    }

    static let hotspot = NetworkPath(isOnline: true, isExpensive: true, interface: .wifi)
    static let lowDataWifi = NetworkPath(isOnline: true, isConstrained: true, interface: .wifi)

    static let cases: [Case] = CellularPolicy.allCases.flatMap { policy -> [Case] in
        let metered: NetworkDecision =
            switch policy {
            case .always: .allowed
            case .ask: .askUser
            case .never: .denied
            }
        return [
            Case(path: .offline, policy: policy, treatsExpensiveAsCellular: false, expected: .denied, name: "offline"),
            Case(
                path: .offline, policy: policy, treatsExpensiveAsCellular: true, expected: .denied, name: "mac offline"),
            Case(path: .wifi, policy: policy, treatsExpensiveAsCellular: false, expected: .allowed, name: "wifi"),
            Case(path: .wifi, policy: policy, treatsExpensiveAsCellular: true, expected: .allowed, name: "mac wifi"),
            Case(path: .wired, policy: policy, treatsExpensiveAsCellular: true, expected: .allowed, name: "mac wired"),
            Case(
                path: .cellular, policy: policy, treatsExpensiveAsCellular: false, expected: metered, name: "cellular"),
            Case(
                path: NetworkPath(isOnline: true, interface: .cellular), policy: policy,
                treatsExpensiveAsCellular: false, expected: metered, name: "inexpensive cellular"),
            Case(
                path: hotspot, policy: policy, treatsExpensiveAsCellular: false, expected: .allowed, name: "ios hotspot"
            ),
            Case(
                path: hotspot, policy: policy, treatsExpensiveAsCellular: true, expected: metered, name: "mac hotspot"),
            Case(
                path: NetworkPath(isOnline: true, isExpensive: true, interface: .wired), policy: policy,
                treatsExpensiveAsCellular: true, expected: metered, name: "mac expensive wired"),
            Case(
                path: lowDataWifi, policy: policy, treatsExpensiveAsCellular: false, expected: metered, name: "low data"
            ),
            Case(path: nil, policy: policy, treatsExpensiveAsCellular: false, expected: .allowed, name: "unknown"),
        ]
    }

    @Test(arguments: cases)
    func decision(_ testCase: Case) {
        let decision = NetworkPolicy.decision(
            for: testCase.path, cellularPolicy: testCase.policy,
            treatsExpensiveAsCellular: testCase.treatsExpensiveAsCellular)
        #expect(decision == testCase.expected)
    }

    @Test func expensivePathsAreCellularOnlyOnMacOS() {
        #if os(macOS)
            #expect(NetworkPolicy.treatsExpensiveAsCellularByDefault)
            #expect(NetworkPolicy.decision(for: Self.hotspot, cellularPolicy: .never) == .denied)
        #else
            #expect(!NetworkPolicy.treatsExpensiveAsCellularByDefault)
            #expect(NetworkPolicy.decision(for: Self.hotspot, cellularPolicy: .never) == .allowed)
        #endif
    }
}

@MainActor
@Suite struct NetworkPolicyTests {
    @Test func streamAndDownloadUseTheirOwnSettings() async throws {
        let suiteName = "ABSCoreTests.NetworkPolicy.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = AppSettings(defaults: defaults)
        settings.streamingUsingCellular = .ask
        settings.downloadUsingCellular = .never

        let source = FakeNetworkPathSource()
        let monitor = NetworkMonitor(source: source)
        let policy = NetworkPolicy(monitor: monitor, settings: settings, treatsExpensiveAsCellular: false)
        #expect(policy.canStream() == .allowed)
        #expect(policy.canDownload() == .allowed)

        monitor.start()
        var updates = monitor.paths().makeAsyncIterator()
        source.send(.cellular)
        _ = await updates.next()
        #expect(policy.canStream() == .askUser)
        #expect(policy.canDownload() == .denied)

        settings.downloadUsingCellular = .always
        #expect(policy.canDownload() == .allowed)

        source.send(.wifi)
        _ = await updates.next()
        #expect(policy.canStream() == .allowed)

        source.send(.offline)
        _ = await updates.next()
        #expect(policy.canStream() == .denied)
        #expect(policy.canDownload() == .denied)
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
