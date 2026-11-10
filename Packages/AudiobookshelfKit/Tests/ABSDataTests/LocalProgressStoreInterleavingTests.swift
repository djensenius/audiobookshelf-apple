import ABSCore
import Foundation
import Testing

@testable import ABSData

/// Seeded random interleavings of `LocalProgressStore` operations on one row's audio position,
/// against a reference server. The clock advances 0 or 1 ms per step, so server writes and edits
/// often share a millisecond. After every step: an unconfirmed edit is only replaced by another
/// device's later write; a clean row holds a server value no older than the last acknowledged
/// write nor goes back to an older one; a held socket value never becomes the row's value; and `needsConfirmationFetch`
/// matches the hold. Each run then converges to the server. 25 seeds of 50 steps by default; set
/// `ABS_PROGRESS_SEEDS` to run more (2,000 take about two minutes), or `ABS_PROGRESS_SEED` to
/// replay one.
@Suite struct LocalProgressStoreInterleavingTests {
    @Test func randomInterleavingsKeepTheStoreInvariants() async throws {
        let environment = ProcessInfo.processInfo.environment
        let seeds: [UInt64] =
            if let seed = environment["ABS_PROGRESS_SEED"].flatMap(UInt64.init) {
                [seed]
            } else {
                Array(1...(environment["ABS_PROGRESS_SEEDS"].flatMap(UInt64.init) ?? 25))
            }
        let container = try DataStack(location: .inMemory).container
        for seed in seeds {
            var run = StoreInterleaving(seed: seed, store: LocalProgressStore(modelContainer: container))
            try await run.start()
            for step in 0..<50 {
                try await run.step()
                if let failure = try await run.check() {
                    Issue.record("seed \(seed), step \(step): \(failure)\n\(run.log.joined(separator: "\n"))")
                    return
                }
            }
            if let failure = try await run.converge() {
                Issue.record("seed \(seed), convergence: \(failure)\n\(run.log.joined(separator: "\n"))")
                return
            }
        }
    }
}

/// One run: the store, a reference server (its write history, newest last) and the client's
/// pending network events.
private struct StoreInterleaving {
    private struct Write {
        var currentTime: Double
        var time: Date
        var ours: Bool
    }

    private struct Fetch {
        var captured: ProgressGeneration
        var generation: UInt64
        var response: ProgressBaseline?
    }

    private static let duration: Double = 100_000
    private static let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    let store: LocalProgressStore
    let key: MediaKey
    var rng: SeededGenerator
    var log: [String] = []
    private let quiet: Bool
    /// Invariants found broken during a step, reported by ``check()``.
    private var violations: [String] = []
    private var milliseconds: Double = 0
    /// Positions 10 s apart: comparisons allow 1 s.
    private var nextValue: Double = 20
    private var writes = [Write(currentTime: 10, time: t0, ours: false)]
    /// Snapshots emitted by the server and not yet delivered, oldest first.
    private var socket: [ProgressBaseline] = []
    private var fetches: [Fetch] = []
    /// The PATCH in flight and the index of its server write once applied.
    private var send: (patch: ProgressPatch, applied: Int?)?
    /// Mirrors the store's generation check: bumped by every local edit and settlement.
    private var generation: UInt64 = 0
    private var holdActive = false
    /// The latest local edit the server hasn't confirmed.
    private var pending: (value: Double, time: Date)?
    /// The server write of the latest acknowledged PATCH.
    private var floor = 0
    /// The newest server write a clean row has held.
    private var newestClean = 0

    init(seed: UInt64, store: LocalProgressStore) {
        self.store = store
        key = MediaKey(serverConnectionID: Fixtures.connectionID, libraryItemId: "li_\(seed)")
        rng = SeededGenerator(seed: seed)
        quiet = !seed.isMultiple(of: 2)
    }

    private var now: Date { Self.t0.addingTimeInterval(milliseconds / 1000) }

    private func snapshot(_ index: Int) -> ProgressBaseline {
        let write = writes[index]
        return ProgressBaseline(
            currentTime: write.currentTime, progress: write.currentTime / Self.duration, duration: Self.duration,
            isFinished: false, lastUpdate: write.time)
    }

    private mutating func serverWrite(_ currentTime: Double, ours: Bool) -> Int {
        writes.append(Write(currentTime: currentTime, time: now, ours: ours))
        socket.append(snapshot(writes.count - 1))
        return writes.count - 1
    }

    mutating func start() async throws {
        try await edit(seed: snapshot(0))
    }

    private mutating func edit(seed: ProgressBaseline? = nil) async throws {
        let value = nextValue
        nextValue += 10
        let edit = ProgressEdit(
            audio: .init(currentTime: value, duration: Self.duration, progress: value / Self.duration))
        try await store.recordEdit(edit, for: key, serverProgress: seed, now: now)
        generation += 1
        pending = (value, now)
        log.append("\(Int(milliseconds)) ms: edit \(value)")
    }

    private mutating func complete(timed: Bool) async throws {
        guard let patch = send?.patch, let applied = send?.applied else { return }
        let acked = try await store.completeSend(patch, serverLastUpdate: timed ? writes[applied].time : nil)
        precondition(acked)
        generation += 1
        send = nil
        if !timed { holdActive = true }
        floor = max(floor, applied)
        if pending?.value == patch.values.audio?.currentTime { pending = nil }
        log.append("\(Int(milliseconds)) ms: ack \(patch.values.audio?.currentTime ?? -1)\(timed ? " timed" : "")")
    }

    private mutating func deliverFetch(_ index: Int) async throws {
        let fetch = fetches.remove(at: index)
        guard let response = fetch.response else { return }
        try await store.applyServerProgress([key: response], capturedAt: fetch.captured, source: .fetch)
        if fetch.generation >= generation { holdActive = false }
        log.append(
            "\(Int(milliseconds)) ms: fetch \(response.currentTime)\(fetch.generation >= generation ? "" : " stale")")
    }

    mutating func step() async throws {
        // Odd seeds rarely edit or advance the clock, so the row is often clean while server values
        // sharing a millisecond arrive.
        milliseconds += Double(Int.random(in: 0..<(quiet ? 4 : 2), using: &rng) == 1 ? 1 : 0)
        switch Int.random(in: quiet ? 13..<100 : 0..<100, using: &rng) {
        case 0..<16:
            try await edit()
        case 16..<28:
            if let patch = try await store.beginSend(for: key, now: now) {
                send = (patch, nil)
                log.append("\(Int(milliseconds)) ms: begin \(patch.values.audio?.currentTime ?? -1)")
            }
        case 28..<38:
            if let send, send.applied == nil, let value = send.patch.values.audio?.currentTime {
                let applied = serverWrite(value, ours: true)
                self.send?.applied = applied
                log.append("\(Int(milliseconds)) ms: server applies \(value)")
            }
        case 38..<48:
            try await complete(timed: Int.random(in: 0..<4, using: &rng) == 0)
        case 48..<53:
            if let patch = send?.patch {
                let permanent = Bool.random(using: &rng)
                try await store.failSend(patch, error: permanent ? "404" : nil)
                generation += 1
                send = nil
                log.append("\(Int(milliseconds)) ms: fail")
            }
        case 53..<61:
            let value = nextValue
            nextValue += 10
            _ = serverWrite(value, ours: false)
            log.append("\(Int(milliseconds)) ms: other device writes \(value)")
        case 61..<75:
            guard !socket.isEmpty else { return }
            let event = socket.removeFirst()
            let before = try await store.progress(for: key)
            let held = await store.needsConfirmationFetch.contains(key)
            let capture = await store.captureGeneration()
            try await store.applyServerProgress([key: event], capturedAt: capture, source: .socket)
            log.append("\(Int(milliseconds)) ms: socket \(event.currentTime)\(held ? " held" : "")")
            if held, try await store.progress(for: key)?.currentTime != before?.currentTime {
                violations.append("a held socket value \(event.currentTime) became the row's value")
                log.append("\(Int(milliseconds)) ms: VIOLATION: \(violations[violations.count - 1])")
            }
        case 75..<83:
            fetches.append(Fetch(captured: await store.captureGeneration(), generation: generation))
        case 83..<91:
            if let index = fetches.indices.filter({ fetches[$0].response == nil }).randomElement(using: &rng) {
                fetches[index].response = snapshot(writes.count - 1)
            }
        case 91..<97:
            // Responses arrive in any order, often the newest first.
            let served = fetches.indices.filter { fetches[$0].response != nil }
            if let index = Bool.random(using: &rng) ? served.last : served.randomElement(using: &rng) {
                try await deliverFetch(index)
            }
        default:
            // The syncer's confirmation fetch.
            guard holdActive else { return }
            fetches.append(
                Fetch(
                    captured: await store.captureGeneration(), generation: generation,
                    response: snapshot(writes.count - 1)))
            try await deliverFetch(fetches.count - 1)
        }
    }

    /// The invariants; returns a description of the first one violated.
    mutating func check() async throws -> String? {
        if let violation = violations.first { return violation }
        guard let row = try await store.progress(for: key) else { return "the row is gone" }
        let value = row.currentTime
        if let edit = pending, value != edit.value {
            // Only another device's write made at or after the edit may replace it.
            guard writes.contains(where: { !$0.ours && $0.currentTime == value && $0.time >= edit.time }) else {
                return "unconfirmed edit \(edit.value) replaced by \(value)"
            }
            pending = nil
        }
        if row.dirtyGroups.isEmpty {
            guard let index = writes.lastIndex(where: { $0.currentTime == value }) else {
                return "clean row holds \(value), which the server never had"
            }
            guard index >= floor else {
                return "clean row holds \(value), older than the acknowledged \(writes[floor].currentTime)"
            }
            // A clean row never goes back to an older write (the earliest with its value, in case
            // a send was applied twice).
            let first = writes.firstIndex { $0.currentTime == value } ?? index
            guard first >= newestClean else {
                return "clean row went back to \(value) from \(writes[newestClean].currentTime)"
            }
            newestClean = first
            if pending?.value == value { pending = nil }
        }
        if await store.needsConfirmationFetch.contains(key) != holdActive {
            return "needsConfirmationFetch is \(!holdActive), expected \(holdActive)"
        }
        return nil
    }

    /// Stops the other device, sends until nothing is dirty and applies a confirming fetch: the
    /// row must then equal the server.
    mutating func converge() async throws -> String? {
        milliseconds += 1
        for _ in 0..<20 {
            if send == nil, let patch = try await store.beginSend(for: key, now: now) { send = (patch, nil) }
            guard let send else { break }
            if send.applied == nil, let value = send.patch.values.audio?.currentTime {
                let applied = serverWrite(value, ours: true)
                self.send?.applied = applied
            }
            try await complete(timed: false)
            if let failure = try await check() { return failure }
        }
        fetches.append(
            Fetch(
                captured: await store.captureGeneration(), generation: generation, response: snapshot(writes.count - 1))
        )
        try await deliverFetch(fetches.count - 1)
        if let failure = try await check() { return failure }
        guard let row = try await store.progress(for: key) else { return "the row is gone" }
        guard row.dirtyGroups.isEmpty, row.currentTime == writes[writes.count - 1].currentTime else {
            return
                "row \(row.currentTime) (dirty \(row.dirtyGroups)) after converging; server has \(writes.last!.currentTime)"
        }
        return nil
    }
}
