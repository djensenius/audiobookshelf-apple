import Foundation

/// What ``DownloadManager`` needs from ``DownloadEngine``; tests substitute a fake.
///
/// ``updates`` and ``progress`` have one consumer each: once ``DownloadManager/start()`` has
/// run, the manager is that consumer, and nothing else may iterate them.
public protocol DownloadEngineControlling: Sendable {
    /// Durable changes, for one consumer (see ``DownloadEngine/updates``).
    var updates: AsyncStream<DownloadUpdate> { get }
    /// Live progress per part, for one consumer (see ``DownloadEngine/progress``).
    var progress: AsyncStream<DownloadProgress> { get }
    /// See ``DownloadEngine/start(partIDs:)``.
    func start(partIDs: [UUID]) async
    /// See ``DownloadEngine/stop(partIDs:keepingResumeData:)``.
    func stop(partIDs: [UUID], keepingResumeData: Bool) async
    /// See ``DownloadEngine/attachSurvivingTransfers()``.
    func attachSurvivingTransfers() async -> Bool
    /// See ``DownloadEngine/pause(recordID:)``.
    func pause(recordID: UUID) async throws -> Bool
    /// See ``DownloadEngine/resume(recordID:)``.
    func resume(recordID: UUID) async throws -> Bool
}

extension DownloadEngine: DownloadEngineControlling {}
