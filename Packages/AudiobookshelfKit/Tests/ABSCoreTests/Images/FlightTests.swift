import Foundation
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
        await #expect(throws: CancellationError.self) { try await flight.join() }
    }
}
