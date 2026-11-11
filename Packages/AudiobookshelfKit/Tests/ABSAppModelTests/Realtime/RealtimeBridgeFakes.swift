import ABSAPI
import ABSCore
import ABSRealtime
import Foundation

@testable import ABSAppModel

/// Records values and lets a test wait, without sleeping, until they satisfy a condition. A
/// wait ends early when its task is cancelled, as by a test's time limit.
@MainActor
final class Recorder<Value> {
    private struct Waiter {
        let condition: ([Value]) -> Bool
        let continuation: CheckedContinuation<Void, Never>
    }

    private(set) var values: [Value] = []
    private var waiters: [Int: Waiter] = [:]
    private var nextWaiterID = 0

    func append(_ value: Value) {
        values.append(value)
        let ready = waiters.filter { $0.value.condition(values) }
        for (id, waiter) in ready {
            waiters[id] = nil
            waiter.continuation.resume()
        }
    }

    func wait(until condition: @escaping ([Value]) -> Bool) async {
        guard !condition(values) else { return }
        nextWaiterID += 1
        let id = nextWaiterID
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume()
                } else {
                    waiters[id] = Waiter(condition: condition, continuation: continuation)
                }
            }
        } onCancel: {
            Task { @MainActor in self.cancelWait(id) }
        }
    }

    func wait(count: Int) async {
        await wait { $0.count >= count }
    }

    private func cancelWait(_ id: Int) {
        waiters.removeValue(forKey: id)?.continuation.resume()
    }
}

extension Recorder where Value: Equatable {
    func wait(for value: Value) async {
        await wait { $0.contains(value) }
    }

    func count(of value: Value) -> Int { values.filter { $0 == value }.count }
}

/// A socket whose events the test sends, and which records its calls.
@MainActor
final class FakeSocket: RealtimeConnecting {
    nonisolated let events: AsyncStream<RealtimeEvent>
    nonisolated let continuation: AsyncStream<RealtimeEvent>.Continuation
    let configuration: RealtimeConfiguration
    let calls = Recorder<String>()

    init(configuration: RealtimeConfiguration) {
        self.configuration = configuration
        (events, continuation) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
    }

    func connect() async { calls.append("connect") }
    func disconnect(sendingFarewell: Bool) async {
        calls.append(sendingFarewell ? "disconnect" : "disconnect(noFarewell)")
    }
    func networkChanged() async { calls.append("networkChanged") }
    func updateToken(_ token: String) async { calls.append("updateToken(\(token))") }
}

/// A token source with a stored token and scripted refreshes.
@MainActor
final class FakeTokenSource: RealtimeTokenSource {
    var current: String?
    /// What each refresh returns or throws, in order; the last one repeats.
    var refreshResults: [Result<String, any Error>] = []
    /// When set, a refresh waits for it after being recorded.
    var refreshGate: Gate?
    /// When set, reading the token to connect with waits for it.
    var readGate: Gate?
    /// The rejected token of each refresh.
    let refreshes = Recorder<String?>()
    /// How often the token to connect with was read.
    let reads = Recorder<Void>()

    init(current: String?) {
        self.current = current
    }

    func currentAccessToken() async -> String? { current }

    func accessToken(replacing rejected: String?) async throws -> String {
        guard let rejected else {
            reads.append(())
            await readGate?.wait()
            guard let current else { throw APIError.notAuthenticated }
            return current
        }
        refreshes.append(rejected)
        await refreshGate?.wait()
        let index = min(refreshes.values.count, refreshResults.count) - 1
        return try refreshResults[index].get()
    }
}

/// A bridge with fake sockets and tokens, and helpers to drive it.
@MainActor
final class BridgeHarness {
    let cache = ProgressCache()
    let sockets = Recorder<FakeSocket>()
    let handled = Recorder<RealtimeEvent>()
    var tokenSources: [ObjectIdentifier: FakeTokenSource] = [:]
    let defaultTokens = FakeTokenSource(current: "t1")
    private(set) var bridge: RealtimeBridge!

    init() {
        bridge = RealtimeBridge(
            progress: cache,
            makeSocket: { [sockets] configuration in
                let socket = FakeSocket(configuration: configuration)
                sockets.append(socket)
                return socket
            },
            makeTokenSource: { [unowned self] client in
                tokenSources[ObjectIdentifier(client)] ?? defaultTokens
            })
        bridge.didHandle = { [handled] in handled.append($0) }
    }

    func context(_ identity: SessionIdentity = identityA, client: APIClient?, isOffline: Bool = false)
        -> SessionContext
    {
        SessionContext(identity: identity, client: client, isOffline: isOffline, sessionID: 1)
    }

    /// Starts a session and waits until its socket connects.
    @discardableResult
    func start(client: APIClient? = nil) async throws -> FakeSocket {
        let client = try client ?? makeClient()
        let count = sockets.values.count
        await bridge.sessionDidStart(context(client: client))
        await sockets.wait(count: count + 1)
        let socket = sockets.values[count]
        await socket.calls.wait(for: "connect")
        return socket
    }

    /// Sends `event` and waits until the bridge handled it.
    func send(_ event: RealtimeEvent, on socket: FakeSocket) async {
        let count = handled.values.count
        socket.continuation.yield(event)
        await handled.wait(count: count + 1)
    }
}

func progressUpdate(
    _ itemID: String, episode: String? = nil, currentTime: Double, lastUpdate: Int?, sessionID: String? = "remote"
) -> RealtimeEvent {
    .userItemProgressUpdated(
        UserItemProgressUpdate(
            id: "p-\(itemID)", sessionId: sessionID, deviceDescription: nil,
            progress: MediaProgress(
                id: "p-\(itemID)", libraryItemId: itemID, episodeId: episode, currentTime: currentTime,
                lastUpdate: lastUpdate)))
}
