import ABSAPI
import ABSCore
import Foundation
import Testing

@testable import ABSPlayback

private struct FixedDeviceIdentifier: DeviceIdentifying {
    let value: String
    func deviceIdentifier() async -> String { value }
}

@Suite struct PlaybackDeviceInfoTests {
    @Test func supportedTypesKeepPlayableServerTypesMinusDenylist() {
        let playable: Set = ["audio/mpeg", "audio/mp4", "audio/flac", "audio/ogg", "audio/amr-wb", "audio/x-caf"]
        #expect(
            SupportedAudioMIMETypes.current { playable.contains($0) }
                == ["audio/mpeg", "audio/mp4", "audio/flac", "audio/x-caf"])
        #expect(
            SupportedAudioMIMETypes.current { _ in true }.allSatisfy { !["audio/ogg", "audio/amr-wb"].contains($0) })
    }

    @Test func supportedTypesOnThisDeviceIncludeCoreFormats() {
        let types = SupportedAudioMIMETypes.current()
        #expect(types.contains("audio/mpeg"))
        #expect(types.contains("audio/mp4"))
        #expect(!types.contains("audio/ogg"))
        #expect(!types.contains("audio/x-ms-wma"))
        #expect(types.allSatisfy { $0.hasPrefix("audio/") })
    }

    @Test func deviceInfoMatchesADR0007() {
        let info = PlaybackDeviceInfo.make(
            deviceID: "DEVICE-UUID", clientVersion: "1.2", model: "iPhone17,1", osVersion: "27.0.1")
        #expect(info.deviceId == "DEVICE-UUID")
        #expect(info.clientName == "Audiobookshelf Apple")
        #expect(info.clientVersion == "1.2")
        #expect(info.manufacturer == "Apple")
        #expect(info.model == "iPhone17,1")
        #expect(info.sdkVersion == "27.0.1")
    }

    @Test func hardwareModelAndOSVersionAreAvailable() {
        #expect(PlaybackDeviceInfo.hardwareModel()?.isEmpty == false)
        #expect(PlaybackDeviceInfo.operatingSystemVersion().split(separator: ".").count == 3)
    }

    @Test func startRequestUsesStableDeviceIDAndRuntimeTypes() async {
        let ids = FixedDeviceIdentifier(value: "DEVICE-UUID")
        let request = await PlaybackDeviceInfo.startRequest(deviceIdentifiers: ids)
        #expect(request.deviceInfo.deviceId == "DEVICE-UUID")
        #expect(request.mediaPlayer == "AVPlayer")
        #expect(request.forceDirectPlay == false)
        #expect(request.forceTranscode == false)
        #expect(request.supportedMimeTypes == SupportedAudioMIMETypes.current())
        #expect(await PlaybackDeviceInfo.startRequest(deviceIdentifiers: ids, forceTranscode: true).forceTranscode)
    }
}
