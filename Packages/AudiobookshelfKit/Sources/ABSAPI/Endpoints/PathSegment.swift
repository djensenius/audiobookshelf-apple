import Foundation

/// Percent-encodes `value` (usually a server ID) for use as one path segment, so `/`, `?`,
/// `#`, and `%` can't change the route. `.` and `..` are encoded so they aren't resolved as
/// relative segments.
func pathSegment(_ value: String) -> String {
    switch value {
    case ".": return "%2E"
    case "..": return "%2E%2E"
    default:
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove("/")
        // Only fails for invalid UTF-16, which a Swift `String` can't hold.
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
    }
}
