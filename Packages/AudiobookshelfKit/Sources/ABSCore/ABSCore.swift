import Foundation

/// An app's marketing version and build number, read from its bundle.
public struct AppVersion: Sendable, Hashable, CustomStringConvertible {
    public let marketing: String
    public let build: String

    public init(marketing: String, build: String) {
        self.marketing = marketing
        self.build = build
    }

    public init(bundle: Bundle = .main) {
        self.init(
            marketing: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0",
            build: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        )
    }

    /// For example, `0.1.0 (1)`.
    public var description: String { "\(marketing) (\(build))" }
}
