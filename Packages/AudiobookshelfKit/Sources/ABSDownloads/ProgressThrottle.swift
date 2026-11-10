import Foundation

/// Decides which progress events reach the UI and which are written to the store.
///
/// A part's progress is published on its first event, then whenever at least 1% of the file
/// or 1 second has passed since the last published event, and when it reaches 100%. It is
/// written to the store at most every 2 seconds (ADR 0003); state changes are written anyway.
struct ProgressThrottle {
    struct Decision: Equatable {
        var publishes: Bool
        var persists: Bool
    }

    var publishFraction = 0.01
    var publishInterval: TimeInterval = 1
    var persistInterval: TimeInterval = 2
    private var published: [UUID: (bytes: Int64, date: Date)] = [:]
    private var persisted: [UUID: Date] = [:]

    mutating func record(_ partID: UUID, bytesWritten: Int64, expectedBytes: Int64, at date: Date) -> Decision {
        var publishes = true
        if let last = published[partID] {
            let step = expectedBytes > 0 ? max(1, Int64((Double(expectedBytes) * publishFraction).rounded(.up))) : .max
            let reachedEnd = expectedBytes > 0 && bytesWritten >= expectedBytes && last.bytes < expectedBytes
            publishes =
                reachedEnd || bytesWritten - last.bytes >= step || date.timeIntervalSince(last.date) >= publishInterval
        }
        if publishes { published[partID] = (bytesWritten, date) }
        let persists = persisted[partID].map { date.timeIntervalSince($0) >= persistInterval } ?? true
        if persists { persisted[partID] = date }
        return Decision(publishes: publishes, persists: persists)
    }

    /// Forgets `partID`, so its next event is published and written.
    mutating func reset(_ partID: UUID) {
        published[partID] = nil
        persisted[partID] = nil
    }
}
