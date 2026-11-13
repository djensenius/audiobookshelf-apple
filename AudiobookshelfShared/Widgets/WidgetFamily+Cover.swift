import WidgetKit

extension WidgetFamily {
    /// Whether the Continue Listening widget draws its cover in this family (#89): only the home
    /// screen families do, so the accessory ones skip reading and decoding it. Shared with the
    /// app so its tests can check it.
    var showsContinueListeningCover: Bool {
        switch self {
        case .systemSmall, .systemMedium: true
        default: false
        }
    }
}
