import AVFoundation
import Testing

@testable import ABSPlayback

/// The chime's engine posts `AVAudioEngineConfigurationChange` on a route or format change. These build the output
/// without starting it, so they play nothing and don't need an output device.
@MainActor
struct SystemSleepTimerFeedbackTests {
    private let format: AVAudioFormat

    init() throws {
        format = try #require(SystemSleepTimerFeedback.makeChime()).format
    }

    @Test func aConfigurationChangeReleasesTheEngineAfterTheNotificationReturns() async throws {
        let feedback = SystemSleepTimerFeedback()
        _ = try #require(feedback.chimeOutput(format: format))

        let disposal = feedback.configurationDidChange(generation: feedback.outputGeneration)

        // Still held when the observer returns: releasing an engine inside its own notification can deadlock.
        #expect(feedback.hasOutput)
        await disposal.value
        #expect(!feedback.hasOutput)
    }

    @Test func aLateNotificationFromADroppedEngineLeavesTheRebuiltOutputAlone() async throws {
        let feedback = SystemSleepTimerFeedback()
        _ = try #require(feedback.chimeOutput(format: format))
        let dropped = feedback.outputGeneration
        await feedback.configurationDidChange(generation: dropped).value
        _ = try #require(feedback.chimeOutput(format: format))

        // The dropped engine posts again before its observer is gone.
        await feedback.configurationDidChange(generation: dropped).value

        #expect(feedback.hasOutput)
        #expect(feedback.outputGeneration == dropped + 1)
    }
}
