import ABSCore
import Foundation
import Testing

@testable import ABSAppModel

@Suite struct ConnectionIndicatorStateTests {
    private static let retryAt = Date(timeIntervalSince1970: 1_800_000_000)
    private static let sockets: [RealtimeConnectionState] = [
        .idle, .connecting, .connected, .disconnected, .authFailed,
    ]

    private func state(
        signedIn: Bool = true, path: NetworkPath? = .wifi, socket: RealtimeConnectionState? = .connected,
        banner: ConnectionBannerState? = .online
    ) -> ConnectionIndicatorState? {
        ConnectionIndicatorState(isSignedIn: signedIn, path: path, socket: socket, banner: banner)
    }

    @Test(arguments: sockets)
    func hiddenSignedOut(socket: RealtimeConnectionState) {
        #expect(state(signedIn: false, socket: socket) == nil)
        #expect(state(signedIn: false, path: .offline, socket: socket) == nil)
    }

    @Test func hiddenWithoutABridge() {
        #expect(state(socket: nil) == nil)
        #expect(state(path: .offline, socket: nil) == nil)
    }

    @Test(arguments: sockets)
    func noNetworkIsOfflineWhateverTheSocketSays(socket: RealtimeConnectionState) {
        #expect(state(path: .offline, socket: socket) == .offline)
        #expect(state(path: .offline, socket: socket, banner: .serverUnreachable(retryAt: nil)) == .offline)
        #expect(state(socket: socket, banner: .offline(.noNetwork)) == .offline)
    }

    @Test func startingSocketIsConnecting() {
        #expect(state(socket: .connecting) == .connecting)
        #expect(state(socket: .idle) == .connecting)
        #expect(state(socket: .connecting, banner: nil) == .connecting)
    }

    @Test func lostOrRejectedSocketIsServerUnreachable() {
        #expect(state(socket: .disconnected) == .serverUnreachable)
        #expect(state(socket: .authFailed) == .serverUnreachable)
        #expect(state(socket: .authFailed, banner: nil) == .serverUnreachable)
    }

    @Test(arguments: sockets)
    func failedPingsAreServerUnreachable(socket: RealtimeConnectionState) {
        #expect(state(socket: socket, banner: .serverUnreachable(retryAt: Self.retryAt)) == .serverUnreachable)
        // Checking again doesn't flip it back to connecting.
        #expect(state(socket: socket, banner: .serverUnreachable(retryAt: nil)) == .serverUnreachable)
    }

    @Test func connectedFollowsTheInterfaceAndMetering() {
        #expect(state(path: .wifi) == .connected(cellular: false, metered: false))
        #expect(state(path: .wired) == .connected(cellular: false, metered: false))
        #expect(state(path: .cellular) == .connected(cellular: true, metered: true))
        #expect(
            state(path: NetworkPath(isOnline: true, interface: .cellular))
                == .connected(cellular: true, metered: false))
        #expect(
            state(path: NetworkPath(isOnline: true, isExpensive: true, interface: .wifi))
                == .connected(cellular: false, metered: true))
        #expect(
            state(path: NetworkPath(isOnline: true, isConstrained: true, interface: .wifi))
                == .connected(cellular: false, metered: true))
        #expect(
            state(path: NetworkPath(isOnline: true, isConstrained: true, interface: .cellular))
                == .connected(cellular: true, metered: true))
    }

    @Test func unknownPathAndBannerAreAssumedOnline() {
        #expect(state(path: nil, banner: nil) == .connected(cellular: false, metered: false))
        #expect(state(path: nil, socket: .connecting) == .connecting)
    }
}
