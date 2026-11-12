import ABSData
import Foundation

/// Hands ``ProgressSyncer``'s playback history events (#384) to a `PlaybackHistoryRecording`,
/// one at a time, on tasks nothing in playback or sync awaits. The recorder writes through its
/// store's actor and logs and drops an event it can't save, so a slow or failing store only
/// delays or loses history.
@MainActor
final class PlaybackHistoryLog {
    /// An event waiting to be recorded, with the position it happened at.
    struct Event {
        let name: PlaybackHistoryEventName
        let media: PlaybackHistoryMedia
        let position: TimeInterval?
    }

    private let recorder: any PlaybackHistoryRecording
    private var tail: Task<Void, Never>?
    /// Events waiting for a `/close` result before they join the queue.
    private var waiting: [UUID: Task<Void, Never>] = [:]

    init(_ recorder: any PlaybackHistoryRecording) {
        self.recorder = recorder
    }

    /// Records `events` in order, after any recorded before them.
    func record(_ events: [Event], sync: PlaybackHistorySyncResult, details: String? = nil) {
        guard !events.isEmpty else { return }
        let previous = tail
        let recorder = recorder
        tail = Task {
            await previous?.value
            for event in events {
                await recorder.record(event.name, for: event.media, at: event.position, sync: sync, details: details)
            }
        }
    }

    /// Records `events` once `close` resolves, with its result: acknowledged is a success,
    /// suppressed or cancelled is not attempted. Later events don't wait for it.
    func record(_ events: [Event], after close: PlaybackCloseResult<Bool>) {
        guard !events.isEmpty else { return }
        let id = UUID()
        // Holds the log until the events join the queue: its syncer may be gone by then.
        waiting[id] = Task {
            let sync: PlaybackHistorySyncResult
            do {
                sync = try await close.wait() ? .succeeded : .notAttempted
            } catch {
                sync = .failed(message: ProgressSyncer.caseName(error))
            }
            waiting[id] = nil
            record(events, sync: sync)
        }
    }

    /// Waits until every event handed over so far is recorded, including ones waiting for a
    /// `/close` that has resolved by then (tests).
    func waitForIdle() async {
        while let task = waiting.values.first ?? tail {
            await task.value
            if waiting.isEmpty, tail == task {
                tail = nil
                return
            }
        }
    }
}
