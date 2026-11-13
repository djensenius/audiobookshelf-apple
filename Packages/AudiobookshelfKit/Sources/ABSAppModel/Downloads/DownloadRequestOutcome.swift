import ABSCore
import ABSDownloads

/// What ``DownloadsController/request(item:episodeID:connectionID:)`` and
/// ``DownloadsController/confirmMeteredDownload(item:episodeID:ticket:)`` did. For new
/// requests only: resuming and retrying a download (#75) get their own result type.
public enum DownloadRequestOutcome: Sendable, Equatable {
    /// The manager took the request: the download started, an existing record was kept (a paused
    /// or failed one resumed), or the media is already downloaded.
    case started(DownloadManager.EnqueueResult)
    /// The path is metered and the download cellular policy is ``CellularPolicy/ask``: nothing was
    /// queued. Ask the user, then call
    /// ``DownloadsController/confirmMeteredDownload(item:episodeID:ticket:)`` with the ticket if
    /// they agree.
    case needsConfirmation(MeteredReason, DownloadRequestTicket)
    /// The path is metered and the download cellular policy is ``CellularPolicy/never``: nothing
    /// was queued.
    case denied(MeteredReason)
    /// The manager couldn't queue the download.
    case failed(DownloadManagerError)
    /// Refused before anything was queued: the user may not download, or the session the request
    /// was made in ended.
    case rejected(DownloadRequestError)
}
