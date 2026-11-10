import Synchronization
import Testing

@testable import ABSCore

/// Yields until `condition` holds, without sleeping; the suite's time limit catches a hang.
func yieldUntil(_ condition: () async -> Bool) async {
    while await !condition() { await Task.yield() }
}

@Suite(.timeLimit(.minutes(1))) struct AsyncSemaphoreTests {
    @Test func noMoreThanThePermitCountRunAtOnce() async throws {
        let semaphore = AsyncSemaphore(permits: 2)
        let running = Mutex((now: 0, peak: 0))
        let gates = (0..<5).map { _ in AsyncStream.makeStream(of: Void.self) }
        try await withThrowingTaskGroup(of: Void.self) { group in
            for gate in gates {
                group.addTask {
                    try await semaphore.acquire()
                    running.withLock { state in
                        state.now += 1
                        state.peak = max(state.peak, state.now)
                    }
                    var iterator = gate.stream.makeAsyncIterator()
                    _ = await iterator.next()
                    running.withLock { $0.now -= 1 }
                    await semaphore.release()
                }
            }
            await yieldUntil { await semaphore.waiterCount == 3 && running.withLock { $0.now } == 2 }
            for gate in gates { gate.continuation.finish() }
            try await group.waitForAll()
        }
        #expect(running.withLock { $0.peak } == 2)
        #expect(await semaphore.availablePermits == 2)
        #expect(await semaphore.waiterCount == 0)
    }

    @Test func waitersResumeInArrivalOrder() async throws {
        let semaphore = AsyncSemaphore(permits: 0)
        let order = Mutex<[Int]>([])
        var waiters: [Task<Void, any Error>] = []
        for index in 0..<3 {
            waiters.append(
                Task {
                    try await semaphore.acquire()
                    order.withLock { $0.append(index) }
                })
            await yieldUntil { await semaphore.waiterCount == index + 1 }
        }
        for index in 0..<3 {
            await semaphore.release()
            await yieldUntil { order.withLock { $0.count } == index + 1 }
        }
        for waiter in waiters { try await waiter.value }
        #expect(order.withLock { $0 } == [0, 1, 2])
        #expect(await semaphore.availablePermits == 0)
    }

    @Test func cancelledWaiterGivesItsPlaceToTheNext() async throws {
        let semaphore = AsyncSemaphore(permits: 0)
        let first = Task { try await semaphore.acquire() }
        await yieldUntil { await semaphore.waiterCount == 1 }
        let second = Task { try await semaphore.acquire() }
        await yieldUntil { await semaphore.waiterCount == 2 }

        first.cancel()
        await #expect(throws: CancellationError.self) { try await first.value }
        await yieldUntil { await semaphore.waiterCount == 1 }
        await semaphore.release()
        try await second.value
        #expect(await semaphore.availablePermits == 0)
        await semaphore.release()
        #expect(await semaphore.availablePermits == 1)
        #expect(await semaphore.waiterCount == 0)
    }

    @Test func callerCancelledBeforeAcquiringTakesNoPermit() async {
        let semaphore = AsyncSemaphore(permits: 1)
        let caller = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await semaphore.acquire()
        }
        await #expect(throws: CancellationError.self) { try await caller.value }
        #expect(await semaphore.availablePermits == 1)
        #expect(await semaphore.waiterCount == 0)
    }
}
