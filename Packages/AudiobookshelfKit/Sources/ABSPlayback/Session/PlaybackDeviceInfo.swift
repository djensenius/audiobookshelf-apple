import ABSAPI
import ABSCore
import AVFoundation
import Foundation

/// The `supportedMimeTypes` sent when starting a session (ADR 0007, decision 4).
public enum SupportedAudioMIMETypes {
    /// Every audio MIME type the server assigns to a file (`server/utils/constants.js`).
    public static let serverAudioTypes = [
        "audio/mpeg", "audio/mp4", "audio/aac", "audio/flac", "audio/x-caf", "audio/x-aiff", "audio/ogg",
        "audio/webm", "audio/x-matroska", "audio/x-ms-wma", "audio/amr-wb",
    ]

    /// Types never sent even if AVFoundation reports them playable. `audio/ogg` covers Vorbis and
    /// Opus, whose progressive seeking in `AVPlayer` is unproven; AMR-WB isn't in
    /// `AVURLAsset.audiovisualMIMETypes()`. Remove an entry only when the #49 device matrix
    /// passes for it on both iOS and macOS.
    public static let denylist: Set<String> = ["audio/ogg", "audio/amr-wb"]

    /// The server's audio types this device can play, in server order.
    public static func current(
        isPlayable: (String) -> Bool = { AVURLAsset.isPlayableExtendedMIMEType($0) }
    ) -> [String] {
        serverAudioTypes.filter { !denylist.contains($0) && isPlayable($0) }
    }
}

/// Builds the `deviceInfo` and body for `POST /api/items/:id/play` (ADR 0007, decision 2).
public enum PlaybackDeviceInfo {
    public static let clientName = "Audiobookshelf Apple"

    public static func make(
        deviceID: String,
        clientVersion: String? = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
        model: String? = hardwareModel(),
        osVersion: String = operatingSystemVersion()
    ) -> DeviceInfo {
        var info = DeviceInfo(
            deviceId: deviceID, manufacturer: "Apple", model: model, clientName: clientName,
            clientVersion: clientVersion)
        info.sdkVersion = osVersion
        return info
    }

    /// The body for starting a session on this device with `AVPlayer`. The first call reads the
    /// device ID from the Keychain off the caller's actor.
    public static func startRequest(
        deviceIdentifiers: any DeviceIdentifying, forceTranscode: Bool = false
    ) async -> PlaybackStartRequest {
        PlaybackStartRequest(
            deviceInfo: make(deviceID: await deviceIdentifiers.deviceIdentifier()),
            supportedMimeTypes: SupportedAudioMIMETypes.current(), forceTranscode: forceTranscode)
    }

    /// The hardware identifier, for example `iPhone17,1` or `Mac15,3`.
    public static func hardwareModel() -> String? {
        #if targetEnvironment(simulator)
            if let model = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] { return model }
        #endif
        #if os(macOS)
            return sysctlString("hw.model")
        #else
            return sysctlString("hw.machine")
        #endif
    }

    public static func operatingSystemVersion() -> String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        let value = String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self)
        return value.isEmpty ? nil : value
    }
}
