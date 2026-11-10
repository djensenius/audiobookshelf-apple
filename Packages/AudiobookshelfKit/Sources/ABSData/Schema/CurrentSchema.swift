// The current schema version. Code outside `ABSData/Schema/` uses these names only, so a new
// schema version changes this file instead of every caller.

public typealias CurrentSchema = SchemaV1

public typealias ServerConnectionRecord = CurrentSchema.ServerConnectionRecord
public typealias LocalLibraryItem = CurrentSchema.LocalLibraryItem
public typealias LocalFile = CurrentSchema.LocalFile
public typealias LocalMediaProgress = CurrentSchema.LocalMediaProgress
public typealias DownloadRecord = CurrentSchema.DownloadRecord
public typealias DownloadPart = CurrentSchema.DownloadPart
public typealias PendingLocalSession = CurrentSchema.PendingLocalSession
public typealias PlaybackHistoryEvent = CurrentSchema.PlaybackHistoryEvent
