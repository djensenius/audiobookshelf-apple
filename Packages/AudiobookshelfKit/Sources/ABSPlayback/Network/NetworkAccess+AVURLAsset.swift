import ABSCore
import AVFoundation

extension NetworkAccess {
    /// `AVURLAsset` initialization options with these network access flags, so streamed
    /// playback follows the same rules as `URLSession` traffic. Merge them into any other
    /// options passed to `AVURLAsset(url:options:)`.
    public var urlAssetOptions: [String: Bool] {
        [
            AVURLAssetAllowsCellularAccessKey: allowsCellularAccess,
            AVURLAssetAllowsExpensiveNetworkAccessKey: allowsExpensiveNetworkAccess,
            AVURLAssetAllowsConstrainedNetworkAccessKey: allowsConstrainedNetworkAccess,
        ]
    }
}
