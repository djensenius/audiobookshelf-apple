import Testing

@Suite("Contract test load cache")
struct ContractLoadCacheTests {
    @Test("concurrent callers share one load")
    func concurrentCallersShareLoad() async throws {
        let cache = ContractLoadCache<Int>()
        let probe = ContractLoadProbe()
        let gate = AsyncStream.makeStream(of: Void.self)
        let started = AsyncStream.makeStream(of: Void.self)
        let callers = (0..<12).map { _ in
            Task {
                try await cache.value {
                    try await probe.load(waitingFor: gate.stream, started: started.continuation)
                }
            }
        }

        var startIterator = started.stream.makeAsyncIterator()
        #expect(await startIterator.next() != nil)
        try await yieldUntil { await cache.waiterCount == callers.count }
        gate.continuation.finish()
        var values: [Int] = []
        for caller in callers {
            values.append(try await caller.value)
        }

        #expect(values.count == 12)
        #expect(Set(values) == [42])
        #expect(await probe.callCount == 1)
    }

    @Test("a cancelled caller stops waiting without cancelling the shared load")
    func cancelledCallerLeavesSharedLoadRunning() async throws {
        let cache = ContractLoadCache<Int>()
        let probe = ContractLoadProbe()
        let gate = AsyncStream.makeStream(of: Void.self)
        let started = AsyncStream.makeStream(of: Void.self)
        let load: @Sendable () async throws -> Int = {
            try await probe.load(waitingFor: gate.stream, started: started.continuation)
        }
        let leaving = Task { try await cache.value(loading: load) }
        let staying = Task { try await cache.value(loading: load) }

        var startIterator = started.stream.makeAsyncIterator()
        #expect(await startIterator.next() != nil)
        try await yieldUntil { await cache.waiterCount == 2 }
        leaving.cancel()
        await #expect(throws: CancellationError.self) { try await leaving.value }
        #expect(await cache.waiterCount == 1)

        gate.continuation.finish()
        #expect(try await staying.value == 42)
        #expect(await probe.callCount == 1)
    }

    @Test("a failed load is cleared so a later caller can retry")
    func failedLoadCanBeRetried() async throws {
        let cache = ContractLoadCache<String>()
        let probe = RetryLoadProbe()

        await #expect(throws: CacheLoadError.expected) {
            try await cache.value {
                try await probe.load()
            }
        }

        #expect(try await cache.value { try await probe.load() } == "loaded")
        #expect(try await cache.value { "unused" } == "loaded")
        #expect(await probe.callCount == 2)
    }
}

private actor ContractLoadProbe {
    private(set) var callCount = 0

    func load(waitingFor gate: AsyncStream<Void>, started: AsyncStream<Void>.Continuation) async throws -> Int {
        callCount += 1
        started.yield()
        var iterator = gate.makeAsyncIterator()
        _ = await iterator.next()
        return 42
    }
}

private func yieldUntil(_ condition: () async -> Bool) async throws {
    for _ in 0..<1_000_000 {
        if await condition() { return }
        try Task.checkCancellation()
        await Task.yield()
    }
    throw CacheWaitError.timedOut
}

private enum CacheWaitError: Error {
    case timedOut
}

private enum CacheLoadError: Error {
    case expected
}

private actor RetryLoadProbe {
    private(set) var callCount = 0

    func load() async throws -> String {
        callCount += 1
        guard callCount > 1 else { throw CacheLoadError.expected }
        return "loaded"
    }
}
