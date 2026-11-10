import ABSCore
import Foundation

/// A direct-play session for a three-file mp3 book, shaped like
/// `PlaybackSession.toJSONForClient` from the server (2.37.2).
let multiTrackSessionJSON = #"""
    {
      "id": "3f2b8e4c-9d1a-4c6e-8f00-1a2b3c4d5e6f",
      "userId": "user-1",
      "libraryId": "lib-1",
      "libraryItemId": "li-1",
      "bookId": "book-1",
      "episodeId": null,
      "mediaType": "book",
      "mediaMetadata": {"title": "Dune", "authors": [{"id": "au-1", "name": "Frank Herbert"}]},
      "chapters": [
        {"id": 0, "start": 0, "end": 1800.5, "title": "One"},
        {"id": 1, "start": 1800.5, "end": 4000.25, "title": "Two"}
      ],
      "displayTitle": "Dune",
      "displayAuthor": "Frank Herbert",
      "coverPath": "/metadata/items/li-1/cover.jpg",
      "duration": 5400.75,
      "playMethod": 0,
      "mediaPlayer": "AVPlayer",
      "deviceInfo": {
        "id": "dev-row-1", "userId": "user-1", "deviceId": "DEVICE-UUID", "ipAddress": "10.0.0.2",
        "osName": "iOS", "osVersion": "27.0", "deviceName": "Apple iPhone17,1", "manufacturer": "Apple",
        "model": "iPhone17,1", "sdkVersion": "27.0.0", "clientName": "Audiobookshelf Apple",
        "clientVersion": "1.0"
      },
      "serverVersion": "2.37.2",
      "date": "2026-11-09",
      "dayOfWeek": "Monday",
      "timeListening": null,
      "startTime": 1234.5,
      "currentTime": 1234.5,
      "startedAt": 1762732800000,
      "updatedAt": 1762732800000,
      "audioTracks": [
        {"index": 1, "startOffset": 0, "duration": 1800.5, "title": "01.mp3",
         "contentUrl": "/api/items/li-1/file/1001", "mimeType": "audio/mpeg", "codec": "mp3", "metadata": null},
        {"index": 2, "startOffset": 1800.5, "duration": 2199.75, "title": "02.mp3",
         "contentUrl": "/api/items/li-1/file/1002", "mimeType": "audio/mpeg", "codec": "mp3", "metadata": null},
        {"index": 3, "startOffset": 4000.25, "duration": 1400.5, "title": "03.mp3",
         "contentUrl": "/api/items/li-1/file/1003", "mimeType": "audio/mpeg", "codec": "mp3", "metadata": null}
      ],
      "libraryItem": null
    }
    """#

func decodeMultiTrackSession() throws -> PlaybackSession {
    try JSONDecoder().decode(PlaybackSession.self, from: Data(multiTrackSessionJSON.utf8))
}
