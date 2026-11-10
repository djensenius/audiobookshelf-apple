import AVFoundation
import Foundation

/// Why an item or the player failed, kept structured so recovery (P2-06a) can follow ADR 0007's
/// failure classification instead of parsing a localized string.
public struct PlaybackFailure: Sendable, Hashable {
    /// The ADR 0007 failure class this failure suggests. The HTTP status is only a hint: the
    /// coordinator still checks the session (`GET /api/session/{id}`) before choosing a path.
    public enum Kind: Sendable, Hashable {
        /// Connection loss (`NSURLErrorNotConnectedToInternet`, `.timedOut`, …): wait for the network.
        case network
        /// The server answered with an HTTP error status (401, 403, 404, 5xx, …).
        case http(status: Int)
        /// TLS or certificate failure. Not recoverable.
        case tls
        /// The media could not be decoded (`AVError.decodeFailed`, `.failedToParse`).
        case decode
        /// The format is not supported (`AVError.fileFormatNotRecognized`, `.decoderNotFound`).
        /// Like ``decode``, direct play falls back to HLS.
        case unsupported
        /// The load was cancelled (`NSURLErrorCancelled`).
        case cancelled
        case unknown
    }

    public let kind: Kind
    /// The top-level error's domain and code, for example `AVFoundationErrorDomain` / `-11800`.
    public let domain: String
    public let code: Int
    /// The first `NSUnderlyingErrorKey` error, often `NSURLErrorDomain` or `NSOSStatusErrorDomain`.
    public let underlyingDomain: String?
    public let underlyingCode: Int?
    /// The newest HTTP status in the item's error log, when it has one.
    public let httpStatus: Int?
    /// A display description (the error's localized description).
    public let description: String

    public init(
        kind: Kind, domain: String, code: Int, underlyingDomain: String? = nil, underlyingCode: Int? = nil,
        httpStatus: Int? = nil, description: String
    ) {
        self.kind = kind
        self.domain = domain
        self.code = code
        self.underlyingDomain = underlyingDomain
        self.underlyingCode = underlyingCode
        self.httpStatus = httpStatus
        self.description = description
    }
}

extension PlaybackFailure {
    /// An `AVPlayerItemErrorLogEvent`'s fields (that class cannot be created in tests).
    struct ErrorLogEntry: Sendable, Hashable {
        var domain: String
        var statusCode: Int
        var comment: String?
    }

    /// The item's error log entries, fetched without blocking.
    static func errorLogEntries(of item: AVPlayerItem) async -> [ErrorLogEntry] {
        (await item.errorLog?.events ?? []).map {
            ErrorLogEntry(domain: $0.errorDomain, statusCode: $0.errorStatusCode, comment: $0.errorComment)
        }
    }

    /// Classifies `error` with the item's cumulative `errorLog`. Precedence:
    /// 1. A network, TLS or cancellation error in the current error's underlying chain.
    /// 2. The newest classifiable log entry (a transport error or an HTTP status). The log keeps
    ///    entries playback already recovered from, so only the newest one counts.
    /// 3. A decode or unsupported-format error in the current error's chain.
    init(error: (any Error)?, errorLog: [ErrorLogEntry] = []) {
        let status = Self.httpStatus(in: errorLog)
        guard let error else {
            let newest = errorLog.last { Self.kind(of: $0) != nil } ?? errorLog.last
            self.init(
                kind: Self.kind(of: nil, errorLog: errorLog), domain: "", code: 0, httpStatus: status,
                description: newest?.comment ?? "Unknown error")
            return
        }
        let nsError = error as NSError
        let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError
        self.init(
            kind: Self.kind(of: nsError, errorLog: errorLog),
            domain: nsError.domain, code: nsError.code,
            underlyingDomain: underlying?.domain, underlyingCode: underlying?.code,
            httpStatus: status, description: nsError.localizedDescription)
    }

    /// The newest HTTP status in the log.
    static func httpStatus(in log: [ErrorLogEntry]) -> Int? {
        log.reversed().lazy.compactMap(httpStatus(of:)).first
    }

    /// The entry's HTTP status: `errorStatusCode` when it is one, else "HTTP 404" in the comment
    /// (CoreMedia uses its own negative codes).
    private static func httpStatus(of entry: ErrorLogEntry) -> Int? {
        guard entry.domain != NSURLErrorDomain else { return nil }
        if (400..<600).contains(entry.statusCode) { return entry.statusCode }
        if let comment = entry.comment, let match = comment.firstMatch(of: /HTTP (\d{3})/),
            let status = Int(match.1), (400..<600).contains(status)
        {
            return status
        }
        return nil
    }

    private static func kind(of entry: ErrorLogEntry) -> Kind? {
        if entry.domain == NSURLErrorDomain { return urlKind(entry.statusCode) }
        return httpStatus(of: entry).map { .http(status: $0) }
    }

    private static func kind(of error: NSError?, errorLog: [ErrorLogEntry]) -> Kind {
        let errors = error.map(chain(of:)) ?? []
        for error in errors where error.domain == NSURLErrorDomain {
            if let kind = urlKind(error.code) { return kind }
        }
        if let kind = errorLog.reversed().lazy.compactMap(kind(of:)).first { return kind }
        for error in errors where error.domain == AVFoundationErrorDomain {
            switch AVError.Code(rawValue: error.code) {
            case .decodeFailed, .failedToParse: return .decode
            case .fileFormatNotRecognized, .decoderNotFound: return .unsupported
            default: continue
            }
        }
        return .unknown
    }

    private static func urlKind(_ code: Int) -> Kind? {
        switch URLError.Code(rawValue: code) {
        case .notConnectedToInternet, .networkConnectionLost, .timedOut, .cannotConnectToHost, .cannotFindHost,
            .dnsLookupFailed, .internationalRoamingOff, .dataNotAllowed:
            .network
        case .secureConnectionFailed, .serverCertificateHasBadDate, .serverCertificateUntrusted,
            .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid, .clientCertificateRejected,
            .clientCertificateRequired:
            .tls
        case .cancelled: .cancelled
        default: nil
        }
    }

    /// The error and its `NSUnderlyingErrorKey` chain (bounded).
    private static func chain(of error: NSError) -> [NSError] {
        var errors = [error]
        while errors.count < 8, let next = errors.last?.userInfo[NSUnderlyingErrorKey] as? NSError {
            errors.append(next)
        }
        return errors
    }
}
