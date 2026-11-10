import Foundation

/// How the server streams a session's audio.
public enum PlayMethod: Sendable, Hashable, Codable, RawRepresentable {
    case directPlay
    case directStream
    case transcode
    case local
    /// A method this client doesn't know; the server's value is kept.
    case unknown(Int)

    public init(rawValue: Int) {
        switch rawValue {
        case 0: self = .directPlay
        case 1: self = .directStream
        case 2: self = .transcode
        case 3: self = .local
        default: self = .unknown(rawValue)
        }
    }

    public var rawValue: Int {
        switch self {
        case .directPlay: 0
        case .directStream: 1
        case .transcode: 2
        case .local: 3
        case .unknown(let value): value
        }
    }
}

/// Describes the playing device. The client sends a subset (`deviceId`, `clientName`, …)
/// when starting playback; the server returns it with `id`, `userId`, and request details.
public struct DeviceInfo: Sendable, Hashable, Codable {
    public var id: String?
    public var userId: String?
    public var deviceId: String?
    public var ipAddress: String?
    public var browserName: String?
    public var browserVersion: String?
    public var osName: String?
    public var osVersion: String?
    public var deviceName: String?
    public var deviceType: String?
    public var manufacturer: String?
    public var model: String?
    /// Android SDK level. The server sends a string; older or other clients may have sent a number,
    /// which decodes as its string form.
    public var sdkVersion: String?
    public var clientName: String?
    public var clientVersion: String?

    public init(
        deviceId: String? = nil,
        deviceName: String? = nil,
        manufacturer: String? = nil,
        model: String? = nil,
        osName: String? = nil,
        osVersion: String? = nil,
        clientName: String? = nil,
        clientVersion: String? = nil
    ) {
        self.deviceId = deviceId
        self.deviceName = deviceName
        self.manufacturer = manufacturer
        self.model = model
        self.osName = osName
        self.osVersion = osVersion
        self.clientName = clientName
        self.clientVersion = clientVersion
    }

    enum CodingKeys: String, CodingKey {
        case id, userId, deviceId, ipAddress, browserName, browserVersion, osName, osVersion, deviceName
        case deviceType, manufacturer, model, sdkVersion, clientName, clientVersion
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id)
        userId = try container.decodeIfPresent(String.self, forKey: .userId)
        deviceId = try container.decodeIfPresent(String.self, forKey: .deviceId)
        ipAddress = try container.decodeIfPresent(String.self, forKey: .ipAddress)
        browserName = try container.decodeIfPresent(String.self, forKey: .browserName)
        browserVersion = try container.decodeIfPresent(String.self, forKey: .browserVersion)
        osName = try container.decodeIfPresent(String.self, forKey: .osName)
        osVersion = try container.decodeIfPresent(String.self, forKey: .osVersion)
        deviceName = try container.decodeIfPresent(String.self, forKey: .deviceName)
        deviceType = try container.decodeIfPresent(String.self, forKey: .deviceType)
        manufacturer = try container.decodeIfPresent(String.self, forKey: .manufacturer)
        model = try container.decodeIfPresent(String.self, forKey: .model)
        sdkVersion = try Self.decodeStringOrNumber(container, forKey: .sdkVersion)
        clientName = try container.decodeIfPresent(String.self, forKey: .clientName)
        clientVersion = try container.decodeIfPresent(String.self, forKey: .clientVersion)
    }

    private static func decodeStringOrNumber(
        _ container: KeyedDecodingContainer<CodingKeys>, forKey key: CodingKeys
    ) throws -> String? {
        if let value = try? container.decodeIfPresent(Int.self, forKey: key) {
            return String(value)
        }
        if let value = try? container.decodeIfPresent(Double.self, forKey: key) {
            return String(value)
        }
        return try container.decodeIfPresent(String.self, forKey: key)
    }
}

/// A playback session returned by `POST /api/items/:id/play[/:episodeId]`.
/// Times and durations are seconds; `startedAt` and `updatedAt` are epoch milliseconds.
public struct PlaybackSession: Sendable, Hashable, Codable, Identifiable {
    public let id: String
    public let userId: String?
    public let libraryId: String?
    public let libraryItemId: String
    public let bookId: String?
    public let episodeId: String?
    public let mediaType: MediaType
    /// `nil` when the media type is unknown to this client. Such sessions re-encode without it.
    public let mediaMetadata: MediaMetadata?
    public let chapters: [Chapter]
    public let displayTitle: String?
    public let displayAuthor: String?
    public let coverPath: String?
    public let duration: Double
    public let playMethod: PlayMethod
    public let mediaPlayer: String?
    public let deviceInfo: DeviceInfo?
    public let serverVersion: String?
    /// `YYYY-MM-DD` in the server's time zone.
    public let date: String?
    public let dayOfWeek: String?
    public var timeListening: Double
    public let startTime: Double
    public var currentTime: Double
    public let startedAt: Int?
    public var updatedAt: Int?
    public let audioTracks: [AudioTrack]
    /// Expanded library item.
    public let libraryItem: LibraryItem?

    public init(
        id: String, userId: String? = nil, libraryId: String? = nil, libraryItemId: String, bookId: String? = nil,
        episodeId: String? = nil, mediaType: MediaType, mediaMetadata: MediaMetadata? = nil, chapters: [Chapter] = [],
        displayTitle: String? = nil, displayAuthor: String? = nil, coverPath: String? = nil, duration: Double = 0,
        playMethod: PlayMethod = .directPlay, mediaPlayer: String? = nil, deviceInfo: DeviceInfo? = nil,
        serverVersion: String? = nil, date: String? = nil, dayOfWeek: String? = nil, timeListening: Double = 0,
        startTime: Double = 0, currentTime: Double = 0, startedAt: Int? = nil, updatedAt: Int? = nil,
        audioTracks: [AudioTrack] = [], libraryItem: LibraryItem? = nil
    ) {
        self.id = id
        self.userId = userId
        self.libraryId = libraryId
        self.libraryItemId = libraryItemId
        self.bookId = bookId
        self.episodeId = episodeId
        self.mediaType = mediaType
        self.mediaMetadata = mediaMetadata
        self.chapters = chapters
        self.displayTitle = displayTitle
        self.displayAuthor = displayAuthor
        self.coverPath = coverPath
        self.duration = duration
        self.playMethod = playMethod
        self.mediaPlayer = mediaPlayer
        self.deviceInfo = deviceInfo
        self.serverVersion = serverVersion
        self.date = date
        self.dayOfWeek = dayOfWeek
        self.timeListening = timeListening
        self.startTime = startTime
        self.currentTime = currentTime
        self.startedAt = startedAt
        self.updatedAt = updatedAt
        self.audioTracks = audioTracks
        self.libraryItem = libraryItem
    }

    enum CodingKeys: String, CodingKey {
        case id, userId, libraryId, libraryItemId, bookId, episodeId, mediaType, mediaMetadata, chapters
        case displayTitle, displayAuthor, coverPath, duration, playMethod, mediaPlayer, deviceInfo
        case serverVersion, date, dayOfWeek, timeListening, startTime, currentTime, startedAt, updatedAt
        case audioTracks, libraryItem
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        userId = try container.decodeIfPresent(String.self, forKey: .userId)
        libraryId = try container.decodeIfPresent(String.self, forKey: .libraryId)
        libraryItemId = try container.decode(String.self, forKey: .libraryItemId)
        bookId = try container.decodeIfPresent(String.self, forKey: .bookId)
        episodeId = try container.decodeIfPresent(String.self, forKey: .episodeId)
        mediaType = try container.decode(MediaType.self, forKey: .mediaType)
        if container.contains(.mediaMetadata), try !container.decodeNil(forKey: .mediaMetadata) {
            mediaMetadata = try MediaMetadata(
                from: container.superDecoder(forKey: .mediaMetadata), mediaType: mediaType)
        } else {
            mediaMetadata = nil
        }
        chapters = try container.decodeIfPresent([Chapter].self, forKey: .chapters) ?? []
        displayTitle = try container.decodeIfPresent(String.self, forKey: .displayTitle)
        displayAuthor = try container.decodeIfPresent(String.self, forKey: .displayAuthor)
        coverPath = try container.decodeIfPresent(String.self, forKey: .coverPath)
        duration = try container.decodeIfPresent(Double.self, forKey: .duration) ?? 0
        playMethod = try container.decodeIfPresent(PlayMethod.self, forKey: .playMethod) ?? .directPlay
        mediaPlayer = try container.decodeIfPresent(String.self, forKey: .mediaPlayer)
        deviceInfo = try container.decodeIfPresent(DeviceInfo.self, forKey: .deviceInfo)
        serverVersion = try container.decodeIfPresent(String.self, forKey: .serverVersion)
        date = try container.decodeIfPresent(String.self, forKey: .date)
        dayOfWeek = try container.decodeIfPresent(String.self, forKey: .dayOfWeek)
        timeListening = try container.decodeIfPresent(Double.self, forKey: .timeListening) ?? 0
        startTime = try container.decodeIfPresent(Double.self, forKey: .startTime) ?? 0
        currentTime = try container.decodeIfPresent(Double.self, forKey: .currentTime) ?? 0
        startedAt = try container.decodeIfPresent(Int.self, forKey: .startedAt)
        updatedAt = try container.decodeIfPresent(Int.self, forKey: .updatedAt)
        audioTracks = try container.decodeIfPresent([AudioTrack].self, forKey: .audioTracks) ?? []
        libraryItem = try container.decodeIfPresent(LibraryItem.self, forKey: .libraryItem)
    }
}
