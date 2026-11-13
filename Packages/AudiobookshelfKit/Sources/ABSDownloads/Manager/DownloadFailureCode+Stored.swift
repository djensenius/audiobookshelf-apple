import ABSData

// The stored failure code, typed. ABSData saves it as a raw string, since it can't see
// `DownloadFailureCode`; the engine saves it in the same write as the failure (#73).

extension DownloadPartDTO {
    /// The code of the part's saved failure, for a localised message; `nil` when it has none, or
    /// its code is one this build doesn't know.
    public var failureCode: DownloadFailureCode? {
        lastErrorCode.flatMap(DownloadFailureCode.init(rawValue:))
    }
}

extension DownloadRecordDTO {
    /// The failure code of the first failed part that has one (in part order), for a record
    /// that failed; `nil` when none has.
    public var failureCode: DownloadFailureCode? {
        parts.lazy.filter { $0.state == .failed }.compactMap(\.failureCode).first
    }
}
