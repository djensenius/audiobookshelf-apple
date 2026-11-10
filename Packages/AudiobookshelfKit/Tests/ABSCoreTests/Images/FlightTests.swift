import Foundation
import Synchronization
import Testing

@testable import ABSCore

@Suite(.timeLimit(.minutes(1))) struct FlightTests {
    @Test func callerCancelledBeforeJoiningAbandonsTheFlight() async throws {
        let (finished, finish) = AsyncStream.makeStream(of: Bool.self)
        let flight = Flight<Int>()
        flight.start {
            defer { finish.finish() }
            do {
                try await Task.sleep(for: .seconds(30))
            } catch {
                finish.yield(Task.isCancelled)
                throw error
            }
            return 1
        }
        let caller = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await flight.join()
        }
        await #expect(throws: CancellationError.self) { try await caller.value }
        #expect(flight.isAbandoned)
        var iterator = finished.makeAsyncIterator()
        #expect(await iterator.next() == true)
    }

    /// The abandonment lands before `start` publishes the task handle, the window in which
    /// `cancel()` sees no task; `start` must cancel the task itself.
    @Test func flightAbandonedBeforeItsTaskIsPublishedCancelsTheTask() async throws {
        let (finished, finish) = AsyncStream.makeStream(of: Bool.self)
        let flight = Flight<Int>()
        flight.cancel()
        flight.start {
            defer { finish.finish() }
            do {
                try await Task.sleep(for: .seconds(30))
            } catch {
                finish.yield(Task.isCancelled)
                throw error
            }
            return 1
        }
        #expect(flight.isAbandoned)
        var iterator = finished.makeAsyncIterator()
        #expect(await iterator.next() == true)
        // `Abandoned` or the task's `CancellationError`, depending on whether `finish` has run yet.
        await #expect(throws: (any Error).self) { try await flight.join() }
    }

    /// Starts a flight whose operation waits for `gate`, then reports whether it was cancelled.
    private func gatedFlight(
        _ gate: AsyncStream<Void>, starts: AsyncStream<Void>.Continuation, cancelled: AsyncStream<Bool>.Continuation
    ) -> Flight<Int> {
        let flight = Flight<Int>()
        flight.start {
            starts.yield()
            var iterator = gate.makeAsyncIterator()
            _ = await iterator.next()
            cancelled.yield(Task.isCancelled)
            try Task.checkCancellation()
            return 7
        }
        return flight
    }

    @Test func oneCallerLeavingKeepsTheSharedWorkForTheOthers() async throws {
        let gate = AsyncStream.makeStream(of: Void.self)
        let starts = AsyncStream.makeStream(of: Void.self)
        let cancelled = AsyncStream.makeStream(of: Bool.self)
        let flight = gatedFlight(gate.stream, starts: starts.continuation, cancelled: cancelled.continuation)
        let leaving = Task { try await flight.join() }
        let staying = Task { try await flight.join() }
        await yieldUntil { flight.waiterCount == 2 }

        leaving.cancel()
        await #expect(throws: CancellationError.self) { try await leaving.value }
        #expect(flight.waiterCount == 1)
        #expect(!flight.isAbandoned)
        gate.continuation.finish()
        #expect(try await staying.value == 7)
        var iterator = cancelled.stream.makeAsyncIterator()
        #expect(await iterator.next() == false)
    }

    @Test func everyCallerLeavingCancelsTheWorkAndALaterCallerStartsAgain() async throws {
        let gate = AsyncStream.makeStream(of: Void.self)
        let starts = AsyncStream.makeStream(of: Void.self)
        let cancelled = AsyncStream.makeStream(of: Bool.self)
        let flight = gatedFlight(gate.stream, starts: starts.continuation, cancelled: cancelled.continuation)
        let callers = [Task { try await flight.join() }, Task { try await flight.join() }]
        await yieldUntil { flight.waiterCount == 2 }

        for caller in callers {
            caller.cancel()
            await #expect(throws: CancellationError.self) { try await caller.value }
        }
        #expect(flight.isAbandoned)
        var wasCancelled = cancelled.stream.makeAsyncIterator()
        #expect(await wasCancelled.next() == true)
        // An abandoned flight never serves a result again; the caller starts a new one.
        await #expect(throws: (any Error).self) { try await flight.join() }

        let fresh = gatedFlight(gate.stream, starts: starts.continuation, cancelled: cancelled.continuation)
        #expect(try await fresh.join() == 7)
        #expect(await wasCancelled.next() == false)
        starts.continuation.finish()
        #expect(await starts.stream.reduce(0) { count, _ in count + 1 } == 2)
    }
}
