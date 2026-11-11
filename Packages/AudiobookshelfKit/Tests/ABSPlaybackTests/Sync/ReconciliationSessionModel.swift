import ABSCore
import Foundation

@testable import ABSAPI

/// Opt-in identity shared by the coordinator and progress adapters. Unconfigured fakes keep
/// their original recording behavior. This is not a production reconciliation service.
struct SessionModelClient: Sendable {
    let model: ReconciliationSessionModel
    var userID = "user"
    var deviceID = "phone"
}

/// Sequential subset of the two pinned servers; see docs/testing/server-contracts.md.
/// Application is atomic here, unlike the server's asynchronous database work. The gates
/// explore client-visible ambiguity, NOT a proof of server ordering after cancellation.
actor ReconciliationSessionModel {
    enum Operation: Hashable, Sendable {
        case start, sync, close, lookup, records, progress
    }

    enum Failure: Error, Equatable { case responseLost, notApplied }

    final class Request: Sendable {
        enum Outcome: Sendable { case acknowledged, appliedResponseLost, unapplied }
        let outcome: Outcome
        let arrived = Gate()
        let enter = Gate()
        let entered = Gate()
        let apply = Gate()
        let applicationFinished = Gate()
        let respond = Gate()
        let completed = Gate()

        init(_ outcome: Outcome = .acknowledged) { self.outcome = outcome }

        /// Cleanup always releases owned tasks, even if an assertion throws.
        func release() {
            enter.open()
            apply.open()
            respond.open()
        }
    }

    private struct Key: Hashable {
        let user: String
        let item: String
        let episode: String?
    }

    private let clock: TestClock
    private var nextID = 0
    private var open: [String: PlaybackSession] = [:]
    private var stored: [String: PlaybackSession] = [:]
    private var progress: [Key: MediaProgress] = [:]
    private var requests: [Operation: [Request]] = [:]

    init(clock: TestClock = TestClock()) { self.clock = clock }

    func enqueue(_ request: Request, for operation: Operation) {
        requests[operation, default: []].append(request)
    }

    private var milliseconds: Int { Int(clock.now.timeIntervalSince1970 * 1000) }

    private func perform<Value: Sendable>(
        _ operation: Operation, application: () throws -> Value
    ) async throws -> Value {
        guard var queue = requests[operation], !queue.isEmpty else { return try application() }
        let request = queue.removeFirst()
        requests[operation] = queue
        request.arrived.open()
        await request.enter.wait()
        request.entered.open()
        await request.apply.wait()
        let result: Result<Value, any Error>
        if request.outcome == .unapplied {
            result = .failure(Failure.notApplied)
        } else {
            result = Result { try application() }
        }
        request.applicationFinished.open()
        await request.respond.wait()
        request.completed.open()
        let value = try result.get()
        if request.outcome == .appliedResponseLost { throw Failure.responseLost }
        return value
    }

    func start(_ client: SessionModelClient, itemID: String, episodeID: String?) async throws -> PlaybackSession {
        try await perform(.start) {
            let retired = open.values.filter {
                $0.userId == client.userID && $0.deviceInfo?.deviceId == client.deviceID
            }
            for session in retired {
                save(session)
                open.removeValue(forKey: session.id)
            }
            nextID += 1
            let key = Key(user: client.userID, item: itemID, episode: episodeID)
            let time = progress[key]?.currentTime ?? 0
            let session = PlaybackSession(
                id: "session-\(nextID)", userId: client.userID, libraryItemId: itemID, episodeId: episodeID,
                mediaType: episodeID == nil ? .book : .podcast, displayTitle: itemID,
                duration: 3600, playMethod: .directPlay, deviceInfo: DeviceInfo(deviceId: client.deviceID),
                startTime: time, currentTime: time, startedAt: milliseconds, updatedAt: milliseconds,
                audioTracks: [AudioTrack(index: 1, startOffset: 0, duration: 3600, mimeType: "audio/mpeg")])
            open[session.id] = session
            return session
        }
    }

    private func requireOpen(_ id: String, userID: String) throws -> PlaybackSession {
        guard let session = open[id], session.userId == userID else { throw APIError.notFound }
        return session
    }

    private func save(_ session: PlaybackSession) {
        if session.timeListening > 0 { stored[session.id] = session }
    }

    private func report(_ report: PlaybackSyncReport, to session: inout PlaybackSession) {
        session.currentTime = report.currentTime
        session.timeListening += report.timeListened
        // The server updates the session date on nonzero listening, not every position write.
        if report.timeListened > 0 { session.updatedAt = milliseconds }
        let key = Key(user: session.userId ?? "", item: session.libraryItemId, episode: session.episodeId)
        progress[key] = MediaProgress(
            id: "progress-\(session.libraryItemId)", libraryItemId: session.libraryItemId,
            episodeId: session.episodeId, duration: report.duration,
            progress: report.duration > 0 ? report.currentTime / report.duration : 0,
            currentTime: report.currentTime, lastUpdate: milliseconds)
        save(session)
    }

    func sync(_ client: SessionModelClient, id: String, report: PlaybackSyncReport) async throws {
        try await perform(.sync) {
            var session = try requireOpen(id, userID: client.userID)
            self.report(report, to: &session)
            open[id] = session
        }
    }

    func close(_ client: SessionModelClient, id: String, report: PlaybackSyncReport?) async throws {
        try await perform(.close) {
            var session = try requireOpen(id, userID: client.userID)
            if let report { self.report(report, to: &session) }
            save(session)
            open.removeValue(forKey: id)
        }
    }

    func lookup(_ client: SessionModelClient, id: String) async throws -> PlaybackSession {
        try await perform(.lookup) { try requireOpen(id, userID: client.userID) }
    }

    func fetchProgress(
        _ client: SessionModelClient, itemID: String, episodeID: String?
    ) async throws -> MediaProgress? {
        try await perform(.progress) {
            progress[Key(user: client.userID, item: itemID, episode: episodeID)]
        }
    }

    func records(
        _ client: SessionModelClient, itemID: String, episodeID: String?, page: Int = 0, itemsPerPage: Int = 10
    ) async throws -> ListeningSessionsPage {
        precondition(page >= 0 && itemsPerPage > 0)
        return try await perform(.records) {
            let rows = stored.values.filter {
                $0.userId == client.userID && $0.libraryItemId == itemID && $0.episodeId == episodeID
            }.sorted {
                // Tie order is deliberately only a fixture convenience, not a server guarantee.
                if $0.updatedAt == $1.updatedAt { return $0.id < $1.id }
                return ($0.updatedAt ?? 0) > ($1.updatedAt ?? 0)
            }
            let records = rows.dropFirst(page * itemsPerPage).prefix(itemsPerPage).map {
                [
                    "id": $0.id, "timeListening": $0.timeListening, "currentTime": $0.currentTime,
                    "updatedAt": $0.updatedAt ?? 0,
                ] as [String: Any]
            }
            // Use the real page decoder, preserving its actual metadata rather than a fake array.
            let data = try JSONSerialization.data(withJSONObject: [
                "sessions": records, "total": rows.count, "numPages": (rows.count + itemsPerPage - 1) / itemsPerPage,
                "page": page, "itemsPerPage": itemsPerPage,
            ])
            return try JSONDecoder().decode(ListeningSessionsPage.self, from: data)
        }
    }
}
