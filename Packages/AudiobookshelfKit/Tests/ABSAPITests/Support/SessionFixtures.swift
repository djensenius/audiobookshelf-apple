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

/// A session as `/play` and `GET /api/session/:id` actually send it: the expanded `libraryItem`
/// and per-track file `metadata` (copied from the ABSCore `multiFileBook` fixture).
let expandedSessionJSON = #"""
    {
      "id": "7d0e5a10-2b3c-4d5e-8f90-a1b2c3d4e5f6", "userId": "user-1", "libraryId": "lib-books",
      "libraryItemId": "li-book-2", "bookId": "book-2", "episodeId": null, "mediaType": "book",
      "mediaMetadata": {"title": "Book Two", "authors": []}, "chapters": [], "displayTitle": "Book Two",
      "displayAuthor": "", "coverPath": null, "duration": 1000.5, "playMethod": 0, "mediaPlayer": "AVPlayer",
      "deviceInfo": {"deviceId": "DEVICE-UUID", "clientName": "Audiobookshelf Apple"},
      "serverVersion": "2.37.2", "timeListening": 0, "startTime": 0, "currentTime": 0,
      "startedAt": 1762732800000, "updatedAt": 1762732800000,
      "audioTracks": [
        {"index": 1, "startOffset": 0, "duration": 600, "title": "01.mp3",
         "contentUrl": "/api/items/li-book-2/file/11", "mimeType": "audio/mpeg", "codec": "mp3",
         "metadata": {"filename": "01.mp3", "ext": ".mp3", "path": "/audiobooks/Two/01.mp3",
                      "relPath": "01.mp3", "size": 1000, "mtimeMs": 1700000001000.5}},
        {"index": 2, "startOffset": 600, "duration": 400.5, "title": "02.mp3",
         "contentUrl": "/api/items/li-book-2/file/12", "mimeType": "audio/mpeg", "codec": "mp3",
         "metadata": {"filename": "02.mp3", "ext": ".mp3", "path": "/audiobooks/Two/02.mp3",
                      "relPath": "02.mp3", "size": 1000}}
      ],
      "libraryItem": {"id":"li-book-2","ino":"1","libraryId":"lib-books","folderId":"fol-1",
        "path":"/audiobooks/Two","relPath":"Two","isFile":false,"addedAt":1700000003000,"updatedAt":1700000004000,
        "isMissing":false,"isInvalid":false,"mediaType":"book","media":{"id":"book-2","libraryItemId":"li-book-2",
        "metadata":{"title":"Book Two","authors":[],"narrators":[],"series":[],"genres":[],"explicit":false},
        "coverPath":null,"tags":[],"audioFiles":[{"index":1,"ino":"11","metadata":{"filename":"01.mp3",
        "ext":".mp3","path":"/audiobooks/Two/01.mp3","relPath":"01.mp3","size":1000},"duration":600,
        "mimeType":"audio/mpeg"},{"index":2,"ino":"12","metadata":{"filename":"02.mp3","ext":".mp3",
        "path":"/audiobooks/Two/02.mp3","relPath":"02.mp3","size":1000},"duration":400.5,"mimeType":"audio/mpeg"}],
        "chapters":[],"ebookFile":null,"duration":1000.5,"size":2000,"tracks":[{"index":1,"startOffset":0,
        "duration":600,"title":"01.mp3","contentUrl":"/api/items/li-book-2/file/11","mimeType":"audio/mpeg",
        "codec":"mp3"},{"index":2,"startOffset":600,"duration":400.5,"title":"02.mp3",
        "contentUrl":"/api/items/li-book-2/file/12","mimeType":"audio/mpeg","codec":"mp3"}]},
        "libraryFiles":[],"size":2000}
    }
    """#
