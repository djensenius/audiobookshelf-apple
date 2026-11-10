import ABSCore
import AVFoundation
import Foundation
import Testing

@testable import ABSPlayback

/// Short silent WAV tracks generated at test time, so no binary fixtures are committed.
final class AudioFixture: Sendable {
    static let trackLength = 3.0
    static let sampleRate = 8000.0

    let directory: URL
    let urls: [URL]

    /// `count` tracks of ``trackLength`` seconds each, in a fresh temporary directory.
    init(trackCount count: Int = 3) throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "ABSPlaybackTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.directory = directory
        urls = try (0..<count).map { try Self.writeTrack(named: "track\($0)", in: directory) }
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    /// Three back-to-back tracks: 0–3, 3–6 and 6–9.
    var timeline: PlaybackTimeline {
        PlaybackTimeline(
            tracks: urls.indices.map {
                AudioTrack(index: $0 + 1, startOffset: Double($0) * Self.trackLength, duration: Self.trackLength)
            },
            chapters: [])
    }

    var source: AudioEngineSource { AudioEngineSource(timeline: timeline, trackURLs: urls) }

    private static func writeTrack(named name: String, in directory: URL) throws -> URL {
        let url = directory.appending(path: "\(name).wav")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings)
        let frames = AVAudioFrameCount(trackLength * sampleRate)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames))
        buffer.frameLength = frames
        try file.write(from: buffer)
        file.close()
        return url
    }
}

/// Polls `condition` on the main actor every 10 ms until it holds, `timeout` passes or the task
/// is cancelled (both return `false`).
@MainActor
func eventually(timeout: Duration = .seconds(3), _ condition: () -> Bool) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while !condition() {
        guard clock.now < deadline else { return false }
        do { try await Task.sleep(for: .milliseconds(10)) } catch { return false }
    }
    return true
}

struct WaitTimedOut: Error {}

/// Yields to other main-actor work until `condition` holds, checking it between every job so a
/// short-lived state is not missed. Records an issue and throws after `timeout`; throws
/// `CancellationError` if the task is cancelled.
@MainActor
func waitUntil(
    timeout: Duration = .seconds(5), sourceLocation: SourceLocation = #_sourceLocation, _ condition: () -> Bool
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while !condition() {
        try Task.checkCancellation()
        guard clock.now < deadline else {
            Issue.record("Timed out after \(timeout)", sourceLocation: sourceLocation)
            throw WaitTimedOut()
        }
        await Task.yield()
    }
}

/// Records `activate` / `deactivate` calls; throws ``activationError`` when set.
@MainActor
final class FakeAudioSession: AudioSessionActivating {
    struct ActivationError: Error {}

    private(set) var activations = 0
    private(set) var deactivations = 0
    var activationError: ActivationError?

    func activate() throws {
        activations += 1
        if let activationError { throw activationError }
    }
    func deactivate() { deactivations += 1 }
}
