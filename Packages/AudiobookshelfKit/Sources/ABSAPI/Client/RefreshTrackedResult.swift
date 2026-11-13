/// What ``APIClient/sendTrackingRefresh(_:)`` returns: the request's outcome, and whether a token
/// refresh answered its 401 on the way (for example, to charge it to a caller's refresh budget).
public struct RefreshTrackedResult<Response: Sendable>: Sendable {
    public let result: Result<Response, any Error>
    /// Whether the tokens this request was rejected with were refreshed for it before it was
    /// retried (or gave up).
    public let didRefresh: Bool

    public init(result: Result<Response, any Error>, didRefresh: Bool) {
        self.result = result
        self.didRefresh = didRefresh
    }
}
