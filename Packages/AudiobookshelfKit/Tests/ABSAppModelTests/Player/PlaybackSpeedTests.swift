import ABSCore
import Foundation
import Testing

@testable import ABSAppModel

/// Runs `body` with a fake playback and a view model over it, with settings in a fresh suite.
@MainActor
private func withPlayer(_ body: @MainActor (PlayerViewModel, FakePlaybackControl) async throws -> Void) async throws {
    let suiteName = "ABSAppModelTests.PlaybackSpeed.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let playback = FakePlaybackControl()
    try await body(PlayerViewModel(playback: playback, settings: AppSettings(defaults: defaults)), playback)
}

@Suite struct PlaybackSpeedTests {
    @Test func stepAvoidsFloatDrift() throws {
        var rate = 1.0
        for _ in 0..<7 { rate = try #require(PlaybackSpeed.stepped(rate, up: true)) }
        #expect(rate == 1.7)
        for _ in 0..<12 { rate = try #require(PlaybackSpeed.stepped(rate, up: false)) }
        #expect(rate == 0.5)

        // Every grid rate is the exact decimal, up and down the whole range.
        rate = 0.5
        for tenths in 6...100 {
            rate = try #require(PlaybackSpeed.stepped(rate, up: true))
            #expect(rate == Double(tenths) / 10)
        }
    }

    @Test func stepStopsAtBounds() {
        #expect(PlaybackSpeed.stepped(10, up: true) == nil)
        #expect(PlaybackSpeed.stepped(10, up: false) == 9.9)
        #expect(PlaybackSpeed.stepped(0.5, up: false) == nil)
        #expect(PlaybackSpeed.stepped(0.5, up: true) == 0.6)
        // A grid rate a hair off still counts as on the grid.
        #expect(PlaybackSpeed.stepped(10.000_000_000_000_002, up: true) == nil)
        #expect(PlaybackSpeed.stepped(0.499_999_999_999_999_9, up: false) == nil)
    }

    @Test func outOfRangeStepsToTheBound() {
        // Toward the range, the first step lands on the bound rather than past it.
        #expect(PlaybackSpeed.stepped(0.25, up: true) == 0.5)
        #expect(PlaybackSpeed.stepped(12, up: false) == 10)
        #expect(PlaybackSpeed.stepped(10.04, up: false) == 10)
        // Away from it, there's nothing to step to.
        #expect(PlaybackSpeed.stepped(0.25, up: false) == nil)
        #expect(PlaybackSpeed.stepped(12, up: true) == nil)
    }

    @Test func stepMovesOffGridRateToNearestInDirection() {
        #expect(PlaybackSpeed.stepped(1.25, up: true) == 1.3)
        #expect(PlaybackSpeed.stepped(1.25, up: false) == 1.2)
        #expect(PlaybackSpeed.stepped(1.2000000000000002, up: true) == 1.3)
        #expect(PlaybackSpeed.stepped(1.1999999999999999, up: false) == 1.1)
    }

    @Test func normalizedRejectsNaNAndZero() {
        for rate in [Double.nan, .infinity, -.infinity, 0, -1] {
            #expect(PlaybackSpeed.normalized(rate) == 1, "rate \(rate)")
            #expect(PlaybackSpeed.stepped(rate, up: true) == 1.1, "rate \(rate)")
        }
        #expect(PlaybackSpeed.normalized(1.24) == 1.2)
        #expect(PlaybackSpeed.normalized(1.26) == 1.3)
        #expect(PlaybackSpeed.normalized(0.1) == 0.5)
        #expect(PlaybackSpeed.normalized(32) == 10)
        #expect(PlaybackSpeed.normalized(1.7000000000000004) == 1.7)
    }

    @Test func normalizedRoundsHalfTenthsUp() {
        // `rate / 0.1` gives 11.499999999999998 for 1.15, which would round down; `rate * 10` is 11.5.
        #expect(PlaybackSpeed.normalized(1.15) == 1.2)
        #expect(PlaybackSpeed.normalized(1.45) == 1.5)
        #expect(PlaybackSpeed.normalized(2.15) == 2.2)
        #expect(PlaybackSpeed.normalized(1.35) == 1.4)
        // Below the range, half tenths still clamp to its bound.
        #expect(PlaybackSpeed.normalized(0.35) == 0.5)
    }

    @Test func presetMatchingTolerance() {
        #expect(PlaybackSpeed.isPreset(1.2))
        #expect(PlaybackSpeed.isPreset(1.0 + 0.1 + 0.1))
        #expect(PlaybackSpeed.isPreset(1.700_000_5))
        #expect(!PlaybackSpeed.isPreset(1.700_002))
        #expect(!PlaybackSpeed.isPreset(1.3))
        #expect(!PlaybackSpeed.isPreset(10))
        #expect(PlaybackSpeed.presets.allSatisfy(PlaybackSpeed.range.contains))
    }

    @MainActor
    @Test func stepRateCallsSetRateOnce() async throws {
        try await withPlayer { model, playback in
            playback.rate = 1.2
            model.stepRate(up: true)
            #expect(playback.calls == [.setRate(1.3)])
            playback.clearCalls()
            model.stepRate(up: false)
            model.stepRate(up: false)
            #expect(playback.calls == [.setRate(1.2), .setRate(1.1)])
            #expect(model.rate == 1.1)
        }
    }

    @MainActor
    @Test func canStepFalseAtMax() async throws {
        try await withPlayer { model, playback in
            playback.rate = 10
            #expect(!model.canStepRate(up: true))
            #expect(model.canStepRate(up: false))
            model.stepRate(up: true)
            #expect(playback.calls.isEmpty)

            playback.rate = 0.5
            #expect(model.canStepRate(up: true))
            #expect(!model.canStepRate(up: false))
            model.stepRate(up: false)
            #expect(playback.calls.isEmpty)
        }
    }
}
